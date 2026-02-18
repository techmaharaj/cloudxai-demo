#!/usr/bin/env bash
# ============================================================
# CloudXAI Demo Script
# "Accountable AI on Kubernetes: How Platforms Enforce What RBAC Can't"
#
# Run time: ~10 minutes
# Prerequisites: ./setup.sh must have been run first
# ============================================================
set -euo pipefail

NAMESPACE="cloudxai"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
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
  echo -e "${BLUE}║${NC}  ${BOLD}$1${NC}"
  echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
}

section() {
  echo ""
  echo -e "${MAGENTA}┌─────────────────────────────────────────────────────────────┐${NC}"
  echo -e "${MAGENTA}│${NC}  $1"
  echo -e "${MAGENTA}└─────────────────────────────────────────────────────────────┘${NC}"
}

speak() { echo -e "  ${CYAN}🎤 SPEAKER NOTE: $1${NC}"; }
cmd()   { echo -e "  ${GREEN}$ $1${NC}"; }
warn()  { echo -e "  ${RED}⚠️  $1${NC}"; }
ok()    { echo -e "  ${GREEN}✅ $1${NC}"; }

# ─────────────────────────────────────────────────────────────────────────────
banner "CloudXAI Demo: Accountable AI on Kubernetes"
# ─────────────────────────────────────────────────────────────────────────────

speak "Welcome. Today I'm going to show you a problem that every platform team"
speak "faces when AI agents start acting on Kubernetes - and three patterns to fix it."
speak ""
speak "The scenario: an AI agent that auto-scales deployments based on CPU metrics."
speak "Sounds useful. But when something goes wrong, can you answer:"
speak "  WHO triggered the agent? WHAT boundaries applied? WHY did it decide that?"

pause

# ─────────────────────────────────────────────────────────────────────────────
banner "PART 1: The Problem (BEFORE)"
# ─────────────────────────────────────────────────────────────────────────────

section "Step 1.1 - Deploy the app to the DEFAULT namespace (no accountability)"

speak "First, let's deploy our demo app to the default namespace."
speak "This is the 'before' state - no accountability features."
echo ""
cmd "kubectl apply -f before/k8s/deployment.yaml"
kubectl apply -f "$SCRIPT_DIR/before/k8s/deployment.yaml"
echo ""
cmd "kubectl get deployment demo-app -n default"
kubectl get deployment demo-app -n default 2>/dev/null || echo "  (deploying...)"
kubectl rollout status deployment/demo-app -n default --timeout=60s

pause

section "Step 1.2 - Run the agent WITHOUT accountability"

speak "Now let's run the AI agent in its broken state."
speak "Watch what happens - it scales the deployment, but..."
echo ""
cmd "python3 before/agent.py"
echo ""
python3 "$SCRIPT_DIR/before/agent.py"

pause

section "Step 1.3 - Look at the audit log (the USELESS version)"

speak "Here's what the Kubernetes audit log shows for that action."
speak "This is what your security team sees at 2am when something goes wrong."
echo ""

# Show simulated audit log output (what it would look like)
cat << 'EOF'
  📋 Kubernetes Audit Log Entry:
  ─────────────────────────────────────────────────────────────
  {
    "kind": "Event",
    "apiVersion": "audit.k8s.io/v1",
    "verb": "patch",
    "user": {
      "username": "system:serviceaccount:default:default",
      "groups": ["system:serviceaccounts", "system:authenticated"]
    },
    "objectRef": {
      "resource": "deployments",
      "name": "demo-app",
      "namespace": "default"
    },
    "responseStatus": { "code": 200 }
  }
  ─────────────────────────────────────────────────────────────
EOF

echo ""
warn "Questions you CANNOT answer from this log:"
echo "  ❓ WHO triggered this agent? (just 'default' service account)"
echo "  ❓ WHY did it choose that replica count?"
echo "  ❓ Was this within approved boundaries?"
echo "  ❓ What metrics drove this decision?"
echo ""
speak "This is the accountability gap. RBAC told us the service account CAN patch"
speak "deployments. But it can't tell us WHO authorized this action, or WHY."

pause

# ─────────────────────────────────────────────────────────────────────────────
banner "PART 2: The Fix (AFTER) - Three Accountability Patterns"
# ─────────────────────────────────────────────────────────────────────────────

speak "Now let's add the three accountability patterns."
speak "Everything runs in the 'cloudxai' namespace - one kubectl delete and it's gone."

section "Step 2.1 - Verify the after-scenario app is running"

echo ""
cmd "kubectl get all -n cloudxai"
kubectl get all -n "$NAMESPACE"

pause

section "Step 2.2 - Start Jaeger UI (open in a new terminal if not already running)"

speak "Jaeger is our tracing backend. It will show us the full decision chain."
echo ""
cmd "kubectl port-forward svc/jaeger 16686:16686 -n cloudxai &"
echo ""
echo "  Starting port-forward in background..."
kubectl port-forward svc/jaeger 16686:16686 -n "$NAMESPACE" &>/dev/null &
PF_PID=$!
sleep 2
ok "Jaeger UI available at: http://localhost:16686"
echo ""
speak "Open http://localhost:16686 in your browser now."
speak "It's empty - no traces yet. We'll come back to this."

pause

