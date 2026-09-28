# Deployment workflow

This guide describes operator actions; static CI does not provision anything.
The author reports the baseline as successfully deployed and tested. Repository
cleanup validation is not a fresh deployment test.

## Prerequisites and configuration

Use the prerequisites and versions in the [README](../README.md#7-prerequisites).
Configure AWS authentication locally through a credential chain. Never include
credentials in source, command transcripts, or public CI.

For a new environment, copy the example inputs to ignored `terraform.tfvars`
and replace the fictional domain, key-pair name, administrator CIDR and email.
Preserve an existing deployment's local file. Run Terraform from the repository
root; script references use `path.module`.

## State preflight

Before any future infrastructure operation, establish which state is authoritative.
The local workspace examined during cleanup had an empty current state and a
populated backup. That does not prove whether AWS resources exist. Do not infer
that an empty state means a safe new deployment, and do not restore or manipulate
state merely to follow this guide. Resolve ownership through a separately
authorized operational review. State and backups remain private.

## Static validation

```bash
terraform fmt -check
terraform init -backend=false -lockfile=readonly
terraform validate
bash -n scripts/user_data_server.sh
bash -n scripts/user_data_worker.sh
bash -n scripts/gateway-migration.sh
```

Initialization downloads providers but does not contact the configured AWS account
for resource discovery. Validation checks configuration, not runtime availability
of AMIs, DNS zones, charts, credentials or EC2 quotas. Shell templates contain
Terraform interpolation and escaping; `bash -n` alone does not validate rendering.

## Authorized deployment sequence

1. Verify authoritative state, local inputs, permissions, network prerequisites,
   component availability, costs, and the proposed hostname.
2. With explicit operator authorization, generate and privately review a Terraform
   plan. Plans may contain sensitive material and must remain outside publication.
3. Only after approval, provision the reviewed infrastructure through the normal
   Terraform workflow. No deployment is performed by this repository's CI.
4. Observe EC2 cloud-init and `/var/log/user-data-rke2.log` on both hosts.
5. Verify RKE2 server/agent services and two Ready nodes.
6. Verify Helm workloads, Traefik Service, Gateway/HTTPRoute conditions, certificate
   readiness, public DNS, and the external NLB request path.

The worker's Terraform dependency ensures EC2 creation ordering, not completed
server bootstrap. Scripts provide the subsequent readiness checks.

## Outputs and validation boundaries

`rancher_dns_url` reflects the intended Gateway hostname. The preserved legacy
`rancher_ui_url` instead builds a server-IP-based sslip.io URL. Public IP outputs
and the sensitive bootstrap password output are private operational information.

DNS cutover precedes certificate readiness and local HTTPS verification. This
supports HTTP-01 issuance but means cutover is not gated by a passing HTTPS test.
The local check uses certificate-verification bypass for staging TLS and does not
prove public NLB health. A successful certificate does not make staging trusted.

## Lifecycle caution

Both instances replace on user-data changes. Preserve local values and inspect a
future authorized plan before treating a documentation/source reorganization as
a safe infrastructure update. No zero-change plan was performed during cleanup.

NLB resources and the DNS alias are not Terraform-managed resources. Any future
teardown procedure must deliberately address controller finalizers, load balancer
cleanup, DNS, and data backups before terminating the cluster. This guide does
not provide or execute destructive commands.
