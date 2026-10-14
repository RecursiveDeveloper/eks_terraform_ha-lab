#!/bin/bash
set -euo pipefail

# ── 1. Delete Karpenter-managed resources ─────────────────────────────────────
echo "==> Deleting Karpenter NodeClaims, NodePools and EC2NodeClasses..."
kubectl delete nodeclaims --all || true
kubectl delete nodepools --all || true
kubectl delete ec2nodeclasses --all || true
echo "Waiting for Karpenter nodes to drain..."
sleep 30

# ── 2. Uninstall Karpenter ────────────────────────────────────────────────────
echo "==> Uninstalling Karpenter..."
if helm list -n kube-system | grep -q karpenter; then
  helm uninstall karpenter -n kube-system
  sleep 15
else
  echo "Karpenter not found, skipping."
fi

echo "==> Karpenter teardown complete."
