output "server_public_ip" {
  value       = aws_instance.rke2_server.public_ip
  description = "Public IP of RKE2 Control Plane Server"
}

output "worker_public_ip" {
  value       = aws_instance.rke2_worker.public_ip
  description = "Public IP of RKE2 Worker Agent"
}

output "rancher_bootstrap_password" {
  value       = random_password.rancher_bootstrap_password.result
  sensitive   = true
  description = "Rancher UI initial admin password"
}

output "cert_manager_version" {
  value       = var.cert_manager_version
  description = "Version of cert-manager chart for deploy_rancher.sh"
}

output "rancher_chart_version" {
  value       = var.rancher_chart_version
  description = "Version of Rancher chart for deploy_rancher.sh"
}

output "rancher_ui_url" {
  value       = "https://rancher.${aws_instance.rke2_server.public_ip}.sslip.io"
  description = "Rancher UI Endpoint URL"
}