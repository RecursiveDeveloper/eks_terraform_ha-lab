#!/bin/bash
set -euo pipefail

AWS_REGION="$1"

# ── 1. Delete all ingress resources ───────────────────────────────────────────
echo "==> Deleting all ingress resources..."
kubectl delete ingress --all --all-namespaces || true
echo "Waiting for load balancer cleanup..."
sleep 30

# ── 2. Uninstall aws-load-balancer-controller ─────────────────────────────────
echo "==> Uninstalling aws-load-balancer-controller..."
if helm list -n kube-system | grep -q aws-load-balancer-controller; then
  helm uninstall aws-load-balancer-controller -n kube-system
  sleep 15
else
  echo "aws-load-balancer-controller not found, skipping."
fi

# ── 3. Delete the ALB resource directly ───────────────────────────────────────
echo "==> Checking for remaining ALB resources..."
LB_ARN=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(LoadBalancerName, 'shareduniralb')].LoadBalancerArn" \
  --output text 2>/dev/null || echo "")

if [ -z "$LB_ARN" ] || [ "$LB_ARN" = "None" ]; then
  echo "Load balancer 'shareduniralb' not found, skipping deletion."
else
  echo "Deleting load balancer: $LB_ARN"
  aws elbv2 delete-load-balancer --load-balancer-arn "$LB_ARN"
fi

echo "==> Load balancer teardown complete."
