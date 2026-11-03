#!/bin/bash
set -euo pipefail

CLUSTER_NAME="$1"
AWS_REGION="$2"

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

# ── 3. Find and delete load balancers tagged for this cluster ─────────────────
echo "==> Checking for load balancers tagged for cluster ${CLUSTER_NAME}..."
LB_ARNS=$(aws elbv2 describe-load-balancers \
  --region "$AWS_REGION" \
  --query 'LoadBalancers[].LoadBalancerArn' \
  --output text)

if [ -z "$LB_ARNS" ] || [ "$LB_ARNS" = "None" ]; then
  echo "No load balancers found in ${AWS_REGION}."
else
  for LB_ARN in $LB_ARNS; do
    CLUSTER_TAG=$(aws elbv2 describe-tags \
      --region "$AWS_REGION" \
      --resource-arns "$LB_ARN" \
      --query "TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster'].Value | [0]" \
      --output text)

    if [ "$CLUSTER_TAG" != "$CLUSTER_NAME" ]; then
      continue
    fi

    echo "Deleting cluster load balancer: $LB_ARN"
    aws elbv2 delete-load-balancer \
      --region "$AWS_REGION" \
      --load-balancer-arn "$LB_ARN"
    aws elbv2 wait load-balancers-deleted \
      --region "$AWS_REGION" \
      --load-balancer-arns "$LB_ARN"
  done
fi

echo "==> Load balancer teardown complete."
