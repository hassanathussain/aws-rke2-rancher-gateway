#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------------------------
# Phase 1: Logging & Fail-Safe Traps Setup
# Redirects stdout/stderr to log file and installs an error signal handler.
# ------------------------------------------------------------------------------
exec > >(tee -a /var/log/user-data-rke2.log) 2>&1
trap 'log "ERROR: user_data_server.sh failed at line $LINENO"' ERR

# Outputs timestamped log statements
log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

# ------------------------------------------------------------------------------
# Phase 2: Injected Variable Declarations
# Receives deployment variables rendered by Terraform's templatefile function.
# ------------------------------------------------------------------------------
RKE2_VERSION="${rke2_version}"
CERT_MANAGER_VER="${cert_manager_version}"
RANCHER_VER="${rancher_chart_version}"
BOOTSTRAP_PASS="${rancher_bootstrap_password}"
ROUTE53_ZONE_ID="${route53_zone_id}"
RANCHER_HOST="${rancher_host}"

# ------------------------------------------------------------------------------
# Phase 3: Helper Utility Functions Definition
# Provides execution retries with exponential delay for network operations.
# ------------------------------------------------------------------------------
retry() {
  local n=0 max=5 delay=10

  until "$@"; do
    n=$((n + 1))

    if [ "$n" -ge "$max" ]; then
      log "Command failed after $n attempts: $*"
      return 1
    fi

    log "Attempt $n/$max failed, retrying in $${delay}s: $*"
    sleep "$delay"
  done
}

# ------------------------------------------------------------------------------
# Phase 4: Host Firewall Disabling
# Disables UFW firewall to prevent interference with Cilium overlay network traffic.
# ------------------------------------------------------------------------------
log "Disabling UFW host firewall..."
systemctl disable --now ufw 2>/dev/null || true

# ------------------------------------------------------------------------------
# Phase 5: AWS Metadata Retrieval (IMDSv2)
# Queries EC2 Metadata service for Instance ID and Availability Zone provider ID formatting.
# ------------------------------------------------------------------------------
log "Fetching EC2 instance identity..."

