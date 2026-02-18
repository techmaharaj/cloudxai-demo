# Accountable AI on Kubernetes
### CloudXAI Conference Demo

> **Talk:** "Accountable AI on Kubernetes: How Platforms Enforce What RBAC Can't"  
> **Demo duration:** ~10 minutes  
> **Setup time:** ~5 minutes

---

## The Problem

When AI agents act on Kubernetes, platforms lose accountability:

```
# What audit logs show today:
user: "system:serviceaccount:default:ai-agent"
verb: "patch"
resource: "deployments"

# Questions you CANNOT answer:
# ❓ WHO triggered this agent?
# ❓ WHY did it choose that replica count?
# ❓ Was this within approved boundaries?
```

RBAC controls **what** a service account can do. It cannot answer **who** authorized an autonomous action, **why** the agent made a specific decision, or **whether** the action was within contextual boundaries.

---

## The Solution: Three Accountability Patterns

| Pattern | What it solves | How |
|---------|---------------|-----|
| **1. User Context Propagation** | WHO triggered the agent | Annotations on every k8s action |
| **2. Dynamic Permission Boundaries** | WHAT limits apply at runtime | Kyverno policies (not RBAC) |
| **3. Decision Attribution** | WHY the agent made this choice | OpenTelemetry traces → Jaeger |

---

## Architecture

```
User (alice) ──→ Agent CLI ──→ Kubernetes API
                     │
              ┌──────▼──────┐
              │  Pattern 1   │  X-User-Id annotation on every PATCH
              │  User Context│  Audit log: triggered-by: alice@company.com
              └──────┬──────┘
                     │
              ┌──────▼──────┐
              │  Pattern 2   │  Kyverno validates replica bounds (2-5)
              │  Kyverno     │  Blocks: scale to 10 ❌  Allows: scale to 4 ✅
              └──────┬──────┘
                     │
              ┌──────▼──────┐
              │  Pattern 3   │  OTel spans: metrics → LLM reasoning → action
              │  Jaeger      │  Full trace linked to audit log via trace-id
              └─────────────┘
```

---

## Project Structure

```
cloudxai/
├── before/                    # ❌ No accountability (the problem)
│   ├── k8s/deployment.yaml   # Plain deployment, default namespace
│   └── agent.py              # Agent with no user context or tracing
│
├── after/                     # ✅ Full accountability (the solution)
│   ├── k8s/
│   │   ├── namespace.yaml    # cloudxai namespace
│   │   ├── deployment.yaml   # Target app with annotation placeholders
│   │   ├── rbac.yaml         # ServiceAccount + Role for agent
│   │   ├── jaeger.yaml       # Jaeger all-in-one (tracing backend)
│   │   └── audit-policy.yaml # k8s audit policy (captures scaling events)
│   ├── policies/
│   │   ├── require-user-context.yaml  # Pattern 1: block actions without user
│   │   └── replica-bounds.yaml        # Pattern 2: enforce 2-5 replica limit
│   └── agent.py              # Full agent: OTel + user context + OpenAI
│
├── kind-config.yaml          # Kind cluster with audit logging enabled
├── setup.sh                  # One-time setup (run first)
├── teardown.sh               # Clean removal
├── demo.sh                   # Step-by-step demo script
├── requirements.txt          # Python dependencies
└── README.md                 # This file
```

---

## Quick Start

### Prerequisites

```bash
# Required tools
brew install kind kubectl helm

# Python 3.9+
pip install -r requirements.txt

# OpenAI API key
export OPENAI_API_KEY=sk-...
```

### Setup (run once, ~5 minutes)

```bash
./setup.sh
```

This will:
- Create a `kind` cluster named `cloudxai-demo` with audit logging
- Deploy the demo app (`nginx`) to the `cloudxai` namespace
- Deploy Jaeger for trace visualization
- Install Kyverno via Helm
- Install Python dependencies

