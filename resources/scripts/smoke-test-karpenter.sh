#!/bin/bash
set -euo pipefail

NAMESPACE="karpenter-smoke-test"
DEPLOYMENT="karpenter-smoke-test"
NODEPOOL="karpenter-smoke-test"
NODECLASS="default"
TIMEOUT="${SMOKE_TEST_TIMEOUT:-10m}"
LOG_SINCE="15m"
NODECLAIM=""
NAMESPACE_CREATED=false
NODEPOOL_CREATED=false

cleanup() {
  local exit_code=$?
  trap - EXIT
  set +e

  if [ "${exit_code}" -ne 0 ]; then
    echo "==> Karpenter smoke test failed; collecting diagnostics..."
    kubectl get nodeclaims -o wide
    kubectl -n "${NAMESPACE}" get pods -o wide
    kubectl -n "${NAMESPACE}" describe deployment "${DEPLOYMENT}"
    kubectl -n kube-system logs \
      -l app.kubernetes.io/name=karpenter \
      --all-pods=true \
      --prefix=true \
      --since="${LOG_SINCE}" \
      --tail=200
  fi

  if [ "${NAMESPACE_CREATED}" = true ]; then
    echo "==> Removing smoke-test namespace ${NAMESPACE}..."
    kubectl delete namespace "${NAMESPACE}" \
      --ignore-not-found=true \
      --wait=true \
      --timeout=2m || exit_code=1
  fi

  if [ -n "${NODECLAIM}" ]; then
    echo "==> Removing smoke-test NodeClaim ${NODECLAIM}..."
    kubectl delete nodeclaim "${NODECLAIM}" \
      --ignore-not-found=true \
      --wait=false || exit_code=1
  fi

  if [ "${NODEPOOL_CREATED}" = true ]; then
    echo "==> Removing temporary NodePool ${NODEPOOL} and any remaining owned NodeClaims..."
    kubectl delete nodepool "${NODEPOOL}" \
      --ignore-not-found=true \
      --wait=false || exit_code=1
  fi

  exit "${exit_code}"
}
trap cleanup EXIT

echo "==> Checking recent Karpenter controller logs for AWS authorization errors..."
if kubectl -n kube-system logs \
  -l app.kubernetes.io/name=karpenter \
  --all-pods=true \
  --prefix=true \
  --since="${LOG_SINCE}" | grep -E 'AccessDenied|UnauthorizedOperation'; then
  echo "ERROR: Karpenter reported an AWS authorization error."
  exit 1
fi

if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "ERROR: Namespace ${NAMESPACE} already exists; refusing to modify it."
  exit 1
fi

if kubectl get nodepool "${NODEPOOL}" >/dev/null 2>&1; then
  echo "ERROR: NodePool ${NODEPOOL} already exists; refusing to modify it."
  exit 1
fi

echo "==> Creating isolated smoke-test resources..."
kubectl create namespace "${NAMESPACE}"
NAMESPACE_CREATED=true

kubectl apply -f - <<EOF
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: ${NODEPOOL}
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: ${NODECLASS}
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: karpenter.k8s.aws/instance-size
          operator: In
          values: ["small"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["2"]
      taints:
        - key: karpenter.sh/smoke-test
          value: "true"
          effect: NoSchedule
EOF
NODEPOOL_CREATED=true

echo "==> Creating a workload that only the temporary NodePool can schedule..."
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOYMENT}
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${DEPLOYMENT}
  template:
    metadata:
      labels:
        app: ${DEPLOYMENT}
    spec:
      nodeSelector:
        karpenter.sh/nodepool: ${NODEPOOL}
      tolerations:
        - key: karpenter.sh/smoke-test
          operator: Equal
          value: "true"
          effect: NoSchedule
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.10
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 128Mi
EOF

echo "==> Waiting up to ${TIMEOUT} for the smoke-test workload..."
kubectl -n "${NAMESPACE}" wait \
  --for=condition=Available \
  "deployment/${DEPLOYMENT}" \
  --timeout="${TIMEOUT}"

NODE_NAME=$(kubectl -n "${NAMESPACE}" get pods \
  -l "app=${DEPLOYMENT}" \
  -o jsonpath='{.items[0].spec.nodeName}')
if [ -z "${NODE_NAME}" ]; then
  echo "ERROR: The smoke-test pod has no assigned node."
  exit 1
fi

PROVIDER_ID=$(kubectl get node "${NODE_NAME}" -o jsonpath='{.spec.providerID}')
if [ -z "${PROVIDER_ID}" ]; then
  echo "ERROR: Node ${NODE_NAME} has no provider ID."
  exit 1
fi

NODECLAIM=$(kubectl get nodeclaims \
  -o "jsonpath={range .items[?(@.status.providerID==\"${PROVIDER_ID}\")]}{.metadata.name}{\"\n\"}{end}")
if [ -z "${NODECLAIM}" ] || [[ "${NODECLAIM}" == *$'\n'* ]]; then
  echo "ERROR: Expected exactly one NodeClaim for provider ID ${PROVIDER_ID}; found '${NODECLAIM}'."
  exit 1
fi

echo "==> Verifying NodeClaim ${NODECLAIM} for node ${NODE_NAME}..."
kubectl wait \
  --for=condition=Ready \
  "nodeclaim/${NODECLAIM}" \
  --timeout="${TIMEOUT}"

echo "==> Karpenter smoke test passed: NodeClaim ${NODECLAIM} is Ready and the workload is available on ${NODE_NAME}."
