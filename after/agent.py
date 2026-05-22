#!/usr/bin/env python3
"""
Platform AI Operations Service - ACCOUNTABLE MODE
=================================================
This is the platform's shared AI service with three accountability
patterns active. Developers invoke this service via CLI, Slack, or API.
The platform tracks WHO invoked it, enforces WHAT boundaries apply,
and records WHY the AI made each decision.

Pattern 1: User Context Propagation
  - Platform annotates every k8s action with the invoking user's identity
  - Audit logs show the human, not just the service account

Pattern 2: Dynamic Permission Boundaries
  - Kyverno enforces context-aware replica limits (2-5)
  - Rules RBAC cannot express: conditional, runtime-evaluated

Pattern 3: Decision Attribution
  - OpenTelemetry traces the full chain: metrics → reasoning → action
  - Every action links to a trace ID for forensic investigation

Usage:
  python agent.py --user alice@company.com        # standard invocation
  python agent.py --user alice@company.com --replicas 10  # test boundaries
  python agent.py --user alice@company.com --chat # interactive mode
"""

import argparse
import json
import logging
import os
import random
import sys
import time
import uuid
from datetime import datetime

from dotenv import load_dotenv
load_dotenv()

# Suppress noisy OTel export warnings - if Jaeger isn't reachable, log cleanly
logging.getLogger("opentelemetry.sdk.trace.export").setLevel(logging.CRITICAL)
logging.getLogger("opentelemetry.exporter.otlp").setLevel(logging.CRITICAL)

from kubernetes import client, config
from kubernetes.client.rest import ApiException
from openai import OpenAI
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import Status, StatusCode

# ─── Configuration ────────────────────────────────────────────────────────────

NAMESPACE = "cloudxai"
DEPLOYMENT = "demo-app"
TEMPO_OTLP_ENDPOINT = os.getenv("TEMPO_ENDPOINT", "http://127.0.0.1:4318/v1/traces")
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY", "")

# Policy boundaries (mirrors Kyverno policy for transparency)
MIN_REPLICAS = 2
MAX_REPLICAS = 5


# ─── OpenTelemetry Setup ───────────────────────────────────────────────────────

def setup_tracing(user: str) -> trace.Tracer:
    """Initialize OTel tracer pointing at Tempo."""
    resource = Resource.create({
        "service.name": "ai-scaling-agent",
        "service.version": "1.0.0",
        "deployment.environment": "demo",
        "agent.triggered_by": user,
    })

    provider = TracerProvider(resource=resource)
    exporter = OTLPSpanExporter(endpoint=TEMPO_OTLP_ENDPOINT)
    provider.add_span_processor(BatchSpanProcessor(
        exporter,
        # Don't block the agent if Tempo is unreachable
        max_export_batch_size=512,
        export_timeout_millis=3000,
    ))
    trace.set_tracer_provider(provider)

    # Quick connectivity check - warn once, don't crash
    try:
        import urllib.request
        from urllib.error import HTTPError
        try:
            urllib.request.urlopen(TEMPO_OTLP_ENDPOINT.replace("/v1/traces", ""), timeout=1)
        except HTTPError as e:
            # 404 is expected since OTLP receiver doesn't serve a root page
            if e.code != 404:
                raise e
    except Exception:
        print(f"  ⚠️  Tempo not reachable at {TEMPO_OTLP_ENDPOINT}")
        print(f"     Run in another terminal: kubectl port-forward svc/grafana 3000:3000 -n cloudxai & kubectl port-forward svc/tempo 4318:4318 -n cloudxai")
        print(f"     Continuing without trace export...")
        print()

    return trace.get_tracer("ai-scaling-agent", "1.0.0")


# ─── Pattern 1: User Context ───────────────────────────────────────────────────

def build_accountability_annotations(user: str, trace_id: str, reason: str, cpu: float) -> dict:
    """
    Pattern 1: Build annotations that propagate user context into every k8s action.
    These annotations make audit logs forensically useful.
    """
    return {
        "accountability.ai/triggered-by": user,
        "accountability.ai/trace-id": trace_id,
        "accountability.ai/reason": reason,
        "accountability.ai/cpu-observed": f"{cpu:.1f}%",
        "accountability.ai/timestamp": datetime.utcnow().isoformat() + "Z",
        "accountability.ai/agent-version": "1.0.0",
    }


# ─── Pattern 3: Decision Attribution via OpenAI ───────────────────────────────

