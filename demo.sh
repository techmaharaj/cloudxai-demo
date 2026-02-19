#!/usr/bin/env bash
# ============================================================
# Accountable AI on Kubernetes - Platform Engineering Demo
# "How Platforms Enforce What RBAC Can't"
# ============================================================
set -euo pipefail

NAMESPACE="cloudxai"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

pause() {
  echo ""
  echo -e "${YELLOW}  ⏸  Press ENTER to continue...${NC}"
  read -r
}

banner() {
  echo ""
  echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
  printf "${BLUE}║${NC}  ${BOLD}%-60s${NC}${BLUE}║${NC}\n" "$1"
  echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
}

section() {
  echo ""
  echo -e "${MAGENTA}┌─────────────────────────────────────────────────────────────┐${NC}"
  echo -e "${MAGENTA}│${NC}  $1"
  echo -e "${MAGENTA}└─────────────────────────────────────────────────────────────┘${NC}"
}

cmd() { echo -e "\n  ${GREEN}\$ $1${NC}"; }

# ─────────────────────────────────────────────────────────────────────────────
banner "Accountable AI on Kubernetes"
echo ""
echo -e "  ${CYAN}Talk:${NC} How Platforms Enforce What RBAC Can't"
echo -e "  ${CYAN}Scenario:${NC} Your platform team provides AI Operations as a Service."
echo -e "  ${CYAN}Problem:${NC} When the platform AI acts, audit logs lose the human behind it."
# ─────────────────────────────────────────────────────────────────────────────

pause

# ═══════════════════════════════════════════════════════════════════════════════
banner "PART 1: The Accountability Gap"
# ═══════════════════════════════════════════════════════════════════════════════

section "1.1 - Deploy Platform AI Service (No Accountability)"
echo ""
echo "  Your platform provides an AI service developers invoke to manage workloads."
echo "  This is the unaccountable version — no user tracking, no traces, no boundaries."
cmd "kubectl apply -f before/k8s/deployment.yaml"
kubectl apply -f "$SCRIPT_DIR/before/k8s/deployment.yaml"
echo ""
cmd "kubectl get deployment demo-app -n default"
kubectl get deployment demo-app -n default 2>/dev/null || echo "  (deploying...)"
kubectl rollout status deployment/demo-app -n default --timeout=60s

pause

section "1.2 - Developer Invokes Platform AI Service"
echo ""
echo "  Alice runs: platform-ai scale payment-service"
echo "  Internally, the platform AI agent receives her request and acts..."
cmd "python3 before/agent.py"
echo ""
python3 "$SCRIPT_DIR/before/agent.py"

pause

section "1.3 - What the Audit Log Shows"
echo ""
cat << 'AUDITLOG'
  📋 Kubernetes Audit Log:
  ─────────────────────────────────────────────────────────────
  {
    "verb": "patch",
    "user": {
      "username": "system:serviceaccount:default:ai-ops-agent"
    },
    "objectRef": {
      "resource": "deployments",
      "name": "demo-app",
      "namespace": "default"
    },
    "responseStatus": { "code": 200 }
  }
  ─────────────────────────────────────────────────────────────
AUDITLOG
echo ""
echo -e "  ${RED}❌ WHO invoked the platform service?${NC}  Unknown. Just a service account."
echo -e "  ${RED}❌ WHY did the AI choose that replica count?${NC}  No reasoning captured."
echo -e "  ${RED}❌ WHAT boundaries applied?${NC}  RBAC allowed it — no runtime context."
echo ""
echo "  This is the accountability gap RBAC cannot close."

pause

# ═══════════════════════════════════════════════════════════════════════════════
banner "PART 2: Three Accountability Patterns"
# ═══════════════════════════════════════════════════════════════════════════════

section "2.1 - The Accountable Platform Service"
echo ""
echo "  Same platform AI service, now running in the 'cloudxai' namespace"
echo "  with all three accountability patterns layered on top."
cmd "kubectl get all -n cloudxai"
kubectl get all -n "$NAMESPACE"

pause

section "2.2 - Start Jaeger (Decision Trace Viewer)"
echo ""
echo "  Jaeger will show the full reasoning chain for every AI action."
cmd "kubectl port-forward svc/jaeger 16686:16686 4318:4318 -n cloudxai &"
echo ""
kubectl port-forward svc/jaeger 16686:16686 4318:4318 -n "$NAMESPACE" &>/dev/null &
PF_PID=$!
sleep 2
echo -e "  ${GREEN}✅ Jaeger UI:${NC}   http://localhost:16686"
echo -e "  ${GREEN}✅ OTLP ingest:${NC} http://localhost:4318"

pause

