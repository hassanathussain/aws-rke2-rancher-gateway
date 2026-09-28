# This Terraform configuration provisions the RKE2/Rancher infrastructure.
# ------------------------------------------------------------------------------
# Phase 1: Terraform & Provider Requirements
# Defines minimum required Terraform binary version and provider constraints.
# ------------------------------------------------------------------------------
terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }

    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

# Configure the AWS Provider with the target region
provider "aws" {
  region = var.aws_region
}

# ------------------------------------------------------------------------------
# Phase 2: Sensitive Passwords & Cluster Tokens Generation
# Generates cryptographically secure random strings for node join and Rancher admin.
# ------------------------------------------------------------------------------

# Shared secret token required by RKE2 worker nodes to join the control-plane
resource "random_password" "rke2_token" {
  length  = 32
  special = false
}

# Initial bootstrap password used for first-time Rancher UI login
resource "random_password" "rancher_bootstrap_password" {
  length  = 16
  special = false
}

# ------------------------------------------------------------------------------
# Phase 3: Data Source Lookups
# Fetches dynamic AMI, IAM policy definitions, and default VPC networking details.
# ------------------------------------------------------------------------------

# Retrieve the latest official Canonical Ubuntu 24.04 LTS (Noble Numbat) AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Fetch official IAM policy manifest required by AWS Load Balancer Controller
data "http" "aws_lbc_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json"
}

# Query default AWS VPC infrastructure
data "aws_vpc" "default" {
  default = true
}

# Query subnets associated with the default VPC
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ------------------------------------------------------------------------------
# Phase 4: AWS Security Groups Setup
# Configures network access controls for SSH, RKE2 internal API, and HTTP/S traffic.
# ------------------------------------------------------------------------------

