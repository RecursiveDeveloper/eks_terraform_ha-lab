#!/bin/bash
set -euo pipefail

CLUSTER_NAME="$1"
AWS_REGION="$2"
LB_CONTROLLER_VERSION="v2.14.1"
LB_CONTROLLER_CHART_VERSION="1.14.1"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# ── 1. Clean up existing resources ────────────────────────────────────────────
echo "==> Cleaning up existing load balancer resources..."
kubectl delete validatingwebhookconfiguration aws-load-balancer-webhook --ignore-not-found=true
kubectl delete mutatingwebhookconfiguration aws-load-balancer-webhook --ignore-not-found=true
helm uninstall aws-load-balancer-controller -n kube-system --ignore-not-found || echo "Controller not found, skipping."
sleep 10

# ── 2. IAM service account ────────────────────────────────────────────────────
echo "==> Associating the service account with its Terraform-managed IAM role..."
ROLE_NAME="${CLUSTER_NAME}-aws-load-balancer-controller"
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

kubectl get serviceaccount aws-load-balancer-controller -n kube-system >/dev/null 2>&1 || \
  kubectl create serviceaccount aws-load-balancer-controller -n kube-system
kubectl annotate serviceaccount aws-load-balancer-controller -n kube-system \
  "eks.amazonaws.com/role-arn=${ROLE_ARN}" --overwrite

# ── 3. Helm install ───────────────────────────────────────────────────────────
echo "==> Installing aws-load-balancer-controller via Helm..."
VPC_ID=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query "cluster.resourcesVpcConfig.vpcId" \
  --output text)

helm repo add eks https://aws.github.io/eks-charts
helm repo update

echo "==> Downloading version-pinned AWS Load Balancer Controller CRDs..."
for crd in \
  elbv2.k8s.aws_ingressclassparams.yaml \
  elbv2.k8s.aws_targetgroupbindings.yaml; do
  curl -fsSL \
    "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${LB_CONTROLLER_VERSION}/config/crd/bases/${crd}" \
    -o "${tmpdir}/${crd}"
  kubectl apply -f "${tmpdir}/${crd}"
done

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version "$LB_CONTROLLER_CHART_VERSION" \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="$AWS_REGION" \
  --set vpcId="$VPC_ID" \
  --set image.tag="$LB_CONTROLLER_VERSION"

# ── 4. Wait for readiness ─────────────────────────────────────────────────────
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