# ─── Pattern 1 ────────────────────────────────────────────────────────────────
section "2.3 - Pattern 1: User Context Propagation"
echo ""
echo "  Policy: Every AI action MUST carry the identity of who invoked it."
echo "  Without this annotation, the platform blocks the action entirely."
cmd "cat after/policies/require-user-context.yaml"
echo ""
cat "$SCRIPT_DIR/after/policies/require-user-context.yaml"
echo ""
cmd "kubectl apply -f after/policies/require-user-context.yaml"
kubectl apply -f "$SCRIPT_DIR/after/policies/require-user-context.yaml"

pause

# ─── Pattern 2 ────────────────────────────────────────────────────────────────
section "2.4 - Pattern 2: Dynamic Permission Boundaries"
echo ""
echo "  Policy: Platform enforces context-aware replica limits."
echo "  RBAC can only allow or deny all scaling — it cannot express bounds like this."
cmd "cat after/policies/replica-bounds.yaml"
echo ""
cat "$SCRIPT_DIR/after/policies/replica-bounds.yaml"
echo ""
cmd "kubectl apply -f after/policies/replica-bounds.yaml"
kubectl apply -f "$SCRIPT_DIR/after/policies/replica-bounds.yaml"

pause

section "2.5 - Test: Boundary Enforcement"
echo ""
echo "  Alice asks the platform AI to scale to 10 replicas. Policy max is 5."
cmd "python3 after/agent.py --user alice@company.com --replicas 10"
echo ""
python3 "$SCRIPT_DIR/after/agent.py" --user alice@company.com --replicas 10 || true
echo ""
echo -e "  ${GREEN}✅ Platform blocked overstepping. RBAC alone couldn't do this.${NC}"
echo "     RBAC would have allowed any replica count the service account can patch."

pause

# ─── Pattern 3 ────────────────────────────────────────────────────────────────
section "2.6 - Pattern 3: Decision Attribution"
echo ""
echo "  Alice invokes the platform AI service. Full trace captured end-to-end:"
echo "  metrics observed → LLM reasoning → policy check → action taken."
cmd "python3 after/agent.py --user alice@company.com"
echo ""
python3 "$SCRIPT_DIR/after/agent.py" --user alice@company.com

pause

# ═══════════════════════════════════════════════════════════════════════════════
banner "PART 3: Accountability in Action"
# ═══════════════════════════════════════════════════════════════════════════════

section "3.1 - What the Deployment Knows Now"
echo ""
echo "  Platform writes full accountability metadata to every action it takes:"
cmd "kubectl get deployment demo-app -n cloudxai -o jsonpath='{.metadata.annotations}' | python3 -m json.tool"
echo ""
kubectl get deployment demo-app -n "$NAMESPACE" \
  -o jsonpath='{.metadata.annotations}' 2>/dev/null | python3 -m json.tool || \
  echo "  (Run the agent first to populate annotations)"

pause

section "3.2 - The Decision Trace in Jaeger"
echo ""
echo "  Open: http://localhost:16686"
echo "  Select service: ai-scaling-agent"
echo ""
echo "  Each trace shows the complete chain:"
echo "    agent.scaling_cycle"
echo "      ├── metrics.observe        → CPU observed, current replicas"
echo "      ├── llm.reasoning          → exact LLM prompt + response"
echo "      └── k8s.scale_deployment   → action taken, result"
echo ""
echo "  Every span tagged with: triggered-by: alice@company.com"

pause

section "3.3 - The Forensics Moment"
echo ""
echo "  Incident at 3am: prod auto-scaled, cost spiked."
echo ""
echo "  Without accountability:"
echo "    → Audit log: 'service-account:ai-ops-agent' — dead end."
echo ""
echo "  With these three patterns:"
echo "    → Annotation: accountability.ai/triggered-by: alice@company.com"
echo "    → Annotation: accountability.ai/trace-id: <id>"
echo "    → Open Jaeger trace → CPU was 84% → LLM recommended scale-up → policy allowed it"
echo "    → Full chain. Accountable. Done."

pause

# ─────────────────────────────────────────────────────────────────────────────
banner "Demo Complete"
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${GREEN}Platform can now answer:${NC}"
echo ""
echo -e "    ${GREEN}✅ WHO${NC}  invoked the AI service → alice@company.com"
echo -e "    ${GREEN}✅ WHAT${NC} boundaries the platform enforced → 2-5 replicas (Kyverno)"
echo -e "    ${GREEN}✅ WHY${NC}  the AI made that decision → trace ID links to full reasoning"
echo ""
echo -e "  ${YELLOW}Cleanup:${NC} ./teardown.sh"
echo ""

# Kill port-forwards
kill $PF_PID 2>/dev/null || true
