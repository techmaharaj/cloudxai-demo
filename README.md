# Who Told the AI to Do That?
### GrafanaCon Demo

> **Talk:** "Who Told the AI to Do That?"
> **Demo duration:** ~10 minutes | **Setup time:** ~5 minutes

Someone invoked your platform AI agent. It scaled a deployment, patched a config, and changed something in prod. Now there's an incident, and everyone's asking the same question - who triggered this, and why did it do that? Your audit log points to a service account. Your RBAC policy is clean. You have no answer. This session is about fixing that. We'll look at how OpenTelemetry, Tempo, and Grafana can give you a complete accountability chain for every AI agent action — the human who invoked it, the metrics it observed, the reasoning it applied, the decision it made. All queryable in one place. Because "the AI did it" is not a postmortem.

---

## Platform Use Case

Imagine your platform team provides **AI Operations as a Service**. Developers across teams invoke it to manage their workloads:

```bash
platform-ai scale payment-service   # CLI
/ai scale my-service                # Slack
POST /api/ai/scale                  # Platform portal
```

The AI agent executes actions using a **shared service account** — it acts on behalf of many users. When something goes wrong at 3am and replicas spike, your audit log shows:

```
user: "system:serviceaccount:platform:ai-ops-agent"
verb: "patch"
resource: "deployments"
```

**You've lost the human behind the action.** This is the accountability gap RBAC cannot close.

---

## The Problem

When the platform AI acts, three questions become unanswerable:

| Question | What you need | What you get today |
|----------|--------------|-------------------|
| **WHO** invoked the service? | `alice@company.com` | `serviceaccount:ai-ops-agent` |
| **WHAT** boundaries applied? | "Bob limited to 2-10 replicas" | All-or-nothing RBAC |
| **WHY** did AI make this decision? | Full reasoning chain | Nothing |

RBAC controls what the **service account** can do. It can't track which human authorized a specific autonomous action, and it can't express context-aware boundaries.

---

## The Solution: Three Accountability Patterns

| Pattern | Answers | Tool |
|---------|---------|------|
| **1. User Context Propagation** | WHO | Annotation on every k8s action |
| **2. Dynamic Permission Boundaries** | WHAT | Kyverno policy (not RBAC) |
| **3. Decision Attribution** | WHY | OpenTelemetry → Grafana/Tempo |

---

## Architecture

```
Developer (Alice) → platform-ai CLI → Platform AI Service → Kubernetes API
                                             │
                                    ┌────────▼────────┐
                                    │   Pattern 1      │  annotation: triggered-by: alice
                                    │   User Context   │  audit log now has the human
                                    └────────┬────────┘
                                             │
                                    ┌────────▼────────┐
                                    │   Pattern 2      │  Kyverno: replicas 2-5
                                    │   Boundaries     │  blocked: scale to 100 ❌
                                    └────────┬────────┘
                                             │
                                    ┌────────▼────────┐
                                    │   Pattern 3      │  OTel: metrics → reasoning → action
                                    │   Attribution    │  full trace linked to annotation
                                    └─────────────────┘
```

---

## Project Structure

```
cloudxai/
├── before/                         # ❌ Platform AI with no accountability
│   ├── k8s/deployment.yaml
│   └── agent.py
├── after/                          # ✅ Platform AI with full accountability
│   ├── k8s/
│   │   ├── namespace.yaml          # grafanacon namespace
│   │   ├── deployment.yaml         # Target workload
│   │   ├── rbac.yaml               # ServiceAccount for platform AI
│   │   └── grafana-tempo.yaml      # Trace backend and visualization
│   ├── policies/
│   │   ├── require-user-context.yaml   # Pattern 1: block no-user actions
│   │   └── replica-bounds.yaml         # Pattern 2: enforce 2-5 replicas
│   └── agent.py                    # Platform AI: OTel + user context + OpenAI
├── setup.sh                        # One-shot setup (~4 min)
├── teardown.sh                     # Clean removal
├── demo.sh                         # Step-by-step demo
└── requirements.txt
```

---

## Quick Start

### Prerequisites

```bash
brew install kubectl helm
pip install -r requirements.txt
export OPENAI_API_KEY=sk-...
```

### Setup

```bash
./setup.sh    # deploys everything to Docker Desktop cluster
./demo.sh     # guided demo
./teardown.sh # removes all demo resources (cluster untouched)
```

---

## Agent Usage

```bash
# Standard platform service invocation
python3 after/agent.py --user alice@company.com

# Test boundary enforcement (blocked by Kyverno — max 5)
python3 after/agent.py --user alice@company.com --replicas 10

# Dry run
python3 after/agent.py --user alice@company.com --dry-run

# Interactive chat mode (bonus demo)
python3 after/agent.py --user alice@company.com --chat
```

---

## What the Audit Log Shows

### Before (platform lost the human)
```json
{
  "user": { "username": "system:serviceaccount:default:ai-ops-agent" },
  "verb": "patch",
  "objectRef": { "resource": "deployments", "name": "demo-app" }
}
```

### After (full accountability chain)

```bash
kubectl get deployment demo-app -n grafanacon -o jsonpath='{.metadata.annotations}' | python3 -m json.tool
```
```json
{
  "accountability.ai/triggered-by": "alice@company.com",
  "accountability.ai/trace-id": "a3f2b1c4-...",
  "accountability.ai/reason": "CPU at 78%, scaling from 2 to 4 replicas for availability",
  "accountability.ai/cpu-observed": "78.3%",
  "accountability.ai/timestamp": "2026-02-19T09:30:00Z"
}
```

---

## The Forensics Moment

> *"Prod scaled to 20 replicas at 3am. Who triggered it?"*

1. Find the deployment annotation → `triggered-by: alice@company.com`
2. Copy `trace-id` → open Grafana → full reasoning chain
3. See: CPU was 84% → LLM recommended scale-up → Kyverno allowed it (within bounds)
4. Call Alice. Show the trace. Done in 60 seconds.

---

## Troubleshooting

```bash
# Kyverno policies not applying
kubectl get clusterpolicy -o wide

# No traces in Grafana — check port-forward is forwarding BOTH ports
kubectl port-forward svc/grafana 3000:3000 -n grafanacon & \
kubectl port-forward svc/tempo 4318:4318 -n grafanacon

# Agent can't reach cluster
kubectl config use-context docker-desktop
```
