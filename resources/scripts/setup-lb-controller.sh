#!/bin/bash
set -euo pipefail

CLUSTER_NAME="$1"
AWS_REGION="$2"
LB_CONTROLLER_VERSION="v2.14.1"

# ── 1. Clean up existing resources ────────────────────────────────────────────
echo "==> Cleaning up existing load balancer resources..."
kubectl delete validatingwebhookconfiguration aws-load-balancer-webhook --ignore-not-found=true
kubectl delete mutatingwebhookconfiguration aws-load-balancer-webhook --ignore-not-found=true
helm uninstall aws-load-balancer-controller -n kube-system --ignore-not-found || echo "Controller not found, skipping."
sleep 10

# ── 2. IAM policy ─────────────────────────────────────────────────────────────
echo "==> Configuring IAM policy..."
curl -sO https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${LB_CONTROLLER_VERSION}/docs/install/iam_policy.json
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json 2>/dev/null || echo "Policy already exists, skipping."

# ── 3. IAM service account ────────────────────────────────────────────────────
echo "==> Creating/updating IAM service account..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

eksctl create iamserviceaccount \
  --cluster="$CLUSTER_NAME" \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn="arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy" \
  --region "$AWS_REGION" \
  --override-existing-serviceaccounts \
  --approve

# ── 4. Helm install ───────────────────────────────────────────────────────────
echo "==> Installing aws-load-balancer-controller via Helm..."
VPC_ID=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query "cluster.resourcesVpcConfig.vpcId" \
  --output text)

helm repo add eks https://aws.github.io/eks-charts
helm repo update

wget -q https://raw.githubusercontent.com/aws/eks-charts/master/stable/aws-load-balancer-controller/crds/crds.yaml
kubectl apply -f crds.yaml

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="$AWS_REGION" \
  --set vpcId="$VPC_ID" \
  --set image.tag="$LB_CONTROLLER_VERSION"

# ── 5. Wait for readiness ─────────────────────────────────────────────────────
echo "==> Waiting for AWS Load Balancer Controller to be ready..."
kubectl wait --for=condition=available --timeout=300s \
  deployment/aws-load-balancer-controller -n kube-system

kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=aws-load-balancer-controller \
  -n kube-system --timeout=300s

echo "==> Verifying webhook configurations..."
kubectl get validatingwebhookconfiguration aws-load-balancer-webhook
kubectl get mutatingwebhookconfiguration aws-load-balancer-webhook

echo "==> AWS Load Balancer Controller is ready."
