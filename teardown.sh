#!/usr/bin/env bash
# ============================================================
# CloudXAI Demo - Teardown Script
# Removes the kind cluster and all demo resources
# ============================================================
set -euo pipefail

CLUSTER_NAME="cloudxai-demo"

echo "🗑️  Tearing down CloudXAI demo..."
echo ""

# Kill any port-forward processes
echo "  → Stopping port-forwards..."
pkill -f "kubectl port-forward" 2>/dev/null || true

# Delete kind cluster (removes everything inside it)
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "  → Deleting kind cluster '$CLUSTER_NAME'..."
  kind delete cluster --name "$CLUSTER_NAME"
  echo "  ✅ Cluster deleted"
else
  echo "  ℹ️  Cluster '$CLUSTER_NAME' not found, nothing to delete"
fi

# Clean up temp files
echo "  → Cleaning up temp files..."
rm -f /tmp/cloudxai-audit-policy.yaml
rm -rf /tmp/cloudxai-audit-logs

echo ""
echo "✅ Teardown complete. All demo resources removed."