def get_ai_reasoning(cpu: float, current_replicas: int, user: str, tracer: trace.Tracer) -> tuple[int, str]:
    """
    Pattern 3: Use OpenAI to make the scaling decision.
    The reasoning is captured in an OTel span for full attribution.
    Returns (recommended_replicas, reasoning_text)
    """
    with tracer.start_as_current_span("llm.reasoning") as span:
        span.set_attribute("llm.model", "gpt-4o-mini")
        span.set_attribute("llm.cpu_observed", cpu)
        span.set_attribute("llm.current_replicas", current_replicas)
        span.set_attribute("llm.triggered_by", user)
        span.set_attribute("llm.policy.min_replicas", MIN_REPLICAS)
        span.set_attribute("llm.policy.max_replicas", MAX_REPLICAS)

        prompt = f"""You are an AI agent managing Kubernetes deployments.
You must scale a deployment based on current CPU metrics.

Current state:
- CPU utilization: {cpu:.1f}%
- Current replicas: {current_replicas}
- Triggered by: {user}
- Policy constraints: minimum {MIN_REPLICAS} replicas, maximum {MAX_REPLICAS} replicas

Rules:
- If CPU > 80%: scale up (add 1-2 replicas)
- If CPU < 40%: scale down (remove 1 replica)  
- If CPU 40-80%: maintain current replicas
- NEVER go below {MIN_REPLICAS} or above {MAX_REPLICAS} replicas

Respond with ONLY valid JSON in this exact format:
{{
  "recommended_replicas": <integer>,
  "reasoning": "<one sentence explanation>",
  "confidence": "<high|medium|low>"
}}"""

        try:
            oai = OpenAI(api_key=OPENAI_API_KEY)
            response = oai.chat.completions.create(
                model="gpt-4o-mini",
                messages=[{"role": "user", "content": prompt}],
                temperature=0.1,
                max_tokens=200,
            )

            raw = response.choices[0].message.content.strip()
            # Strip markdown code fences if present
            if raw.startswith("```"):
                raw = raw.split("```")[1]
                if raw.startswith("json"):
                    raw = raw[4:]
            result = json.loads(raw)

            recommended = int(result["recommended_replicas"])
            reasoning = result["reasoning"]
            confidence = result.get("confidence", "medium")

            # Clamp to policy bounds (belt-and-suspenders before Kyverno catches it)
            recommended = max(MIN_REPLICAS, min(MAX_REPLICAS, recommended))

            span.set_attribute("llm.recommended_replicas", recommended)
            span.set_attribute("llm.reasoning", reasoning)
            span.set_attribute("llm.confidence", confidence)
            span.set_attribute("llm.raw_response", raw)
            span.set_status(Status(StatusCode.OK))

            return recommended, reasoning

        except Exception as e:
            span.set_status(Status(StatusCode.ERROR, str(e)))
            span.record_exception(e)
            # Fallback: simple rule-based decision
            if cpu > 80:
                fallback = min(current_replicas + 1, MAX_REPLICAS)
            elif cpu < 40:
                fallback = max(current_replicas - 1, MIN_REPLICAS)
            else:
                fallback = current_replicas
            return fallback, f"Fallback rule-based decision (LLM error: {e})"


# ─── Kubernetes Operations ─────────────────────────────────────────────────────

def get_current_state(apps_v1) -> tuple[int, float]:
    """Get current replica count and simulate CPU observation."""
    deployment = apps_v1.read_namespaced_deployment(DEPLOYMENT, NAMESPACE)
    current_replicas = deployment.spec.replicas or 2
    cpu = random.uniform(60, 92)  # Simulated - replace with Prometheus query in prod
    return current_replicas, cpu


def scale_deployment(
    apps_v1,
    replicas: int,
    user: str,
    trace_id: str,
    reasoning: str,
    cpu: float,
    tracer: trace.Tracer,
    dry_run: bool = False,
) -> bool:
    """
    Pattern 1 + 2: Scale the deployment with user context annotations.
    Kyverno will validate the annotations and replica bounds server-side.
    Returns True if successful, False if blocked by policy.
    """
    with tracer.start_as_current_span("k8s.scale_deployment") as span:
        span.set_attribute("k8s.namespace", NAMESPACE)
        span.set_attribute("k8s.deployment", DEPLOYMENT)
        span.set_attribute("k8s.replicas.requested", replicas)
        span.set_attribute("k8s.triggered_by", user)
        span.set_attribute("k8s.trace_id", trace_id)

        annotations = build_accountability_annotations(user, trace_id, reasoning, cpu)

        body = {
            "metadata": {"annotations": annotations},
            "spec": {"replicas": replicas},
        }

        if dry_run:
            span.set_attribute("k8s.dry_run", True)
            print(f"\n  [DRY RUN] Would PATCH {NAMESPACE}/{DEPLOYMENT}")
            print(f"  [DRY RUN] Annotations: {json.dumps(annotations, indent=4)}")
            span.set_status(Status(StatusCode.OK))
            return True

        try:
            apps_v1.patch_namespaced_deployment(
                name=DEPLOYMENT,
                namespace=NAMESPACE,
                body=body,
            )
            span.set_attribute("k8s.result", "success")
            span.set_status(Status(StatusCode.OK))
            return True

        except ApiException as e:
            error_body = json.loads(e.body) if e.body else {}
            message = error_body.get("message", str(e))

            span.set_attribute("k8s.result", "blocked_by_policy")
            span.set_attribute("k8s.error", message)
            span.set_status(Status(StatusCode.ERROR, message))
            span.record_exception(e)

            print(f"\n  🚫 POLICY BLOCKED: {message}")
            return False


