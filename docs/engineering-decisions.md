# Engineering decisions reflected in the implementation

These observations explain code behavior and tradeoffs. They do not claim to
reconstruct undocumented personal motivations or benchmark alternatives.

| Existing choice | Consequence / tradeoff |
| --- | --- |
| RKE2 on EC2 rather than managed Kubernetes | Demonstrates host, control-plane and agent operations; cluster lifecycle remains the operator's responsibility. |
| Existing default VPC | Reuses networking; requires correct subnet routing and public connectivity assumptions. |
| Cilium | Provides cluster networking; Terraform permits the configured overlay and health-check traffic. |
| Tainted server | Keeps ordinary workloads off the control plane unless they tolerate its taint; a single worker remains a failure domain. |
| Bundled NGINX disabled | Traefik provides the external ingress path. Rancher is initially installed with chart defaults, then its legacy Ingress is disabled. |
| Gateway API with Traefik | Separates listener configuration from HTTP routing while using Traefik as the implementing proxy. |
| Kubernetes `LoadBalancer` Service | AWS Load Balancer Controller owns NLB provisioning and reconciliation independently of Terraform. |
| Instance target mode | Traffic reaches EC2 NodePorts, rather than registering pod IP targets. |
| cert-manager Gateway integration | Gateway annotation and certificate references drive certificate creation and renewal. |
| Staging ACME HTTP-01 | Exercises public challenge routing without providing production certificate trust. |
| Route53 A alias | Directs the hostname to the discovered NLB; cutover is a script UPSERT, not an ExternalDNS reconciliation loop. |
| Embedded migration script | Delivers orchestration through server user data; changes can change instance replacement inputs. |
| Readiness polls and retries | Bound many transient waits, but do not provide a continuously reconciling bootstrap service. |

## Preserved ownership and order

Terraform continues to own EC2, IAM, security groups, tags and generated secrets.
Helm/scripts own Kubernetes configuration, the AWS controller owns the NLB, and
the script updates the DNS record. The cleanup does not add Terraform resources
for these external objects or change their dependencies.

The original script order is preserved, including DNS update before certificate
and local HTTPS checks. See [architecture](architecture.md) for the exact sequence.
Production alternatives belong in the [roadmap](production-roadmap.md).

## Portfolio cleanup equivalence review

Resource names, dependency relationships, security-group rules and versions were
preserved. Worker and gateway scripts are byte-identical after relocation. The
server template substitutes an input for the original ACME email; with preserved
local values, Terraform-rendered server and worker scripts match the baseline
exactly. Required zone/key-pair/email inputs are preserved in ignored local inputs.

Provider initialization removed only a stale, unused `null` provider lock entry.
The required AWS, HTTP and random provider versions and checksums were unchanged.
The legacy URL output remains unchanged. DNS comments now match the actual order.

These are static source/rendering comparisons, not a live zero-change plan,
proof of current AWS state, or revalidation of upstream chart availability.
