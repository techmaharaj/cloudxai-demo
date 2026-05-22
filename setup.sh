#!/usr/bin/env bash
# ============================================================
# GrafanaCon Demo - Setup Script
# Works with an existing Docker Desktop Kubernetes cluster.
# Run time: ~3-4 minutes
# ============================================================
set -euo pipefail

NAMESPACE="cloudxai"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/.env" ]; then
  source "$SCRIPT_DIR/.env"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

banner() { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
ok()     { echo -e "  ${GREEN}✅ $1${NC}"; }
info()   { echo -e "  ${YELLOW}ℹ️  $1${NC}"; }
step()   { echo -e "  ${CYAN}→ $1${NC}"; }

# ── Prerequisites check ──────────────────────────────────────────────────────
banner "Checking prerequisites"

for cmd in kubectl helm python3; do
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
if [ ! -d "$SCRIPT_DIR/venv" ]; then
  step "Creating Python virtual environment..."
  python3 -m venv "$SCRIPT_DIR/venv"
fi
step "Activating virtual environment..."
source "$SCRIPT_DIR/venv/bin/activate"
step "Installing from requirements.txt..."
pip install -q -r "$SCRIPT_DIR/requirements.txt"
ok "Python dependencies installed"

# ── Switch to Docker Desktop context ─────────────────────────────────────────
banner "Connecting to Docker Desktop cluster"
step "Switching kubectl context to docker-desktop..."
kubectl config use-context docker-desktop
kubectl cluster-info >/dev/null
ok "Connected to Docker Desktop cluster"

# ── Namespace ─────────────────────────────────────────────────────────────────
banner "Setting up namespace"
kubectl apply -f "$SCRIPT_DIR/after/k8s/namespace.yaml"
ok "Namespace '$NAMESPACE' created"

# ── RBAC ─────────────────────────────────────────────────────────────────────
banner "Applying RBAC"
kubectl apply -f "$SCRIPT_DIR/after/k8s/rbac.yaml"
ok "ServiceAccount and RBAC applied"

# ── Deploy target application (after scenario) ────────────────────────────────
banner "Deploying demo application (after scenario → cloudxai namespace)"
kubectl apply -f "$SCRIPT_DIR/after/k8s/deployment.yaml"
step "Waiting for demo-app to be ready..."
kubectl rollout status deployment/demo-app -n "$NAMESPACE" --timeout=60s
ok "demo-app is running in cloudxai namespace"

# ── Deploy target application (before scenario) ───────────────────────────────
banner "Deploying demo application (before scenario → default namespace)"
kubectl apply -f "$SCRIPT_DIR/before/k8s/deployment.yaml"
step "Waiting for before demo-app to be ready..."
kubectl rollout status deployment/demo-app -n default --timeout=60s
ok "demo-app is running in default namespace"

# ── Deploy Grafana & Tempo ─────────────────────────────────────────────────────────────
banner "Deploying Grafana & Tempo (tracing backend)"
kubectl apply -f "$SCRIPT_DIR/after/k8s/grafana-tempo.yaml"
step "Waiting for Tempo to be ready..."
kubectl rollout status deployment/tempo -n "$NAMESPACE" --timeout=90s
step "Waiting for Grafana to be ready..."
kubectl rollout status deployment/grafana -n "$NAMESPACE" --timeout=90s
ok "Grafana & Tempo are running"
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
  step "Installing Kyverno (lightweight, single replica)..."
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

step "Waiting for Kyverno admission controller to be ready..."
kubectl rollout status deployment/kyverno-admission-controller -n kyverno --timeout=120s
ok "Kyverno is ready"

# ── Policies intentionally NOT applied yet (demo flow) ───────────────────────
banner "Setup complete! 🎉"

echo ""
echo -e "${GREEN}  Everything is ready. Here's what was deployed:${NC}"
echo ""
echo -e "  ${CYAN}Context:${NC}    docker-desktop"
echo -e "  ${CYAN}Namespace:${NC}  cloudxai  (after scenario — Grafana, Tempo, demo-app, RBAC)"
echo -e "  ${CYAN}Namespace:${NC}  default   (before scenario — plain demo-app)"
echo -e "  ${CYAN}Tracing:${NC}    Grafana & Tempo in cloudxai namespace"
echo -e "  ${CYAN}Policies:${NC}   Kyverno installed — policies NOT yet applied (that's the demo!)"
echo ""
echo -e "${YELLOW}  Before running the demo, open a new terminal and run:${NC}"
echo ""
echo -e "     ${CYAN}kubectl port-forward svc/grafana 3000:3000 -n cloudxai & \\${NC}"
echo -e "     ${CYAN}kubectl port-forward svc/tempo 4318:4318 -n cloudxai${NC}"
echo ""
echo -e "${YELLOW}  Then start the demo:${NC}"
echo ""
echo -e "     ${CYAN}./demo.sh${NC}"
echo ""
