variable "aws_region" {
  type        = string
  default     = "ap-south-1"
  description = "AWS deployment region"
}

variable "admin_cidr" {
  type        = string
  default     = "0.0.0.0/0"
  description = "Allowed CIDR for SSH, kubectl, and NodePort access"
}

variable "rke2_version" {
  type        = string
  default     = "v1.35.7+rke2r1"
  description = "RKE2 release version"
}

variable "cert_manager_version" {
  type        = string
  default     = "v1.21.1"
  description = "cert-manager Helm chart version"
}

variable "rancher_chart_version" {
  type        = string
  default     = "2.14.3"
  description = "Rancher Helm chart version"
}

variable "route53_zone_name" {
  type        = string
  description = "Existing public Route 53 hosted zone to create the Rancher record in"
}

variable "rancher_subdomain" {
  type        = string
  default     = "rancher-k8s"
  description = "Subdomain for the Rancher UI, combined with route53_zone_name"
}
variable "ssh_key_name" {
  type        = string
  description = "Existing EC2 SSH key-pair name in the deployment region"
}

variable "letsencrypt_email" {
  type        = string
  description = "Contact email for the existing ACME staging issuer workflow"
}
