#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------------------------
# Phase 1: Logging Setup & Fail-Safe Traps
# ------------------------------------------------------------------------------

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

trap 'log "ERROR: gateway-migration.sh failed at line $LINENO"' ERR

# ------------------------------------------------------------------------------
# Phase 2: Required Inputs & Environment Validation
# ------------------------------------------------------------------------------
RANCHER_HOST="${1:?Rancher hostname must be passed as the first argument}"
CERT_MANAGER_VER="${2:?cert-manager version must be passed as the second argument}"
ROUTE53_ZONE_ID="${3:?Route 53 public hosted zone ID must be passed as the third argument}"
RANCHER_VER="${4:?Rancher chart version must be passed as the fourth argument}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:?LETSENCRYPT_EMAIL environment variable must be set}"

log "Phase 2: Required Inputs, Using Rancher hostname: ${RANCHER_HOST}"
log "Phase 2: Required Inputs, Using cert-manager version: ${CERT_MANAGER_VER}"
log "Phase 2: Required Inputs, Using Rancher chart version: ${RANCHER_VER}"

# ------------------------------------------------------------------------------
# Phase 3: Runtime Execution Environment Setup
# ------------------------------------------------------------------------------
export PATH="$PATH:/var/lib/rancher/rke2/bin:/usr/local/bin"
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------------------------
# Phase 4: Helper Utilities & Readiness Polling Functions
# ------------------------------------------------------------------------------
retry() {
  local n=0 max=5 delay=10

  until "$@"; do
    n=$((n + 1))

    if [ "$n" -ge "$max" ]; then
      log "Command failed after $n attempts: $*"
      return 1
    fi

    log "Attempt $n/$max failed, retrying in ${delay}s: $*"
    sleep "$delay"
  done
}

wait_for_k8s() {
  local attempts=0
  local max_attempts=30

  until kubectl get nodes &>/dev/null; do
    attempts=$((attempts + 1))

    if [ "$attempts" -ge "$max_attempts" ]; then
      log "ERROR: Kubernetes API did not become ready within timeout"
      return 1
    fi

    sleep 10
  done
}

# ------------------------------------------------------------------------------
# Phase 5: AWS CLI Tool Setup
# ------------------------------------------------------------------------------
if ! command -v aws &>/dev/null; then
  log "Phase 5: AWS CLI Tool Setup, Installing AWS CLI v2..."

  apt-get update -y
  apt-get install -y curl unzip

  retry curl -sfL \
    "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
    -o /tmp/awscliv2.zip

  unzip -o /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install

  rm -rf /tmp/awscliv2.zip /tmp/aws
else
  log "Phase 5: AWS CLI Tool Setup, AWS CLI already installed, skipping."
fi

# ------------------------------------------------------------------------------
# Phase 6: AWS Infrastructure Metadata Discovery
# ------------------------------------------------------------------------------
log "Phase 6: AWS Infrastructure Metadata Discovery, Fetching AWS region, instance ID, and VPC ID..."

