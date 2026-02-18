#!/usr/bin/env python3
"""
BEFORE: AI Scaling Agent - NO ACCOUNTABILITY
============================================
This is the BROKEN version. It scales deployments but:
- No user identity tracked (audit logs show only service account)
- No tracing (decision reasoning is lost)
- No policy enforcement (can scale to any replica count)

This is what most AI agents on Kubernetes look like today.
"""

import sys
import random
import time
from kubernetes import client, config

NAMESPACE = "default"
DEPLOYMENT = "demo-app"


def get_simulated_cpu() -> float:
    """Simulate CPU usage - in a real agent this would query Prometheus."""
    return random.uniform(60, 95)


def decide_replicas(cpu: float, current: int) -> int:
    """Simple scaling logic - no AI, no reasoning captured."""
    if cpu > 80:
        return min(current + 2, 10)  # Can scale to 10! No bounds enforced.
    elif cpu < 50:
        return max(current - 1, 1)
    return current


def scale_deployment(replicas: int):
    """Scale the deployment. No user context. No trace. Just a raw API call."""
    config.load_kube_config()
    apps_v1 = client.AppsV1Api()

    body = {"spec": {"replicas": replicas}}
    apps_v1.patch_namespaced_deployment(
        name=DEPLOYMENT,
        namespace=NAMESPACE,
        body=body
    )


def main():
    print("=" * 60)
    print("🤖 AI Scaling Agent (NO ACCOUNTABILITY MODE)")
    print("=" * 60)
    print()
    print("⚠️  This agent has NO accountability features:")
    print("    - Audit logs will show: system:serviceaccount:default:ai-agent")
    print("    - No user identity tracked")
    print("    - No decision trace")
    print("    - No replica bounds enforced")
    print()

    config.load_kube_config()
    apps_v1 = client.AppsV1Api()

    # Get current replica count
    deployment = apps_v1.read_namespaced_deployment(DEPLOYMENT, NAMESPACE)
    current_replicas = deployment.spec.replicas

    # Simulate observing metrics
    cpu = get_simulated_cpu()
    print(f"📊 Observed CPU: {cpu:.1f}%")
    print(f"📦 Current replicas: {current_replicas}")

    # Make scaling decision
    new_replicas = decide_replicas(cpu, current_replicas)
    print(f"🎯 Decision: scale to {new_replicas} replicas")
    print()

    if new_replicas == current_replicas:
        print("✅ No scaling needed.")
        return

    # Scale - no context, no trace, no policy check
    print(f"⚡ Scaling {DEPLOYMENT} to {new_replicas} replicas...")
    scale_deployment(new_replicas)
    print(f"✅ Done. Scaled to {new_replicas} replicas.")
    print()
    print("🔍 What the audit log shows:")
    print('   user: "system:serviceaccount:default:ai-agent"')
    print('   verb: "patch"')
    print('   resource: "deployments"')
    print()
    print("❓ Questions you CANNOT answer from this log:")
    print("   - WHO triggered this agent?")
    print("   - WHY did it choose this replica count?")
    print("   - Was this within approved boundaries?")
    print("   - What metrics drove this decision?")


if __name__ == "__main__":
    main()
