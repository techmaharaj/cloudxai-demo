#!/usr/bin/env bash
# ============================================================
# CloudXAI Demo - Teardown Script
# Removes all demo resources from the Docker Desktop cluster.
# Does NOT delete the cluster itself.
# ============================================================
set -euo pipefail

echo "🗑️  Tearing down CloudXAI demo resources..."
echo ""

# Kill any port-forward processes
echo "  → Stopping port-forwards..."
pkill -f "kubectl port-forward svc/jaeger" 2>/dev/null || true

# Delete the cloudxai namespace (removes Jaeger, demo-app, RBAC, policies)
if kubectl get namespace cloudxai &>/dev/null; then
  echo "  → Deleting cloudxai namespace (Jaeger, demo-app, RBAC, policies)..."
  kubectl delete namespace cloudxai
  echo "  ✅ cloudxai namespace deleted"
else
  echo "  ℹ️  cloudxai namespace not found, skipping"
fi

# Delete the before-scenario app from default namespace
if kubectl get deployment demo-app -n default &>/dev/null; then
  echo "  → Deleting before-scenario demo-app from default namespace..."
  kubectl delete deployment demo-app -n default
  echo "  ✅ before/demo-app deleted"
else
  echo "  ℹ️  before/demo-app not found in default namespace, skipping"
fi

# Uninstall Kyverno
if helm status kyverno -n kyverno &>/dev/null; then
  echo "  → Uninstalling Kyverno..."
  helm uninstall kyverno -n kyverno
  kubectl delete namespace kyverno --ignore-not-found
  echo "  ✅ Kyverno uninstalled"
else
  echo "  ℹ️  Kyverno not installed, skipping"
fi

# Remove Kyverno cluster policies (in case they were applied manually)
kubectl delete clusterpolicy require-user-context replica-bounds --ignore-not-found 2>/dev/null || true

echo ""
echo "✅ Teardown complete."
echo "   Your Docker Desktop cluster is untouched — only demo resources were removed."