IMDS_TOKEN=$(curl -sf -X PUT \
  "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

AWS_REGION=$(curl -sf \
  -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  "http://169.254.169.254/latest/meta-data/placement/region")

INSTANCE_ID=$(curl -sf \
  -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  "http://169.254.169.254/latest/meta-data/instance-id")

VPC_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION" \
  --query 'Reservations[0].Instances[0].VpcId' \
  --output text)

if [[ -z "$AWS_REGION" || -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  log "ERROR: Could not retrieve region or VPC ID"
  exit 1
fi

log "Phase 6: AWS Infrastructure Metadata Discovery, Instance ID: $INSTANCE_ID | Region: $AWS_REGION | VPC ID: $VPC_ID"

# ------------------------------------------------------------------------------
# Phase 7: RKE2 Ingress Engine Disabling
# ------------------------------------------------------------------------------
CONFIG_FILE=/etc/rancher/rke2/config.yaml

mkdir -p "$(dirname "$CONFIG_FILE")"
touch "$CONFIG_FILE"

if ! grep -Eq '^disable:' "$CONFIG_FILE"; then
  log "Phase 7: RKE2 Ingress Engine Disabling, Disabling built-in rke2-ingress-nginx..."

  cat <<'YAML' >> "$CONFIG_FILE"

disable:
  - rke2-ingress-nginx
YAML

  log "Phase 7: RKE2 Ingress Engine Disabling, Restarting rke2-server to apply the change..."
  systemctl restart rke2-server

  log "Phase 7: RKE2 Ingress Engine Disabling, Waiting for the Kubernetes API to recover..."
  wait_for_k8s
else
  log "Phase 7: RKE2 Ingress Engine Disabling, rke2-ingress-nginx already disabled in config, skipping restart."
fi

# ------------------------------------------------------------------------------
# Phase 8: AWS Load Balancer Controller Deployment
# ------------------------------------------------------------------------------
if ! kubectl get deployment -n kube-system aws-load-balancer-controller &>/dev/null; then
  log "Phase 8: AWS Load Balancer Controller Deployment, Installing AWS Load Balancer Controller..."

  retry helm repo add eks \
    https://aws.github.io/eks-charts \
    --force-update

  retry helm repo update

  retry helm upgrade --install aws-load-balancer-controller \
    eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName=rke2-cluster \
    --set region="$AWS_REGION" \
    --set vpcId="$VPC_ID" \
    --wait \
    --timeout 300s \
    --atomic
fi

log "Phase 8: AWS Load Balancer Controller Deployment, Waiting for AWS Load Balancer Controller..."

retry kubectl wait \
  --for=condition=Available \
  deployment/aws-load-balancer-controller \
  -n kube-system \
  --timeout=300s

# ------------------------------------------------------------------------------
# Phase 9: Cert-Manager Rollout Verification
# ------------------------------------------------------------------------------
log "Phase 9: Cert-Manager Rollout Verification, Verifying cert-manager deployment readiness..."

retry kubectl rollout status deployment/cert-manager \
  -n cert-manager \
  --timeout=300s

# ------------------------------------------------------------------------------
# Phase 10: Let's Encrypt Staging ClusterIssuer Setup
# ------------------------------------------------------------------------------
log "Phase 10: Let's Encrypt Staging ClusterIssuer Setup, creating staging ClusterIssuer..."

cat <<ISSUER | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: "$LETSENCRYPT_EMAIL"
    privateKeySecretRef:
      name: letsencrypt-staging-account-key
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: rancher-gateway
                namespace: cattle-system
                kind: Gateway
ISSUER

# ------------------------------------------------------------------------------
# Phase 11: Legacy Ingress Removal
# ------------------------------------------------------------------------------
log "Phase 11: Legacy Ingress Removal, Disabling Rancher's legacy Ingress..."

retry helm repo add rancher-stable \
  https://releases.rancher.com/server-charts/stable \
  --force-update

retry helm repo update

retry helm upgrade rancher \
  rancher-stable/rancher \
  -n cattle-system \
  --version "$RANCHER_VER" \
  --reuse-values \
  --set ingress.enabled=false \
  --wait \
  --timeout 600s \
  --atomic

kubectl delete ingress rancher \
  -n cattle-system \
  --ignore-not-found=true

# ------------------------------------------------------------------------------
# Phase 12: Traefik Gateway Controller Deployment
# ------------------------------------------------------------------------------
log "Phase 12: Traefik Gateway Controller Deployment, Installing Traefik..."

cat <<'VALUES' > /tmp/traefik-values.yaml
providers:
  kubernetesGateway:
    enabled: true

gateway:
  enabled: false

gatewayClass:
  enabled: true

ports:
  web:
    port: 80
    containerPort: 80
    exposedPort: 80

  websecure:
    port: 443
    containerPort: 443
    exposedPort: 443

securityContext:
  capabilities:
    drop:
      - ALL
    add:
      - NET_BIND_SERVICE
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false

service:
  enabled: true
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "instance"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
VALUES

retry helm repo add traefik \
  https://traefik.github.io/charts \
  --force-update

retry helm repo update

retry helm upgrade --install traefik traefik/traefik \
  -n traefik \
  --create-namespace \
  -f /tmp/traefik-values.yaml \
  --wait \
  --timeout 300s \
  --atomic

# ------------------------------------------------------------------------------
# Phase 13: Gateway & HTTPRoute Resources Provisioning
# ------------------------------------------------------------------------------
log "Phase 13: Gateway & HTTPRoute Resources Provisioning, Applying Gateway and HTTPRoute resources..."

cat <<GATEWAY > /tmp/rancher-gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: rancher-gateway
  namespace: cattle-system
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-staging
spec:
  gatewayClassName: traefik
  listeners:
    - name: http
      hostname: $RANCHER_HOST
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same

    - name: https
      hostname: $RANCHER_HOST
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - name: rancher-gateway-tls
            kind: Secret
      allowedRoutes:
        namespaces:
          from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: rancher-route
  namespace: cattle-system
spec:
  parentRefs:
    - name: rancher-gateway
      sectionName: http
    - name: rancher-gateway
      sectionName: https
  hostnames:
    - $RANCHER_HOST
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: rancher
          port: 80
GATEWAY

retry kubectl apply -f /tmp/rancher-gateway.yaml

# ------------------------------------------------------------------------------
# Phase 14: AWS Network Load Balancer (NLB) Discovery
# ------------------------------------------------------------------------------
log "Phase 14: AWS Network Load Balancer (NLB) Discovery, Waiting for Traefik LoadBalancer hostname..."

NLB_HOST=""
attempts=0
max_attempts=60

until [ -n "$NLB_HOST" ]; do
  NLB_HOST=$(kubectl get svc \
    -n traefik \
    traefik \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' \
    2>/dev/null || true)

  if [ -z "$NLB_HOST" ]; then
    attempts=$((attempts + 1))
    if [ "$attempts" -ge "$max_attempts" ]; then
      log "ERROR: Traefik LoadBalancer hostname did not appear within timeout"
      exit 1
    fi
    sleep 10
  fi
done

log "Phase 14: AWS Network Load Balancer (NLB) Discovery, Traefik NLB Hostname: $NLB_HOST"

NLB_ZONE_ID=""
attempts=0
max_attempts=30

until [ -n "$NLB_ZONE_ID" ]; do
  NLB_ZONE_ID=$(aws elbv2 describe-load-balancers \
    --region "$AWS_REGION" \
    --query "LoadBalancers[?DNSName=='$NLB_HOST'].CanonicalHostedZoneId | [0]" \
    --output text \
    2>/dev/null || true)

  if [ -z "$NLB_ZONE_ID" ] || [ "$NLB_ZONE_ID" = "None" ]; then
    NLB_ZONE_ID=""
    attempts=$((attempts + 1))
    if [ "$attempts" -ge "$max_attempts" ]; then
      log "ERROR: Could not resolve NLB hosted zone ID"
      exit 1
    fi
    sleep 10
  fi
done

# ------------------------------------------------------------------------------
# Phase 15: Public Route 53 Record Update
# ------------------------------------------------------------------------------
log "Phase 15: Public Route 53 Record Update, Updating public Route 53 record for $RANCHER_HOST..."

cat <<JSON > /tmp/change-batch.json
{
  "Comment": "Automated Gateway API cutover by RKE2 server",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$RANCHER_HOST",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "$NLB_ZONE_ID",
          "DNSName": "$NLB_HOST",
          "EvaluateTargetHealth": true
        }
      }
    }
  ]
}
JSON

