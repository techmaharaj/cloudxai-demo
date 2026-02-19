#!/usr/bin/env python3
"""
Platform AI Operations Service - NO ACCOUNTABILITY
===================================================
This represents a platform AI service provided to developers.
Developers invoke it (via CLI, Slack, API) to manage workloads.

The problem: the platform acts using a shared service account.
Audit logs lose the human who triggered it.

NO accountability features active in this version:
- No user identity tracked
- No decision trace
- No replica boundaries enforced
"""

import sys
import random
from kubernetes import client, config

NAMESPACE = "default"
DEPLOYMENT = "demo-app"


def get_simulated_cpu() -> float:
    """Simulate CPU usage - in production this would query Prometheus."""
    return random.uniform(60, 95)


def decide_replicas(cpu: float, current: int) -> int:
    """Simple scaling logic - no AI reasoning, no audit trail."""
    if cpu > 80:
        return min(current + 2, 10)  # No upper bound enforced
    elif cpu < 50:
        return max(current - 1, 1)
    return current


def scale_deployment(replicas: int):
    """Scale the deployment. No user context. No trace. Raw API call."""
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
    print("🤖 Platform AI Operations Service")
    print("   Mode: NO ACCOUNTABILITY")
    print("=" * 60)
    print()
    print("  Platform acting as shared service account.")
    print("  No user identity tracked. No trace. No boundaries.")
    print()

    config.load_kube_config()
    apps_v1 = client.AppsV1Api()

    deployment = apps_v1.read_namespaced_deployment(DEPLOYMENT, NAMESPACE)
    current_replicas = deployment.spec.replicas

    cpu = get_simulated_cpu()
    print(f"  📊 CPU observed:      {cpu:.1f}%")
    print(f"  📦 Current replicas:  {current_replicas}")

    new_replicas = decide_replicas(cpu, current_replicas)
    print(f"  🎯 Scaling decision:  {new_replicas} replicas")
    print()

    if new_replicas == current_replicas:
        print("  ✅ No scaling needed.")
        return

    print(f"  ⚡ Scaling {DEPLOYMENT} → {new_replicas} replicas...")
    scale_deployment(new_replicas)
    print(f"  ✅ Done.")
    print()
    print("  📋 Audit log records:")
    print('     user: "system:serviceaccount:default:ai-ops-agent"')
    print('     verb: "patch"  resource: "deployments"')
    print()
    print("  ❓ WHO invoked this service?    Not recorded.")
    print("  ❓ WHY this replica count?      Not recorded.")
    print("  ❓ What boundaries applied?     None enforced.")


if __name__ == "__main__":
    main()