# ─── Interactive Chat Mode ─────────────────────────────────────────────────────

def chat_mode(user: str, tracer: trace.Tracer):
    """
    Bonus: Interactive chat with the agent during demo.
    Ask it questions about what it's doing and why.
    """
    config.load_kube_config()
    apps_v1 = client.AppsV1Api()

    oai = OpenAI(api_key=OPENAI_API_KEY)

    print(f"\n💬 Chat mode active. You are: {user}")
    print("   Ask the agent anything. Type 'scale' to trigger a scaling action.")
    print("   Type 'exit' to quit.\n")

    system_prompt = f"""You are an AI agent managing Kubernetes deployments for user {user}.
You have access to deployment metrics and can scale deployments.
You operate under these policies:
- Min replicas: {MIN_REPLICAS}, Max replicas: {MAX_REPLICAS}
- You must always explain your reasoning
- You must always identify who triggered you
- All your actions are traced with OpenTelemetry

Be concise, technical, and transparent about your decision-making process.
When asked to scale, explain what metrics you observed and why you chose that replica count."""

    messages = [{"role": "system", "content": system_prompt}]

    while True:
        try:
            user_input = input(f"[{user}] > ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n👋 Exiting chat mode.")
            break

        if not user_input:
            continue
        if user_input.lower() == "exit":
            print("👋 Exiting chat mode.")
            break

        if user_input.lower() == "scale":
            print("\n🔄 Triggering scaling action...\n")
            run_scaling_cycle(user, tracer, apps_v1, dry_run=False)
            continue

        messages.append({"role": "user", "content": user_input})

        with tracer.start_as_current_span("llm.chat") as span:
            span.set_attribute("chat.user", user)
            span.set_attribute("chat.input", user_input)

            response = oai.chat.completions.create(
                model="gpt-4o-mini",
                messages=messages,
                temperature=0.7,
                max_tokens=300,
            )
            reply = response.choices[0].message.content
            span.set_attribute("chat.response_length", len(reply))

        messages.append({"role": "assistant", "content": reply})
        print(f"\n🤖 Agent: {reply}\n")


# ─── Main Scaling Cycle ────────────────────────────────────────────────────────

def run_scaling_cycle(user: str, tracer: trace.Tracer, apps_v1, dry_run: bool = False):
    """Run one full scaling cycle with full accountability."""

    trace_id = str(uuid.uuid4())

    with tracer.start_as_current_span("agent.scaling_cycle") as root_span:
        root_span.set_attribute("agent.triggered_by", user)
        root_span.set_attribute("agent.trace_id", trace_id)
        root_span.set_attribute("agent.timestamp", datetime.utcnow().isoformat())

        # ── Step 1: Observe metrics ──────────────────────────────────────────
        with tracer.start_as_current_span("metrics.observe") as metrics_span:
            current_replicas, cpu = get_current_state(apps_v1)
            metrics_span.set_attribute("metrics.cpu_percent", cpu)
            metrics_span.set_attribute("metrics.current_replicas", current_replicas)
            metrics_span.set_attribute("metrics.source", "simulated")

            print(f"\n  📊 Metrics observed:")
            print(f"     CPU utilization: {cpu:.1f}%")
            print(f"     Current replicas: {current_replicas}")

        # ── Step 2: LLM reasoning ────────────────────────────────────────────
        print(f"\n  🧠 Asking LLM for scaling decision...")
        new_replicas, reasoning = get_ai_reasoning(cpu, current_replicas, user, tracer)

        print(f"\n  💡 LLM Decision:")
        print(f"     Recommended replicas: {new_replicas}")
        print(f"     Reasoning: {reasoning}")

        root_span.set_attribute("decision.replicas", new_replicas)
        root_span.set_attribute("decision.reasoning", reasoning)

        # ── Step 3: Apply with accountability ────────────────────────────────
        if new_replicas == current_replicas:
            print(f"\n  ✅ No scaling needed. Replicas remain at {current_replicas}.")
            root_span.set_attribute("decision.action", "no_change")
            root_span.set_status(Status(StatusCode.OK))
            return

        print(f"\n  ⚡ Scaling {DEPLOYMENT}: {current_replicas} → {new_replicas} replicas")
        print(f"     User context: {user}")
        print(f"     Trace ID: {trace_id}")

        success = scale_deployment(
            apps_v1, new_replicas, user, trace_id, reasoning, cpu, tracer, dry_run
        )

        if success:
            root_span.set_attribute("decision.action", "scaled")
            root_span.set_attribute("decision.result", "success")
            root_span.set_status(Status(StatusCode.OK))
            print(f"\n  ✅ Platform successfully scaled to {new_replicas} replicas")
            print(f"\n  📋 Audit log now records:")
            print(f'     service-account: "system:serviceaccount:cloudxai:ai-ops-agent"')
            print(f'     annotations:')
            print(f'       accountability.ai/triggered-by: "{user}"   ← the human')
            print(f'       accountability.ai/trace-id:    "{trace_id}"')
            print(f'       accountability.ai/reason:      "{reasoning}"')
            print(f'       accountability.ai/cpu-observed: "{cpu:.1f}%"')
            print(f"\n  🔗 View full reasoning trace:")
            print(f"     http://localhost:3000/explore (Select 'Tempo' and query {{ .service.name = \"ai-scaling-agent\" }})")
        else:
            root_span.set_attribute("decision.action", "blocked")
            root_span.set_attribute("decision.result", "policy_violation")
            root_span.set_status(Status(StatusCode.ERROR, "Blocked by Kyverno policy"))
            print(f"\n  🛡️  Platform blocked this action (policy violation).")
            print(f"      Trace still recorded — even rejected actions are auditable.")


