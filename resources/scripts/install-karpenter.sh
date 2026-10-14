#!/bin/bash
set -euo pipefail

CLUSTER_NAME="$1"
KARPENTER_VERSION="1.15.0"

echo "==> Installing Karpenter ${KARPENTER_VERSION}..."
helm registry logout public.ecr.aws || true

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace kube-system \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --wait

echo "==> Karpenter ${KARPENTER_VERSION} installed successfully."
