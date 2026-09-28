# Security considerations

## Publication boundary

Commit source, reviewed provider locks, fictional examples and sanitized Markdown.
Never commit private keys, Terraform state/backups/plans, AWS credentials, local
inputs, kubeconfigs, rendered user data, certificate private keys, or raw logs.
The original PDF/ODT deployment notes contain environment-specific information
and are deliberately excluded, not deleted.

`.gitignore` prevents ordinary accidental staging, not forced additions or secrets
pasted into source. Review the exact candidate file set before each publication.
A regex scan alone cannot prove absence of secrets.

## Credential lifecycle

Terraform generates the RKE2 token and Rancher bootstrap password. These flow
through state and EC2 user data; the bootstrap password also appears in Helm
arguments. `sensitive = true` suppresses normal display, not storage in state.
The retry helper can log command arguments on failure, including that password.
Treat cloud-init logs and Helm release data as private. Logging changes are future
work, not part of this behavior-preserving cleanup.

Operational domain, key-pair name and ACME email are supplied through ignored
local inputs. Real values must never be replaced by example values in an existing
deployment. The local file created during cleanup uses owner-only permissions.

## Baseline exposure and permissions

- The default administrator CIDR permits internet-wide SSH/API access.
- HTTP/HTTPS are publicly reachable; other node/pod rules use self or VPC scope.
- Both EC2 nodes share AWS load-balancer permissions and broad Route53 permissions.
- Scripts request IMDSv2 tokens, but EC2 metadata configuration still permits IMDSv1
  and has hop limit 2. There is no workload-specific IAM isolation configured here.
- Host UFW is disabled by the bootstrap scripts.
- EBS encryption behavior relies on account defaults; it is not enforced here.
- The staging ACME issuer does not provide normal browser trust. No Gateway
  HTTP-to-HTTPS enforcement is configured.

These are documented baseline properties, not changes made by this cleanup.

## Intentionally public constants

The AWS region, instance sizes, version strings, fixed cluster label, subdomain
label, Canonical's public AMI-owner identifier, public upstream URLs, ports, CIDR
rules, metadata-service address, loopback address and public DNS resolvers remain.
They are functional configuration, not the operator's account credentials or
private/public deployment addresses. The author profile is intentionally public.
Example domain/email and administrator address are documentation placeholders.

See [SECURITY.md](../SECURITY.md) for reporting and
[future improvements](production-roadmap.md) for hardening proposals.