# ─── Entry Point ───────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Who Told the AI to Do That? - Demo Agent",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Normal scaling run
  python agent.py --user alice@company.com

  # Try to exceed policy bounds (will be blocked by Kyverno)
  python agent.py --user alice@company.com --replicas 10

  # Dry run (shows what would happen without making changes)
  python agent.py --user alice@company.com --dry-run

  # Interactive chat mode
  python agent.py --user alice@company.com --chat
        """
    )
    parser.add_argument("--user", required=True, help="Identity of the human triggering the agent")
    parser.add_argument("--replicas", type=int, default=None, help="Override replica count (to demo policy blocking)")
    parser.add_argument("--dry-run", action="store_true", help="Show what would happen without making changes")
    parser.add_argument("--chat", action="store_true", help="Interactive chat mode with the agent")
    parser.add_argument("--tempo-endpoint", default=None, help="Override Tempo OTLP endpoint")

    args = parser.parse_args()

    if not OPENAI_API_KEY:
        print("❌ Error: OPENAI_API_KEY environment variable not set")
        sys.exit(1)

    global TEMPO_OTLP_ENDPOINT
    if args.tempo_endpoint:
        TEMPO_OTLP_ENDPOINT = args.tempo_endpoint

    print("=" * 60)
    print("🤖 Platform AI Operations Service")
    print("   Mode: ACCOUNTABLE")
    print("=" * 60)
    print(f"\n  ✅ Pattern 1: User context propagation  ACTIVE")
    print(f"  ✅ Pattern 2: Dynamic policy boundaries  ACTIVE (replicas: {MIN_REPLICAS}-{MAX_REPLICAS})")
    print(f"  ✅ Pattern 3: Decision attribution       ACTIVE (OTel → Grafana/Tempo)")
    print(f"\n  Platform service invoked by: {args.user}")
    print(f"  Tempo endpoint: {TEMPO_OTLP_ENDPOINT}")
    if args.dry_run:
        print(f"  Mode: DRY RUN (no changes will be made)")
    print()

    # Setup tracing
    tracer = setup_tracing(args.user)

    # Load k8s config
    config.load_kube_config()
    apps_v1 = client.AppsV1Api()

    if args.chat:
        chat_mode(args.user, tracer)
        return

    if args.replicas is not None:
        # Manual override mode - useful for demo'ing policy blocking
        print(f"  ⚠️  Boundary override requested: {args.replicas} replicas")
        print(f"     Policy allows: {MIN_REPLICAS}-{MAX_REPLICAS} replicas")
        print(f"     Platform will block this if outside bounds.")

        trace_id = str(uuid.uuid4())
        tracer_instance = trace.get_tracer("ai-scaling-agent")

        with tracer_instance.start_as_current_span("agent.manual_scale") as span:
            span.set_attribute("agent.triggered_by", args.user)
            span.set_attribute("agent.manual_override", True)
            span.set_attribute("agent.requested_replicas", args.replicas)

            _, cpu = get_current_state(apps_v1)
            reasoning = f"Manual override requested by {args.user}: {args.replicas} replicas"

            scale_deployment(
                apps_v1, args.replicas, args.user, trace_id,
                reasoning, cpu, tracer_instance, args.dry_run
            )
    else:
        run_scaling_cycle(args.user, tracer, apps_v1, args.dry_run)

    # Flush traces
    time.sleep(2)
    print("\n  📡 Traces flushed to Tempo (if port-forward is running).")


if __name__ == "__main__":
    main()
