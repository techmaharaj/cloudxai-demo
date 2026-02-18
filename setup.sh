#!/usr/bin/env bash
# ============================================================
# CloudXAI Demo - Setup Script
# Sets up a kind cluster with all demo components
# Run time: ~5 minutes
# ============================================================
set -euo pipefail

CLUSTER_NAME="cloudxai-demo"
NAMESPACE="cloudxai"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

banner() { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
ok()     { echo -e "  ${GREEN}✅ $1${NC}"; }
info()   { echo -e "  ${YELLOW}ℹ️  $1${NC}"; }
step()   { echo -e "  ${CYAN}→ $1${NC}"; }

# ── Prerequisites check ──────────────────────────────────────────────────────
banner "Checking prerequisites"

for cmd in kind kubectl helm python3; do
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "  ${RED}❌ '$cmd' not found. Please install it first.${NC}"
    exit 1
  fi
  ok "$cmd found"
done

if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo -e "  ${RED}❌ OPENAI_API_KEY not set. Run: export OPENAI_API_KEY=sk-...${NC}"
  exit 1
fi
ok "OPENAI_API_KEY is set"

# ── Python dependencies ──────────────────────────────────────────────────────
banner "Installing Python dependencies"
step "Installing from requirements.txt..."
pip install -q -r "$SCRIPT_DIR/requirements.txt"
ok "Python dependencies installed"

# ── Kind cluster ─────────────────────────────────────────────────────────────
banner "Creating kind cluster: $CLUSTER_NAME"

# Prepare audit policy for kind mount
step "Preparing audit policy..."
mkdir -p /tmp/cloudxai-audit-logs
cp "$SCRIPT_DIR/after/k8s/audit-policy.yaml" /tmp/cloudxai-audit-policy.yaml
ok "Audit policy copied to /tmp/cloudxai-audit-policy.yaml"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  info "Cluster '$CLUSTER_NAME' already exists, skipping creation"
else
  step "Creating cluster (this takes ~2 minutes)..."
  kind create cluster --config "$SCRIPT_DIR/kind-config.yaml" --wait 120s
  ok "Cluster created"
fi

kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null
ok "Cluster is reachable"

# ── Namespace ─────────────────────────────────────────────────────────────────
banner "Setting up namespace"
kubectl apply -f "$SCRIPT_DIR/after/k8s/namespace.yaml"
ok "Namespace '$NAMESPACE' created"

# ── RBAC ─────────────────────────────────────────────────────────────────────
banner "Applying RBAC"
kubectl apply -f "$SCRIPT_DIR/after/k8s/rbac.yaml"
ok "ServiceAccount and RBAC applied"

# ── Deploy target application ─────────────────────────────────────────────────
banner "Deploying demo application"
kubectl apply -f "$SCRIPT_DIR/after/k8s/deployment.yaml"
step "Waiting for demo-app to be ready..."
kubectl rollout status deployment/demo-app -n "$NAMESPACE" --timeout=60s
ok "demo-app is running"

# ── Deploy Jaeger ─────────────────────────────────────────────────────────────
banner "Deploying Jaeger (tracing backend)"
kubectl apply -f "$SCRIPT_DIR/after/k8s/jaeger.yaml"
step "Waiting for Jaeger to be ready..."
kubectl rollout status deployment/jaeger -n "$NAMESPACE" --timeout=90s
ok "Jaeger is running"

# ── Install Kyverno ───────────────────────────────────────────────────────────
banner "Installing Kyverno (policy engine)"

if ! helm repo list 2>/dev/null | grep -q "kyverno"; then
  step "Adding Kyverno Helm repo..."
  helm repo add kyverno https://kyverno.github.io/kyverno/
  helm repo update
fi

if helm status kyverno -n kyverno &>/dev/null; then
  info "Kyverno already installed, skipping"
else
  step "Installing Kyverno..."
  kubectl create namespace kyverno --dry-run=client -o yaml | kubectl apply -f -
  helm install kyverno kyverno/kyverno \
    --namespace kyverno \
    --set admissionController.replicas=1 \
    --set backgroundController.enabled=false \
    --set cleanupController.enabled=false \
    --set reportsController.enabled=false \
    --wait --timeout 120s
  ok "Kyverno installed"
fi

step "Waiting for Kyverno webhook to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=kyverno -n kyverno --timeout=90s
ok "Kyverno is ready"

# ── Apply Kyverno policies ────────────────────────────────────────────────────
banner "Applying accountability policies"

info "NOTE: Policies are NOT applied yet (that's the demo!)"
info "Run the BEFORE demo first, then apply policies with:"
info "  kubectl apply -f after/policies/"
echo ""
info "Or let demo.sh guide you step by step."

# ── Port forwarding setup ─────────────────────────────────────────────────────
banner "Setup complete! 🎉"

echo ""
echo -e "${GREEN}  Everything is ready. Here's what was deployed:${NC}"
echo ""
echo -e "  ${CYAN}Namespace:${NC}  cloudxai"
echo -e "  ${CYAN}App:${NC}        demo-app (nginx, 2 replicas)"
echo -e "  ${CYAN}Tracing:${NC}    Jaeger (in-cluster)"
echo -e "  ${CYAN}Policies:${NC}   Kyverno installed (policies not yet applied)"
echo ""
echo -e "${YELLOW}  Next steps:${NC}"
echo ""
echo -e "  1. Start Jaeger UI port-forward (in a separate terminal):"
echo -e "     ${CYAN}kubectl port-forward svc/jaeger 16686:16686 -n cloudxai${NC}"
echo ""
echo -e "  2. Open Jaeger UI:"
echo -e "     ${CYAN}open http://localhost:16686${NC}"
echo ""
echo -e "  3. Run the demo:"
echo -e "     ${CYAN}./demo.sh${NC}"
echo ""
