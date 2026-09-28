# Architecture and ownership

The [README diagram](../README.md#2-architecture) shows the request path. This
reference describes the working implementation, including its ownership boundaries.

## Provisioning

Terraform discovers the existing AWS default VPC and all its subnets, an existing
public Route53 zone, and the latest matching Canonical Ubuntu 24.04 AMI. It tags
the discovered subnets for public load-balancer discovery and cluster association.
It does not create a VPC, subnet, route table, internet gateway, SSH key pair, or zone.

Terraform creates management, cluster, and application security groups; a shared
node IAM role, policies, attachments and instance profile; random credentials;
and one server plus one worker (`t3.medium`, 30 GB gp3 root disk each).
Subnet placement and public addresses rely on AWS default-network behavior.

## Bootstrap and control flow

1. Server user data disables UFW, obtains EC2 identity through IMDSv2, writes
   RKE2 configuration and a Cilium toleration override, and installs RKE2.
2. Server configuration selects Cilium, sets an AWS provider ID, taints the server
   `CriticalAddonsOnly=true:NoSchedule`, and disables bundled NGINX ingress.
3. Worker user data installs the agent, waits for the private supervisor endpoint,
   writes the shared token/provider ID, and starts the RKE2 agent.
4. The server installs Helm and waits for the API and two Ready nodes.
5. It installs Gateway API CRDs, cert-manager with Gateway support, then Rancher.
6. The embedded migration script installs AWS CLI if needed, discovers region/VPC,
   verifies NGINX disabling, and installs/checks AWS Load Balancer Controller.
7. It verifies cert-manager, creates the staging ClusterIssuer, disables Rancher's
   legacy Ingress, and installs Traefik with its Gateway provider enabled.
8. It applies a Gateway and HTTPRoute, discovers the NLB and its hosted-zone ID,
   updates the Route53 alias, waits for the certificate, and checks local HTTPS.

The conceptual service chain includes Rancher and cert-manager, but the actual
installation order is cert-manager before Rancher. Retry helpers use a fixed delay.
No orchestration system continuously reruns this full cloud-init sequence.

## Traffic and TLS

Public DNS resolves the hostname to the NLB. The NLB's instance targets forward
to Kubernetes NodePorts. Traefik uses the `traefik` GatewayClass and the
`cattle-system` Gateway's HTTP/HTTPS listeners. The HTTPRoute matches the Rancher
hostname and `/` prefix and selects the Rancher Service on port 80.

Traefik terminates TLS using `rancher-gateway-tls`. cert-manager creates/manages
the certificate through the Gateway annotation and staging ClusterIssuer.
HTTP-01 solver routes attach to the Gateway; validation requires working public
DNS and HTTP reachability. No DNS-01 solver or ACM TLS termination is configured.
The custom Gateway permits routes from its own namespace. Both application
listeners forward to Rancher; no Gateway redirect filter is configured.

## Ownership

| Object | Owner / lifecycle |
| --- | --- |
| EC2, IAM, security groups, subnet tags, generated credentials | Terraform |
| Existing VPC, subnets, SSH key pair, public zone | External prerequisites |
| RKE2 host configuration | EC2 user data |
| Rancher, cert-manager, Traefik, AWS controller releases | Helm invoked by scripts |
| NLB and associated controller-managed resources | AWS Load Balancer Controller responding to Traefik Service |
| Gateway, HTTPRoute, ClusterIssuer | Migration script applies Kubernetes objects |
| Certificates, challenge resources and TLS secrets | cert-manager |
| Public Route53 A alias | One-time script UPSERT, not continuous reconciliation |

Terraform completion does not establish bootstrap success. NLB reconciliation
continues through its controller; Route53 cutover is a script action. Teardown
needs a separate authorized lifecycle procedure to avoid orphaned resources.