retry aws route53 change-resource-record-sets \
  --hosted-zone-id "$ROUTE53_ZONE_ID" \
  --change-batch file:///tmp/change-batch.json

rm -f /tmp/change-batch.json

log "Phase 15: Public Route 53 record successfully created/updated."
log "Phase 15: $RANCHER_HOST -> $NLB_HOST"

# ------------------------------------------------------------------------------
# Phase 16: Certificate Readiness Validation
# ------------------------------------------------------------------------------
log "Phase 16: Certificate Readiness Validation, Waiting for rancher-gateway-tls to become Ready=True..."

attempts=0
max_attempts=120

until [ "$(kubectl get certificate rancher-gateway-tls \
  -n cattle-system \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
  2>/dev/null || true)" = "True" ]; do

  attempts=$((attempts + 1))
  if [ "$attempts" -ge "$max_attempts" ]; then
    log "ERROR: rancher-gateway-tls did not become Ready=True within timeout"
    kubectl describe certificate rancher-gateway-tls -n cattle-system || true
    exit 1
  fi
  sleep 10
done

log "Phase 16: Certificate Readiness Validation, Certificate rancher-gateway-tls is Ready=True."

# ------------------------------------------------------------------------------
# Phase 17: Local Gateway Health Verification
# ------------------------------------------------------------------------------
NODE_PORT=$(kubectl get svc -n traefik traefik -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')

attempts=0
max_attempts=60
healthy=false

until [ "$healthy" = true ]; do
  status=$(curl -sk \
    -o /dev/null \
    -w '%{http_code}' \
    --connect-timeout 5 \
    --resolve "$RANCHER_HOST:$NODE_PORT:127.0.0.1" \
    "https://$RANCHER_HOST:$NODE_PORT/" \
    || true)

  if [ "$status" = "200" ] || [ "$status" = "301" ] || [ "$status" = "302" ] || [ "$status" = "401" ]; then
    healthy=true
    break
  fi

  attempts=$((attempts + 1))
  if [ "$attempts" -ge "$max_attempts" ]; then
    log "ERROR: Gateway HTTPS health check failed"
    exit 1
  fi
  sleep 5
done

log "Phase 17: Local Gateway Health Verification, Gateway HTTPS health check passed (HTTP $status)."
log "Phase 17: Local Gateway Health Verification, gateway-migration.sh finished successfully."