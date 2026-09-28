# Repository structure

```text
aws-rke2-rancher-gateway/
├── README.md
├── LICENSE
├── SECURITY.md
├── .gitignore
├── .editorconfig
├── .terraform.lock.hcl
├── main.tf
├── variables.tf
├── dns.tf
├── outputs.tf
├── terraform.tfvars.example
├── scripts/
│   ├── user_data_server.sh
│   ├── user_data_worker.sh
│   └── gateway-migration.sh
├── docs/
│   ├── architecture.md
│   ├── deployment.md
│   ├── repository-structure.md
│   ├── security.md
│   ├── engineering-decisions.md
│   ├── troubleshooting.md
│   └── production-roadmap.md
└── .github/
    └── workflows/
        └── validate.yml
```

| File or directory | Responsibility |
| --- | --- |
| `main.tf` | Provider requirements, discovery, credentials, security groups, IAM, EC2 and user-data rendering |
| `variables.tf` | Baseline defaults and required environment inputs |
| `dns.tf` | Hostname construction, existing zone lookup and intended URL output |
| `outputs.tf` | Operational outputs, including a preserved legacy URL |
| `.terraform.lock.hcl` | Reviewed provider selections and checksums |
| `scripts/user_data_server.sh` | Terraform template for server bootstrap and embedded migration execution |
| `scripts/user_data_worker.sh` | Terraform template for agent installation and registration |
| `scripts/gateway-migration.sh` | Embedded, non-template shell script for controllers, routes, TLS and DNS |
| `docs/` | Architecture, operations, tradeoffs and future work |
| `.github/workflows/validate.yml` | Static checks without AWS credentials |

The root Terraform module location and resource addresses are unchanged.
The two user-data templates must be rendered by Terraform; do not run them directly
as ordinary local shell scripts. The migration script contains infrastructure
mutations and is not a validation tool.

Local state, state backups, `terraform.tfvars`, private keys, `.terraform/`, logs,
rendered artifacts and original PDF/ODT notes are excluded. They may still exist
locally and must not be copied into the public repository or attachments.
