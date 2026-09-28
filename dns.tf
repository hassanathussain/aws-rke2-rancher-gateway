# ------------------------------------------------------------------------------
# Route 53 DNS: Rancher Hostname Configuration
#
# Terraform is responsible only for:
#   1. Defining the Rancher FQDN
#   2. Looking up the existing public Route 53 hosted zone
#
# The actual DNS A/ALIAS record is created asynchronously by
# gateway-migration.sh on the RKE2 server after:
#   - RKE2 is running
#   - Rancher is deployed
#   - Traefik Gateway API is configured
#   - AWS NLB has been provisioned
#
# DNS is updated before certificate readiness and the local HTTPS health check.
#
# This keeps terraform apply fast and avoids a second terraform apply.
# ------------------------------------------------------------------------------

locals {
  rancher_fqdn = "${var.rancher_subdomain}.${var.route53_zone_name}"
}

# ------------------------------------------------------------------------------
# Existing Public Route 53 Hosted Zone
# ------------------------------------------------------------------------------
data "aws_route53_zone" "primary" {
  name         = var.route53_zone_name
  private_zone = false
}

# ------------------------------------------------------------------------------
# Rancher URL
# ------------------------------------------------------------------------------
output "rancher_dns_url" {
  value       = "https://${local.rancher_fqdn}"
  description = "Rancher Dashboard URL. DNS is updated asynchronously by the server."
}