IMDS_TOKEN=$(curl -sf -X PUT \
  "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

INSTANCE_ID=$(curl -sf \
  -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  "http://169.254.169.254/latest/meta-data/instance-id")

AWS_AZ=$(curl -sf \
  -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  "http://169.254.169.254/latest/meta-data/placement/availability-zone")

if [[ -z "$INSTANCE_ID" || -z "$AWS_AZ" ]]; then
  log "ERROR: Could not retrieve instance ID or availability zone."
  exit 1
fi

log "Instance ID: $INSTANCE_ID | AZ: $AWS_AZ"

# ------------------------------------------------------------------------------
# Phase 6: RKE2 Server Engine Configuration
# Writes node configuration, disables default Nginx ingress, and sets AWS cloud provider.
# ------------------------------------------------------------------------------
log "Writing RKE2 server configuration..."

mkdir -p /etc/rancher/rke2

cat <<EOF > /etc/rancher/rke2/config.yaml
token: "${rke2_token}"
cloud-provider-name: "aws"
node-name: "ip-$(hostname -I | awk '{print $1}' | tr '.' '-')"
cni: "cilium"

kubelet-arg:
  - "provider-id=aws:///$${AWS_AZ}/$${INSTANCE_ID}"

node-taint:
  - "CriticalAddonsOnly=true:NoSchedule"

disable:
  - rke2-ingress-nginx
EOF

chmod 600 /etc/rancher/rke2/config.yaml

# ------------------------------------------------------------------------------
# Phase 7: Cilium CNI Control-Plane Tolerations
# Configures Cilium chart manifest to tolerate control-plane taints during bootstrap.
# ------------------------------------------------------------------------------
log "Writing Cilium toleration override manifest..."

mkdir -p /var/lib/rancher/rke2/server/manifests

cat <<EOF > /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-cilium
  namespace: kube-system
spec:
  valuesContent: |-
    tolerations:
      - operator: Exists
EOF

# ------------------------------------------------------------------------------
# Phase 8: RKE2 Installation & Service Startup
# Fetches formal install script, installs binaries, enables and starts systemd service.
# ------------------------------------------------------------------------------
log "Installing RKE2 server $${RKE2_VERSION}..."

retry curl -sfL \
  "https://get.rke2.io" \
  -o /tmp/rke2-install.sh

chmod +x /tmp/rke2-install.sh

INSTALL_RKE2_VERSION="$RKE2_VERSION" /tmp/rke2-install.sh

systemctl enable rke2-server.service
systemctl start rke2-server.service

# ------------------------------------------------------------------------------
# Phase 9: Shell Environment & Path Configuration
# Configures PATH and KUBECONFIG for root session and appends settings to .bashrc.
# ------------------------------------------------------------------------------
export PATH="$PATH:/var/lib/rancher/rke2/bin:/usr/local/bin"
export KUBECONFIG="/etc/rancher/rke2/rke2.yaml"

grep -qxF 'export PATH=$PATH:/var/lib/rancher/rke2/bin:/usr/local/bin' /root/.bashrc || \
cat >> /root/.bashrc <<'EOF'
export PATH=$PATH:/var/lib/rancher/rke2/bin:/usr/local/bin
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
alias k=kubectl
EOF

# ------------------------------------------------------------------------------
# Phase 10: Helm CLI Installation
# Downloads and installs Helm 3 binary if not already present on host.
# ------------------------------------------------------------------------------
if ! command -v helm &>/dev/null; then
  log "Installing Helm CLI..."

  retry curl -fsSL \
    -o /tmp/get_helm.sh \
    "https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3"

  chmod +x /tmp/get_helm.sh
  /tmp/get_helm.sh
fi

# ------------------------------------------------------------------------------
# Phase 11: Cluster API & Worker Node Health Verification
# Polls Kubernetes API and waits for control-plane and worker nodes to reach Ready state.
# ------------------------------------------------------------------------------
log "Waiting for Kubernetes API..."

attempts=0
max_attempts=60

until kubectl get nodes &>/dev/null; do
  attempts=$((attempts + 1))

  if [ "$attempts" -ge "$max_attempts" ]; then
    log "ERROR: Kubernetes API did not become reachable within timeout."
    exit 1
  fi

  sleep 10
done

log "Waiting for worker node to join cluster..."

attempts=0
max_attempts=60

until [ "$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready')" -ge 2 ]; do
  attempts=$((attempts + 1))
  READY_COUNT="$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready' || true)"
  log "Waiting for 2 Ready nodes... current count: $${READY_COUNT}"

  if [ "$attempts" -ge "$max_attempts" ]; then
    log "ERROR: Worker node failed to join within timeout."
    kubectl get nodes -o wide || true
    exit 1
  fi

  sleep 10
done

log "Both control-plane and worker nodes are Ready."

# ------------------------------------------------------------------------------
# Phase 12: Gateway API CRDs Installation
# Applies standard Kubernetes Gateway API CustomResourceDefinitions prior to cert-manager.
# ------------------------------------------------------------------------------
log "Installing Gateway API CRDs..."

retry kubectl apply -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml

# ------------------------------------------------------------------------------
# Phase 13: Cert-Manager Helm Installation (Single Source of Truth)
# Deploys cert-manager configured with Gateway API support and public DNS solvers.
# ------------------------------------------------------------------------------
log "Installing cert-manager $${CERT_MANAGER_VER} with Gateway API & Public DNS solvers..."

retry helm repo add jetstack \
  "https://charts.jetstack.io" \
  --force-update

retry helm repo update

cat <<'EOF' > /tmp/cert-manager-values.yaml
crds:
  enabled: true

config:
  gatewayAPI:
    enabled: true

extraArgs:
  - --acme-http01-solver-nameservers=8.8.8.8:53,1.1.1.1:53
EOF

retry helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version "$CERT_MANAGER_VER" \
  -f /tmp/cert-manager-values.yaml \
  --wait \
  --timeout 300s \
  --atomic

# ------------------------------------------------------------------------------
# Phase 14: Rancher Server Helm Deployment
# Installs Rancher control plane targeting configured domain hostname.
# ------------------------------------------------------------------------------
log "Installing Rancher $${RANCHER_VER} at $${RANCHER_HOST}..."

retry helm repo add rancher-stable \
  "https://releases.rancher.com/server-charts/stable" \
  --force-update

retry helm repo update

retry helm upgrade --install rancher rancher-stable/rancher \
  --namespace cattle-system \
  --create-namespace \
  --version "$RANCHER_VER" \
  --set hostname="$RANCHER_HOST" \
  --set bootstrapPassword="$BOOTSTRAP_PASS" \
  --wait \
  --timeout 600s \
  --atomic

log "Rancher installation completed."

# ------------------------------------------------------------------------------
# Phase 15: Gateway Migration Script Provisioning & Execution
# Writes Embedded gateway-migration.sh to disk and executes migration workflow.
# ------------------------------------------------------------------------------
log "Writing /usr/local/bin/gateway-migration.sh..."

cat <<'GWEOF' > /usr/local/bin/gateway-migration.sh
${gateway_script}
GWEOF

chmod +x /usr/local/bin/gateway-migration.sh

log "Invoking gateway-migration.sh..."
LETSENCRYPT_EMAIL="${letsencrypt_email}" \
  /usr/local/bin/gateway-migration.sh \
  "$RANCHER_HOST" \
  "$CERT_MANAGER_VER" \
  "$ROUTE53_ZONE_ID" \
  "$RANCHER_VER"

log "gateway-migration.sh completed successfully."
log "RKE2 server bootstrap completed successfully."