# ─────────────────────────────────────────────────────────────────────────────
section "Step 2.3 - Pattern 1 + 2: Apply Kyverno Policies"
# ─────────────────────────────────────────────────────────────────────────────

speak "Pattern 1: Every agent action MUST include user identity."
speak "Pattern 2: Agent can ONLY scale between 2 and 5 replicas."
speak "These are things RBAC literally cannot express."
echo ""
cmd "cat after/policies/require-user-context.yaml"
echo ""
cat "$SCRIPT_DIR/after/policies/require-user-context.yaml"
echo ""

pause

cmd "cat after/policies/replica-bounds.yaml"
echo ""
cat "$SCRIPT_DIR/after/policies/replica-bounds.yaml"
echo ""

pause

cmd "kubectl apply -f after/policies/"
kubectl apply -f "$SCRIPT_DIR/after/policies/"
echo ""
ok "Policies applied. Now let's test them."

pause

# ─────────────────────────────────────────────────────────────────────────────
section "Step 2.4 - Test Policy Blocking (replica count too high)"
# ─────────────────────────────────────────────────────────────────────────────

speak "Let's try to scale to 10 replicas. The policy allows max 5."
speak "Watch Kyverno block this - with a clear reason."
echo ""
cmd "python3 after/agent.py --user alice@company.com --replicas 10"
echo ""
python3 "$SCRIPT_DIR/after/agent.py" --user alice@company.com --replicas 10 || true

pause

# ─────────────────────────────────────────────────────────────────────────────
section "Step 2.5 - Pattern 3: Run the full accountable agent"
# ─────────────────────────────────────────────────────────────────────────────

speak "Now let's run the full agent - with user context, LLM reasoning, and tracing."
speak "This time, Alice is the user. Every action will be attributed to her."
echo ""
cmd "python3 after/agent.py --user alice@company.com"
echo ""
python3 "$SCRIPT_DIR/after/agent.py" --user alice@company.com

pause

# ─────────────────────────────────────────────────────────────────────────────
section "Step 2.6 - The USEFUL audit log"
# ─────────────────────────────────────────────────────────────────────────────

speak "Now look at what the deployment annotations show."
speak "This is what your audit log can now reference."
echo ""
cmd "kubectl get deployment demo-app -n cloudxai -o jsonpath='{.metadata.annotations}' | python3 -m json.tool"
echo ""
kubectl get deployment demo-app -n "$NAMESPACE" -o jsonpath='{.metadata.annotations}' 2>/dev/null | python3 -m json.tool || \
  echo "  (Run the agent first to populate annotations)"

pause

# ─────────────────────────────────────────────────────────────────────────────
section "Step 2.7 - View traces in Jaeger"
# ─────────────────────────────────────────────────────────────────────────────

speak "Now open Jaeger: http://localhost:16686"
speak "Select service: ai-scaling-agent"
speak "You'll see the full trace:"
speak "  agent.scaling_cycle"
speak "    └── metrics.observe       (what CPU was observed)"
speak "    └── llm.reasoning         (what OpenAI decided and why)"
speak "    └── k8s.scale_deployment  (what action was taken)"
echo ""
echo -e "  ${CYAN}🌐 Open: http://localhost:16686${NC}"
echo ""
echo "  Each span contains:"
echo "    • agent.triggered_by  = alice@company.com"
echo "    • metrics.cpu_percent = the observed CPU value"
echo "    • llm.reasoning       = the exact LLM explanation"
echo "    • llm.raw_response    = the full OpenAI response"
echo "    • k8s.replicas.*      = before and after replica counts"

pause

# ─────────────────────────────────────────────────────────────────────────────
section "Step 2.8 - BONUS: Interactive chat with the agent"
# ─────────────────────────────────────────────────────────────────────────────

speak "Finally - you can actually TALK to the agent during the demo."
speak "Ask it: 'Why did you scale up?' or 'What would you do if CPU hits 95%?'"
echo ""
echo -e "  ${YELLOW}To start chat mode, run:${NC}"
cmd "python3 after/agent.py --user alice@company.com --chat"
echo ""
echo "  Type 'scale' to trigger a live scaling action from within the chat."
echo "  Type 'exit' to quit."
echo ""

read -p "  Start chat mode now? [y/N] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
  python3 "$SCRIPT_DIR/after/agent.py" --user alice@company.com --chat
fi

# ─────────────────────────────────────────────────────────────────────────────
banner "Demo Complete! 🎉"
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}  Summary of what we demonstrated:${NC}"
echo ""
echo "  Pattern 1: User Context Propagation"
echo "    → Every agent action annotated with alice@company.com"
echo "    → Audit logs now show the human, not just the service account"
echo ""
echo "  Pattern 2: Dynamic Permission Boundaries"
echo "    → Kyverno blocked scaling to 10 replicas (max is 5)"
echo "    → RBAC would have allowed it - policies add runtime context"
echo ""
echo "  Pattern 3: Decision Attribution"
echo "    → Full trace in Jaeger: metrics → LLM reasoning → action"
echo "    → Trace ID links audit log to the exact reasoning chain"
echo ""
echo -e "${YELLOW}  Cleanup:${NC}"
cmd "./teardown.sh"
echo ""

# Kill port-forward
kill $PF_PID 2>/dev/null || true
