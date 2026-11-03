#!/bin/bash
set -euo pipefail

CLUSTER_NAME="$1"
KARPENTER_VERSION="1.15.0"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

cat > "${tmpdir}/karpenter-values.yaml" <<'EOF'
replicas: 2
podDisruptionBudget:
  maxUnavailable: 1
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
EOF

echo "==> Installing Karpenter ${KARPENTER_VERSION}..."
helm registry logout public.ecr.aws || true

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace kube-system \
  --values "${tmpdir}/karpenter-values.yaml" \
  --set serviceAccount.name=karpenter \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --wait \
  --timeout 10m

# Refresh existing pods so they receive Pod Identity credentials after association changes.
kubectl rollout restart deployment/karpenter -n kube-system
kubectl rollout status deployment/karpenter -n kube-system --timeout=10m

echo "==> Karpenter ${KARPENTER_VERSION} installed successfully."
