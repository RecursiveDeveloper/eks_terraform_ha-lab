#!/bin/bash
set -euo pipefail

# ── 1. Delete Karpenter NodePools and wait for NodeClaims ─────────────────────
echo "==> Deleting Karpenter NodePools..."
kubectl delete nodepools --all --wait=false || true

echo "==> Waiting for NodeClaims to be deleted..."
kubectl wait --for=delete nodeclaim --all --timeout=10m || true

# Remove any NodeClaims not owned by a NodePool.
kubectl delete nodeclaims --all --ignore-not-found --timeout=5m || true
kubectl wait --for=delete nodeclaim --all --timeout=5m || true

echo "==> Deleting Karpenter EC2NodeClasses..."
kubectl delete ec2nodeclasses --all --ignore-not-found --timeout=5m || true

# ── 2. Wait for Karpenter-managed EC2 instances to terminate ──────────────────
# Terraform does not track these instances, so leftover nodes block VPC deletion.
echo "==> Waiting for Karpenter-managed EC2 instances to terminate..."
INSTANCE_WAIT_SECONDS="${INSTANCE_WAIT_SECONDS:-600}"
INSTANCE_POLL_SECONDS="${INSTANCE_POLL_SECONDS:-15}"
deadline=$((SECONDS + INSTANCE_WAIT_SECONDS))

while true; do
  if ! instance_ids=$(aws ec2 describe-instances \
    --filters \
      "Name=tag:karpenter.sh/nodepool,Values=*" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text); then
    echo "WARNING: could not query EC2 instances; continuing teardown." >&2
    break
  fi

  if [[ -z "$instance_ids" || "$instance_ids" == "None" ]]; then
    echo "No Karpenter-managed instances remain."
    break
  fi

  if (( SECONDS >= deadline )); then
    echo "WARNING: Karpenter-managed instances still present after ${INSTANCE_WAIT_SECONDS}s: ${instance_ids}" >&2
    break
  fi

  echo "Waiting for instances: ${instance_ids}"
  sleep "$INSTANCE_POLL_SECONDS"
done

# ── 3. Uninstall Karpenter ────────────────────────────────────────────────────
echo "==> Uninstalling Karpenter..."
if helm list -n kube-system | grep -q karpenter; then
  helm uninstall karpenter -n kube-system
  sleep 15
else
  echo "Karpenter not found, skipping."
fi

echo "==> Karpenter teardown complete."
