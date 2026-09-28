# Production roadmap — future work only

None of these changes is implemented by the portfolio cleanup. The tested baseline
is preserved. Each change needs design review, a rollback plan and appropriate
runtime verification in an authorized environment.

| Future improvement | Intended outcome |
| --- | --- |
| HA RKE2 control plane and additional workers | Reduce single-node failure domains; review topology and scheduling. |
| Restricted administrative access | Replace unrestricted SSH/API reachability with an approved access model. |
| Scoped IAM and workload identity | Reduce shared node privileges and DNS permission scope. |
| Enforced IMDSv2 | Require tokens rather than merely using them in scripts. |
| Protected remote Terraform backend | Encryption, access control, versioning and state locking. |
| Off-node etcd backups and restore drills | Demonstrable recovery with protected backup data. |
| Observability | Centralized metrics, logs, alerts and workload health evidence. |
| Dependency/version pinning | Review controller chart versions, AMI selection, upstream policies and installer inputs. |
| Production ACME issuer | Publicly trusted certificates after staging validation and trust review. |
| HTTPS enforcement | Explicit redirect policy while preserving HTTP-01 challenge behavior. |
| Automated lifecycle cleanup | Coordinate controller resources, finalizers, DNS and Terraform teardown. |
| Safe bootstrap logging | Prevent secret-bearing command arguments from entering logs. |
| Output/documentation alignment | Retire the preserved legacy URL through a deliberate interface change. |

Do not advertise these capabilities as implemented until code, validation and
operational evidence support them.
