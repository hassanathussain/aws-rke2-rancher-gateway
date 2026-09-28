#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------------------------
# Logging Setup & Fail-Safe Traps
# ------------------------------------------------------------------------------
exec > >(tee -a /var/log/user-data-rke2.log) 2>&1
trap 'log "ERROR: script failed at line $LINENO"' ERR

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

# ------------------------------------------------------------------------------
# Version Configuration (Injected via Terraform templatefile)
# ------------------------------------------------------------------------------
RKE2_VERSION="${rke2_version}"

# ------------------------------------------------------------------------------
# Helper Functions
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
# Host Firewall Configuration
# ------------------------------------------------------------------------------
log "Disabling UFW host firewall"
systemctl disable --now ufw 2>/dev/null || true

# ------------------------------------------------------------------------------
# Get EC2 identity for Kubernetes providerID
# ------------------------------------------------------------------------------
log "Fetching EC2 instance identity..."
imds_token=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

INSTANCE_ID=$(curl -sf \
  -H "X-aws-ec2-metadata-token: $imds_token" \
  http://169.254.169.254/latest/meta-data/instance-id)

AWS_AZ=$(curl -sf \
  -H "X-aws-ec2-metadata-token: $imds_token" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)

if [[ -z "$INSTANCE_ID" || -z "$AWS_AZ" ]]; then
  log "ERROR: Could not retrieve instance ID or availability zone"
  exit 1
fi

log "Instance ID: $INSTANCE_ID | AZ: $AWS_AZ"

# ------------------------------------------------------------------------------
# Download & Install RKE2 Agent Binary
# ------------------------------------------------------------------------------
log "Installing RKE2 agent $RKE2_VERSION"
retry curl -sfL https://get.rke2.io -o /tmp/rke2-install.sh
chmod +x /tmp/rke2-install.sh
INSTALL_RKE2_TYPE="agent" INSTALL_RKE2_VERSION="$RKE2_VERSION" /tmp/rke2-install.sh

systemctl enable rke2-agent.service

# ------------------------------------------------------------------------------
# Wait for RKE2 Server Supervisor Endpoint Connectivity
# ------------------------------------------------------------------------------
log "Checking connectivity to RKE2 server supervisor on ${server_private_ip}:9345..."
attempts=0
max_attempts=60
until curl -sk --connect-timeout 5 "https://${server_private_ip}:9345/ping" &>/dev/null; do
  attempts=$((attempts + 1))
  if [ "$attempts" -ge "$max_attempts" ]; then
    log "ERROR: RKE2 server port 9345 unreachable on ${server_private_ip}"
    exit 1
  fi
  log "Waiting for port 9345 on ${server_private_ip}... (Attempt $attempts/$max_attempts)"
  sleep 10
done

log "RKE2 supervisor endpoint is reachable."

# ------------------------------------------------------------------------------
# Join Cluster (Write Agent Configuration with AWS providerID)
# ------------------------------------------------------------------------------
log "Writing RKE2 agent configuration..."
mkdir -p /etc/rancher/rke2
cat > /etc/rancher/rke2/config.yaml <<EOF
server: https://${server_private_ip}:9345
token: "${rke2_token}"
cloud-provider-name: "aws"
node-name: "ip-$(hostname -I | awk '{print $1}' | tr '.' '-')"
kubelet-arg:
  - "provider-id=aws:///$AWS_AZ/$INSTANCE_ID"
EOF
chmod 600 /etc/rancher/rke2/config.yaml

# ------------------------------------------------------------------------------
# Start Agent Service & Verify Node Registration
# ------------------------------------------------------------------------------
log "Starting rke2-agent service..."
systemctl start rke2-agent.service

log "Verifying rke2-agent is active..."
attempts=0
max_attempts=30   # 5 minutes
until systemctl is-active --quiet rke2-agent; do
  attempts=$((attempts + 1))
  if [ "$attempts" -ge "$max_attempts" ]; then
    log "ERROR: rke2-agent did not become active within timeout"
    journalctl -u rke2-agent --no-pager | tail -n 50
    exit 1
  fi
  sleep 10
done

log "rke2-agent is active. Node should register with providerID: aws:///$AWS_AZ/$INSTANCE_ID"