### Run the Demo

```bash
./demo.sh
```

The script walks you through each step with speaker notes and pauses.

### Teardown

```bash
./teardown.sh
```

Deletes the kind cluster and all resources. One command, clean slate.

---

## Component Details

### `before/agent.py` — The Broken Agent

Scales a deployment with no accountability:
- No user identity tracked
- No decision trace
- No replica bounds
- Audit log shows only service account

```bash
cd before && python3 agent.py
```

### `after/agent.py` — The Accountable Agent

Full accountability implementation:

```bash
# Normal run (LLM decides replica count)
python3 after/agent.py --user alice@company.com

# Test policy blocking (will be rejected by Kyverno)
python3 after/agent.py --user alice@company.com --replicas 10

# Dry run (shows what would happen)
python3 after/agent.py --user alice@company.com --dry-run

# Interactive chat mode (bonus demo feature)
python3 after/agent.py --user alice@company.com --chat
```

### Kyverno Policies

**`require-user-context.yaml`** — Pattern 1 enforcement  
Blocks any deployment update in the `cloudxai` namespace that doesn't include the `accountability.ai/triggered-by` annotation.

**`replica-bounds.yaml`** — Pattern 2 enforcement  
Blocks scaling below 2 or above 5 replicas. This is what RBAC cannot express — RBAC would allow any replica count if the service account has `patch` permission.

### Jaeger UI

After running the agent, open Jaeger to see the full decision trace:

```
http://localhost:16686
```

Select service: `ai-scaling-agent`

Each trace shows:
```
agent.scaling_cycle
  ├── metrics.observe        → CPU: 78.3%, Replicas: 2
  ├── llm.reasoning          → "CPU above 80%, scaling from 2 to 4"
  └── k8s.scale_deployment   → PATCH cloudxai/demo-app → 4 replicas
```

Every span includes `agent.triggered_by: alice@company.com`.

---

## What the Audit Log Shows

### Before (useless)
```json
{
  "user": { "username": "system:serviceaccount:default:default" },
  "verb": "patch",
  "objectRef": { "resource": "deployments", "name": "demo-app" }
}
```

### After (forensically useful)
```
kubectl get deployment demo-app -n cloudxai -o jsonpath='{.metadata.annotations}'
```
```json
{
  "accountability.ai/triggered-by": "alice@company.com",
  "accountability.ai/trace-id": "a3f2b1c4-...",
  "accountability.ai/reason": "CPU at 78.3%, scaling from 2 to 4 replicas",
  "accountability.ai/cpu-observed": "78.3%",
  "accountability.ai/timestamp": "2026-02-18T09:30:00Z"
}
```

---

## Forensics Workflow

> *"Production scaled to 4 replicas at 2am and cost us $500. Who do we call?"*

1. Find the deployment event in audit logs (timestamp: 02:00)
2. Read `accountability.ai/triggered-by` → `alice@company.com`
3. Read `accountability.ai/trace-id` → `a3f2b1c4-...`
4. Open Jaeger, search by trace ID
5. See: CPU was 82% → LLM recommended 4 replicas → Kyverno allowed it
6. Call Alice. Show her the trace. Done.

---

## Troubleshooting

**Kyverno blocks everything:**
```bash
kubectl get clusterpolicy -o wide
kubectl describe clusterpolicy require-user-context
```

**No traces in Jaeger:**
```bash
# Check port-forward is running
kubectl port-forward svc/jaeger 16686:16686 -n cloudxai
# Check Jaeger endpoint in agent
export JAEGER_ENDPOINT=http://localhost:4318/v1/traces
```

**Agent can't reach cluster:**
```bash
kubectl config use-context kind-cloudxai-demo
```

**Audit logs (inside kind node):**
```bash
docker exec -it cloudxai-demo-control-plane cat /var/log/kubernetes/audit.log | \
  python3 -m json.tool | grep -A5 "demo-app"
```