# Security Group for SSH administrative access and external kubectl access
resource "aws_security_group" "mgmt_sg" {
  name_prefix = "rke2-mgmt-sg-"

  description = "Administrative access for SSH and Kubernetes API"

  ingress {
    description = "SSH Access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "Kubernetes API Access"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Security Group for RKE2 internal control-plane, Kubelet, and Cilium CNI overlay
resource "aws_security_group" "cluster_sg" {
  name_prefix = "rke2-cluster-sg-"

  description = "Internal RKE2, Kubernetes and Cilium traffic"

  tags = {
    "kubernetes.io/cluster/rke2-cluster" = "owned"
  }

  ingress {
    description = "Kubernetes API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "RKE2 Supervisor"
    from_port   = 9345
    to_port     = 9345
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "Kubelet API"
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "Cilium VXLAN Overlay"
    from_port   = 8472
    to_port     = 8472
    protocol    = "udp"
    self        = true
  }

  ingress {
    description = "Cilium Health Checks"
    from_port   = 4240
    to_port     = 4240
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Security Group for application exposure, Traefik NodePorts, and Load Balancers
resource "aws_security_group" "app_sg" {
  name_prefix = "rke2-app-sg-"

  description = "Public application traffic and Kubernetes NodePorts"

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Kubernetes NodePort Range"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  ingress {
    description = "AWS Load Balancer Controller Webhook"
    from_port   = 9443
    to_port     = 9443
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "Traefik Pod Ports"
    from_port   = 8000
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ------------------------------------------------------------------------------
# Phase 5: AWS Subnet Infrastructure Tagging
# Applies tags required by AWS Load Balancer Controller for dynamic ELB discovery.
# ------------------------------------------------------------------------------

# Enables internet-facing ELB auto-discovery on public subnets
resource "aws_ec2_tag" "public_subnet_elb_tag" {
  for_each = toset(data.aws_subnets.default.ids)

  resource_id = each.value
  key         = "kubernetes.io/role/elb"
  value       = "1"
}

# Associates subnets with the RKE2 Kubernetes cluster
resource "aws_ec2_tag" "public_subnet_cluster_tag" {
  for_each = toset(data.aws_subnets.default.ids)

  resource_id = each.value
  key         = "kubernetes.io/cluster/rke2-cluster"
  value       = "shared"
}

# ------------------------------------------------------------------------------
# Phase 6: IAM Roles & Controller Access Policies
# Grants EC2 nodes identity rights for AWS integration, ELB creation, and DNS setup.
# ------------------------------------------------------------------------------

# Base EC2 IAM role assumed by RKE2 server and worker nodes
resource "aws_iam_role" "rke2_node_role" {
  name_prefix = "rke2-node-role-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"

        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# Policy allowing AWS Load Balancer Controller to manage AWS ELB/NLB resources
resource "aws_iam_policy" "aws_lbc_policy" {
  name_prefix = "AWSLoadBalancerControllerIAMPolicy-"

  description = "IAM policy for AWS Load Balancer Controller"

  policy = data.http.aws_lbc_iam_policy.response_body
}

# Attach Load Balancer Controller policy to the cluster node role
resource "aws_iam_role_policy_attachment" "rke2_lbc_attach" {
  role       = aws_iam_role.rke2_node_role.name
  policy_arn = aws_iam_policy.aws_lbc_policy.arn
}

# Policy allowing migration script to manipulate Route 53 records and look up NLBs
resource "aws_iam_policy" "gateway_migration_policy" {
  name_prefix = "rke2-gateway-migration-"
  description = "Allows the RKE2 server to update the Rancher Route 53 record and describe load balancers"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageRoute53"
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:GetChange",
          "route53:ListResourceRecordSets",
          "route53:ListHostedZonesByName"
        ]
        Resource = "*"
      },
      {
        Sid      = "DescribeLoadBalancers"
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:DescribeLoadBalancers"]
        Resource = "*"
      }
    ]
  })
}

# Attach gateway migration policy to the cluster node role
resource "aws_iam_role_policy_attachment" "rke2_gateway_migration_attach" {
  role       = aws_iam_role.rke2_node_role.name
  policy_arn = aws_iam_policy.gateway_migration_policy.arn
}

# Instance profile binding the IAM role to EC2 instances
resource "aws_iam_instance_profile" "rke2_node_profile" {
  name_prefix = "rke2-node-profile-"
  role        = aws_iam_role.rke2_node_role.name
}

# ------------------------------------------------------------------------------
# Phase 7: RKE2 Server Compute Provisioning
# Launches RKE2 primary server instance and injects user-data bootstrapping code.
# ------------------------------------------------------------------------------
resource "aws_instance" "rke2_server" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.medium"

  key_name = var.ssh_key_name

  iam_instance_profile = aws_iam_instance_profile.rke2_node_profile.name

  user_data_replace_on_change = true

  vpc_security_group_ids = [
    aws_security_group.mgmt_sg.id,
    aws_security_group.cluster_sg.id,
    aws_security_group.app_sg.id
  ]

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 2
  }

  # Encodes and passes user_data_server.sh, injecting gateway-migration.sh into it
  user_data_base64 = base64gzip(
    templatefile("${path.module}/scripts/user_data_server.sh", {
      rke2_token                 = random_password.rke2_token.result
      rke2_version               = var.rke2_version
      cert_manager_version       = var.cert_manager_version
      rancher_chart_version      = var.rancher_chart_version
      rancher_bootstrap_password = random_password.rancher_bootstrap_password.result
      rancher_host               = local.rancher_fqdn
      route53_zone_id            = data.aws_route53_zone.primary.zone_id
      letsencrypt_email          = var.letsencrypt_email

      gateway_script = file("${path.module}/scripts/gateway-migration.sh")
    })
  )

  tags = {
    Name = "rke2-server"
  }

  depends_on = [
    aws_ec2_tag.public_subnet_elb_tag,
    aws_ec2_tag.public_subnet_cluster_tag,
    aws_iam_role_policy_attachment.rke2_lbc_attach,
    aws_iam_role_policy_attachment.rke2_gateway_migration_attach
  ]
}

# ------------------------------------------------------------------------------
# Phase 8: RKE2 Worker Compute Provisioning
# Provisions worker node compute instance dependent on primary server availability.
# ------------------------------------------------------------------------------
resource "aws_instance" "rke2_worker" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.medium"

  key_name = var.ssh_key_name

  iam_instance_profile = aws_iam_instance_profile.rke2_node_profile.name

  user_data_replace_on_change = true

  vpc_security_group_ids = [
    aws_security_group.mgmt_sg.id,
    aws_security_group.cluster_sg.id,
    aws_security_group.app_sg.id
  ]

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 2
  }

  # Configures worker node with server private IP and join token
  user_data = templatefile("${path.module}/scripts/user_data_worker.sh", {
    server_private_ip = aws_instance.rke2_server.private_ip
    rke2_token        = random_password.rke2_token.result
    rke2_version      = var.rke2_version
  })

  tags = {
    Name = "rke2-worker"
  }

  depends_on = [
    aws_instance.rke2_server
  ]
}