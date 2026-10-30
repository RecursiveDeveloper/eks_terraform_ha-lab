# EKS + Karpenter Terraform Review

**Repository:** `eks_terraform_ha-lab`  
**Reviewed commit:** `28ed218` (plus uncommitted line-ending changes)  
**Review date:** 2026-10-30  
**Scope:** Terraform modules, Karpenter IAM/installation, NodePool/EC2NodeClass, VPC, CI/CD workflows, teardown scripts  
**Method:** Manual review + `terraform validate` + version checks against upstream registries/repositories

> **Implementation update (2026-10-30):** KAR-01 was implemented using EKS Pod Identity, and KAR-02 was updated to match the official Karpenter v1.15.0 CloudFormation IAM policies. See `modules/eks/main.tf`. `terraform validate` and `terraform fmt -check modules/eks/main.tf` pass. KAR-03's unused Terraform-created instance profile remains a cleanup item; the `spec.role` flow is now authorized by the official instance-profile permissions. Apply the changes and verify in-cluster before considering Karpenter operational.

---

## Executive Summary

The overall architecture is sound: a VPC with private subnets for nodes, an EKS managed node group for system components, Karpenter for workload capacity, and EKS managed addons. `terraform validate` passes and the pinned module/provider versions resolve correctly.

The initial review identified three independent blockers. **KAR-01 (controller AWS identity) and KAR-02 (controller IAM permissions) have since been implemented.** KAR-03's `spec.role` approach is now covered by the official instance-profile permissions; the Terraform-created profile is redundant, not a provisioning blocker:

1. **Resolved — KAR-01:** The Karpenter controller pod had no AWS identity. It now uses EKS Pod Identity.
2. **Implemented — KAR-02:** Controller IAM policies now match the official Karpenter v1.15.0 policy statements, including `CreateFleet`, scoped resource tagging/deletion, instance-profile management and regional discovery.
3. **Cleanup — KAR-03:** `EC2NodeClass` uses `spec.role`, so Karpenter manages its instance profile. The policy now supports this; `aws_iam_instance_profile.karpenter_node` remains unused and can be removed as cleanup.

Beyond Karpenter, there are HA, security, teardown and CI hygiene issues. The repository is named `ha-lab`, but it currently has several single points of failure (single NAT gateway, one managed node, one Karpenter replica).

### Severity Summary

| Severity | Count | Meaning |
|---|---:|---|
| **P0 — Blocker** | 4 | Karpenter cannot work, or Terraform can fail during apply |
| **P1 — High** | 6 | Reliability, teardown, or security gaps likely to cause incidents |
| **P2 — Medium** | 7 | HA and security hardening |
| **P3 — Low / Cost** | 5 | Cost control and Karpenter tuning |
| **P4 — Hygiene** | 11 | Terraform/CI/repository maintainability |

> **Status note (2026-10-30):** Counts reflect the initial review. KAR-01, KAR-02, KAR-04 and KAR-26 are resolved; KAR-03 is non-blocking; KAR-06 and KAR-21 are accepted for this lab. The remaining findings are unchanged.

---

## Verification Performed

| Check | Result |
|---|---|
| `terraform validate` with Terraform `1.16.5` | ✅ Passed |
| `terraform fmt -check modules/eks/main.tf` | ✅ Passed after implementation |
| AWS provider `6.69.0` exists | ✅ |
| EKS module `21.29.0` exists | ✅ |
| VPC module `6.7.3` exists | ✅ |
| Karpenter `1.15.0` exists | ✅ |
| Karpenter ↔ Kubernetes compatibility | ✅ K8s `1.37` requires Karpenter `1.15.x` per the current compatibility matrix |
| Karpenter IAM policy vs. official v1.15.0 policy | ✅ Implemented (see KAR-02) |
| Controller AWS identity wiring | ✅ Pod Identity configured (see KAR-01) |
| Access entry policy association wiring | ✅ Module-native `policy_associations` (see KAR-04) |

> **Note:** `terraform init` created `.terraform.lock.hcl` during validation, but it is ignored by `.gitignore` (see KAR-24). The file was removed after validation to leave the working tree clean.

---

# P0 — Blockers

## KAR-01 — Karpenter controller has no AWS identity — RESOLVED

**Status: RESOLVED (2026-10-30) — implemented with EKS Pod Identity.**

**Files:** `modules/eks/main.tf`, `resources/scripts/install-karpenter.sh`

### Implementation

In `modules/eks/main.tf`:

- `aws_iam_role.karpenter_controller` trusts `pods.eks.amazonaws.com` for `sts:AssumeRole` and `sts:TagSession`, scoped by `aws:SourceAccount` to the current account and by `aws:SourceArn` to `module.eks.cluster_arn`.
- `aws_eks_pod_identity_association.karpenter_controller` associates the role with service account `karpenter` in namespace `kube-system`.
- The `eks-pod-identity-agent` addon was already enabled in the EKS module.

In `resources/scripts/install-karpenter.sh`:

- The Helm install sets `serviceAccount.name=karpenter`, matching the Pod Identity association.
- After install, the script restarts `deployment/karpenter` in `kube-system` and waits for the rollout, so running pods receive Pod Identity credentials.

### Verification after deployment

```sh
aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME"
kubectl -n kube-system logs deploy/karpenter | grep -iE "AccessDenied|UnauthorizedOperation"
kubectl get ec2nodeclass default -o yaml
kubectl get nodeclaims
```

---

## KAR-02 — Controller IAM policy is missing required permissions — IMPLEMENTED

**Status: IMPLEMENTED (2026-10-30).**

**Files:** `modules/eks/main.tf` (`karpenter_node_lifecycle`, `karpenter_iam_integration`, `karpenter_eks_integration`, `karpenter_resource_discovery`)

### Implementation

The controller policies were replaced with Terraform equivalents of the Karpenter v1.15.0 official CloudFormation policy:

- **Node lifecycle:** tagged `RunInstances`/`CreateFleet` authorization covering `fleet/*`, `instance/*`, `volume/*`, `network-interface/*`, `launch-template/*`, `spot-instances-request/*`, plus image, snapshot, security-group, subnet, capacity-reservation and placement-group access. `CreateTags` is scoped for both create-time and existing-resource tagging. `TerminateInstances` and `DeleteLaunchTemplate` are scoped to the correct resource types with cluster/nodepool tag conditions.
- **IAM integration:** `iam:PassRole` for the node role plus scoped `CreateInstanceProfile`, `TagInstanceProfile`, `AddRoleToInstanceProfile`, `RemoveRoleFromInstanceProfile`, `DeleteInstanceProfile`, `GetInstanceProfile` and `ListInstanceProfiles`.
- **EKS integration:** `eks:DescribeCluster` scoped to this cluster. The extra `eks:DescribeNodegroup` action was removed to match the official policy.
- **Resource discovery:** regional EC2 reads (`DescribeCapacityReservations`, `DescribeImages`, `DescribeInstances`, `DescribeInstanceStatus`, `DescribeInstanceTypeOfferings`, `DescribeInstanceTypes`, `DescribeLaunchTemplates`, `DescribePlacementGroups`, `DescribeSecurityGroups`, `DescribeSpotPriceHistory`, `DescribeSubnets`), scoped `ssm:GetParameter`, `pricing:GetProducts`, and instance-profile reads.
- **ARN construction:** `data.aws_partition`, `data.aws_region` and `data.aws_caller_identity` replace hard-coded partition/region/account values.

Validation: `terraform validate` and `terraform fmt -check modules/eks/main.tf` pass.

The optional interruption queue/SQS policy is intentionally excluded; see KAR-06 for the accepted lab decision.

Reference:
- <https://github.com/aws/karpenter-provider-aws/blob/v1.15.0/website/content/en/docs/getting-started/getting-started-with-karpenter/cloudformation.yaml>

---

## KAR-03 — `EC2NodeClass` uses `role`, but the created instance profile is unused — NON-BLOCKING

**Status (2026-10-30):** No longer blocks provisioning. The official IAM integration policy added for KAR-02 grants the scoped instance-profile permissions that `spec.role` requires.

**Files:** `resources/manifests/karpenter-nodepool.yaml:40`, `modules/eks/main.tf:144-147`

### Current implementation

- `resources/manifests/karpenter-nodepool.yaml` sets `role: "KarpenterNodeRole-CLUSTER_NAME"`, so Karpenter manages a generated instance profile for that role.
- `modules/eks/main.tf` still creates `aws_iam_instance_profile.karpenter_node`, which the manifest does not reference.
- Optional cleanup: remove the unused `aws_iam_instance_profile.karpenter_node`.

---

## KAR-04 — Access policy association can race the access entry — RESOLVED

**Status: RESOLVED (2026-10-30).**

**File:** `modules/eks/main.tf`

### Implementation

Both user access entries now declare their policy associations directly in the EKS module's `access_entries` map:

```hcl
access_entries = {
  devops_access_entry_1 = {
    principal_arn = var.devops_user1_arn
    type          = "STANDARD"
    policy_associations = {
      admin = {
        policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        access_scope = {
          type = "cluster"
        }
      }
    }
  }
  ...
}
```

The separate `aws_eks_access_policy_association` resources were removed. Each access entry and its policy association are now created together by the module, which removes the dependency race.

Validation: `terraform validate` and `terraform fmt -check modules/eks/main.tf` pass.

---

# P1 — High

## KAR-05 — Discovery tag is applied to the cluster security group too

**File:** `modules/eks/main.tf:31-37`  
**Impact:** Karpenter attaches an unintended extra security group to every node.

### What happens

```hcl
tags = {
  "karpenter.sh/discovery" = var.eks_cluster_name
}

node_security_group_tags = {
  "karpenter.sh/discovery" = var.eks_cluster_name
}
```

The `terraform-aws-modules/eks/aws` module merges `var.tags` into both the cluster security group (`main.tf` in the module) and the node security group. As a result, `securityGroupSelectorTerms` in the `EC2NodeClass` matches **both** SGs, and Karpenter attaches both to launched nodes.

This usually still works, but it is not the documented setup and can cause surprising SG rule interactions.

### Fix

Remove `karpenter.sh/discovery` from the generic `tags` map and keep it only in `node_security_group_tags`:

```hcl
tags = {
  Terraform   = "true"
  Environment = "dev"
}

node_security_group_tags = {
  "karpenter.sh/discovery" = var.eks_cluster_name
}
```

The cluster itself does not need the discovery tag.

---

## KAR-06 — No interruption queue (SQS/EventBridge) — ACCEPTED (lab, no spot)

**Status (2026-10-30):** Accepted risk for this lab. The NodePool is on-demand only and there is no plan to use spot capacity, so spot interruption handling is not required.

**File:** `resources/scripts/install-karpenter.sh`

**Decision:** Keep the chart installed without `settings.interruptionQueue`. No SQS queue, EventBridge rules, or SQS IAM permissions are added.

**Residual risk:** On-demand instances can still receive AWS Health scheduled maintenance events. Karpenter will not react to those through an interruption queue in this lab. If spot capacity is ever introduced, add the interruption queue first.

---

## KAR-07 — Teardown can leave EC2 instances and block VPC deletion

**File:** `resources/scripts/teardown-karpenter.sh:6-10`  
**Impact:** `terraform destroy` fails on leftover ENIs/instances; orphaned EC2 resources incur cost.

### What happens

```sh
kubectl delete nodeclaims --all || true
kubectl delete nodepools --all || true
kubectl delete ec2nodeclasses --all || true
echo "Waiting for Karpenter nodes to drain..."
sleep 30
```

Problems:

- `kubectl delete` is asynchronous; 30 seconds is not a reliable wait.
- Deleting `EC2NodeClass` immediately after `NodePool` can break Karpenter's cleanup, because it may still need the node class to resolve instance profiles/launch templates.
- Karpenter-launched instances are not in Terraform state, so Terraform will not clean them up.
- Leftover instances/ENIs block VPC deletion in `terraform destroy`.

### Fix

Wait for NodeClaims to be fully deleted before deleting the `EC2NodeClass`, then wait for instances to terminate:

```sh
kubectl delete nodepools --all || true
kubectl wait --for=delete nodeclaim --all --timeout=10m || true
kubectl delete ec2nodeclasses --all || true

# Optional: verify no Karpenter-tagged instances remain
aws ec2 describe-instances \
  --filters "Name=tag:karpenter.sh/nodepool,Values=*" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text
```

Also consider waiting for ENIs to disappear before `terraform destroy`.

---

## KAR-08 — LB teardown hardcodes a load balancer name

**File:** `resources/scripts/teardown-lb-controller.sh:24`  
**Impact:** The script deletes nothing (or the wrong LB) in this cluster.

### What happens

```sh
LB_ARN=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(LoadBalancerName, 'shareduniralb')].LoadBalancerArn" \
  --output text 2>/dev/null || echo "")
```

`shareduniralb` is a leftover from another project.

### Fix

Filter by the AWS Load Balancer Controller cluster tag instead:

```sh
LB_ARNS=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?Tags[?Key=='elbv2.k8s.aws/cluster' && Value=='${CLUSTER_NAME}']].LoadBalancerArn" \
  --output text)
```

Pass the cluster name to the script (it currently only receives the region).

---

## KAR-09 — Load Balancer Controller IAM is outside Terraform

**File:** `resources/scripts/setup-lb-controller.sh:15-33`  
**Impact:** Orphaned IAM policy/role after `terraform destroy`.

### What happens

The script creates:

- An IAM policy named `AWSLoadBalancerControllerIAMPolicy`
- An IRSA role via `eksctl create iamserviceaccount`

Neither is tracked by Terraform, and `teardown-lb-controller.sh` does not delete them. After destroying the cluster, the OIDC provider is gone but the role/policy remain.

### Fix

Manage the LBC IAM policy and IRSA role in Terraform, or explicitly delete them in `teardown-lb-controller.sh`. Prefer Terraform so the destroy is complete.

---

## KAR-10 — LBC setup downloads unpinned CRDs and writes files into the repo

**File:** `resources/scripts/setup-lb-controller.sh:17,46`  
**Impact:** Non-reproducible installs; stray files in the workspace.

### What happens

```sh
curl -sO https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${LB_CONTROLLER_VERSION}/docs/install/iam_policy.json
...
wget -q https://raw.githubusercontent.com/aws/eks-charts/master/stable/aws-load-balancer-controller/crds/crds.yaml
```

- The CRDs come from `master`, not from the pinned `v2.14.1` release.
- `curl -sO` and `wget` write `iam_policy.json` and `crds.yaml` into the current directory.
- `curl` without `-f` can silently save an HTML error page as JSON.

### Fix

- Pin the CRD source to the same version as the controller.
- Use `curl -fsSL` and a temporary directory (`mktemp -d`).
- Clean up with `trap 'rm -rf "$tmpdir"' EXIT`.

---

# P2 — Medium (HA and security)

## KAR-11 — Single NAT gateway

**File:** `modules/vpc/main.tf:15`  
**Impact:** An AZ failure removes egress for all private subnets.

```hcl
single_nat_gateway = true
```

Nodes in private subnets need NAT (or VPC endpoints) to reach ECR, STS, SSM and the EKS API. If the NAT gateway's AZ fails, every private subnet loses egress.

### Recommendation

- For true HA: `single_nat_gateway = false` (one NAT per AZ).
- Or add VPC endpoints for `ecr.api`, `ecr.dkr`, `s3`, `sts`, `ssm`, `eks` and keep a single NAT as a fallback.
- If this is a cost-controlled lab, document the trade-off explicitly.

---

## KAR-12 — Single managed node and single Karpenter replica

**Files:** `terraform.auto.tfvars:12-14`, `resources/scripts/install-karpenter.sh:14`  
**Impact:** No redundancy for system addons or the autoscaler itself.

```hcl
min_size     = 1
max_size     = 1
desired_size = 1
```

```sh
--set replicas=1
```

CoreDNS, the AWS Load Balancer Controller, the Pod Identity agent and Karpenter all compete for one `t3a.medium`. If that node is drained or replaced, Karpenter cannot provision replacements.

### Recommendation

- Use at least 2-3 managed nodes across AZs for system components, or create a dedicated system NodePool with taints.
- Run 2 Karpenter replicas with topology spread constraints and a PodDisruptionBudget.
- Ensure the managed node group has enough capacity for `controller.resources.requests` (currently 1 CPU / 1 GiB).

---

## KAR-13 — Public EKS endpoint open to `0.0.0.0/0`

**File:** `modules/eks/main.tf:22`  
**Impact:** The Kubernetes API server is reachable from the entire internet.

```hcl
endpoint_public_access = true
```

The module default `public_access_cidrs` is `["0.0.0.0/0"]`.

### Recommendation

- Restrict to known CIDRs:

```hcl
cluster_endpoint_public_access_cidrs = ["<office-ip>/32", "<runner-ip>/32"]
```

- Or disable public access entirely and use a VPN/bastion or private runners:

```hcl
endpoint_public_access  = false
endpoint_private_access = true
```

- GitHub-hosted runners use a large, changing IP range; OIDC + private runners is a better long-term answer.

---

## KAR-14 — Control plane logging is disabled

**File:** `modules/eks/main.tf` (no `cluster_enabled_log_types`)  
**Impact:** No audit trail for incident response.

### Recommendation

```hcl
cluster_enabled_log_types = [
  "audit",
  "api",
  "authenticator",
  "controllerManager",
  "scheduler",
]
```

Consider shipping to CloudWatch Logs with a retention policy.

---

## KAR-15 — Control plane ENIs are placed in public subnets

**File:** `modules/eks/main.tf:26`  
**Impact:** Unnecessary public exposure of control plane ENIs.

```hcl
control_plane_subnet_ids = var.vpc_public_subnets
```

### Recommendation

Use private subnets for control plane ENIs:

```hcl
control_plane_subnet_ids = var.vpc_private_subnets
subnet_ids               = var.vpc_private_subnets
```

The public endpoint (if enabled) still works independently.

---

## KAR-16 — Public subnets auto-assign public IPs

**File:** `modules/vpc/main.tf:16`  
**Impact:** Accidental public exposure of instances launched in public subnets.

```hcl
map_public_ip_on_launch = true
```

### Recommendation

Set to `false` unless a specific workload requires it. Load balancers do not need this.

---

## KAR-17 — IMDSv2 is not enforced on Karpenter nodes

**File:** `resources/manifests/karpenter-nodepool.yaml` (no `metadataOptions`)  
**Impact:** Pods could potentially access instance credentials via IMDS.

### Recommendation

Add to the `EC2NodeClass`:

```yaml
metadataOptions:
  httpEndpoint: enabled
  httpTokens: required
  httpPutResponseHopLimit: 1
```

Use hop limit `1` if pods do not need IMDS (they shouldn't with IRSA/Pod Identity). If a workload needs IMDS, use `2` and restrict access with a NetworkPolicy.

---

# P3 — Low / Cost

## KAR-18 — NodePool CPU limit is effectively unlimited

**File:** `resources/manifests/karpenter-nodepool.yaml:29-30`

```yaml
limits:
  cpu: 1000
```

1000 vCPUs is not a meaningful cost guard.

### Recommendation

Set a realistic cap for the lab, for example:

```yaml
limits:
  cpu: "32"
  memory: 128Gi
```

---

## KAR-19 — No instance-size constraint

**File:** `resources/manifests/karpenter-nodepool.yaml:18-23`

The NodePool allows `c`, `m` and `r` instances of generation > 2, with no size cap. A single large pod can cause Karpenter to launch a very large (and expensive) instance.

### Recommendation

```yaml
- key: karpenter.k8s.aws/instance-size
  operator: In
  values: ["small", "medium", "large", "xlarge"]
```

Adjust based on the workloads you actually run.

---

## KAR-20 — Aggressive consolidation

**File:** `resources/manifests/karpenter-nodepool.yaml:31-33`

```yaml
consolidationPolicy: WhenEmptyOrUnderutilized
consolidateAfter: 1m
```

This can cause frequent node churn.

### Recommendation

- Use `consolidateAfter: 5m` or `15m`.
- Consider the `Balanced` consolidation policy (available in Karpenter 1.15), which only consolidates when the estimated savings justify the disruption.

---

## KAR-21 — On-demand only, no spot capacity — ACCEPTED (intentional)

**Status (2026-10-30):** Intentional for this lab. Spot capacity will not be used.

**File:** `resources/manifests/karpenter-nodepool.yaml:15-17`

```yaml
- key: karpenter.sh/capacity-type
  operator: In
  values: ["on-demand"]
```

**Decision:** Keep the NodePool on-demand only. Spot cost savings are not a goal for this lab, and avoiding spot also removes the need for interruption handling (KAR-06).

---

## KAR-22 — No disruption budgets

**File:** `resources/manifests/karpenter-nodepool.yaml`

Karpenter can voluntarily disrupt many nodes at once during consolidation or drift.

### Recommendation

```yaml
disruption:
  budgets:
    - nodes: "10%"
```

---

# P4 — Hygiene

## KAR-23 — S3 backend has no encryption or state locking

**File:** `provider.tf:9-13`

```hcl
backend "s3" {
  bucket = "tf-backend-lab-s3"
  key    = "terraform.tfstate"
  region = "us-east-1"
}
```

### Recommendation

```hcl
backend "s3" {
  bucket       = "tf-backend-lab-s3"
  key          = "terraform.tfstate"
  region       = "us-east-1"
  encrypt      = true
  use_lockfile = true
}
```

Terraform 1.10+ supports S3 native locking via `use_lockfile`; DynamoDB-based locking is deprecated. Also enable bucket versioning, SSE and Block Public Access.

---

## KAR-24 — `.terraform.lock.hcl` is ignored

**File:** `.gitignore:24`

```gitignore
*.hcl
```

This ignores `.terraform.lock.hcl`, which should be committed to pin provider versions and checksums.

### Recommendation

Remove the `*.hcl` rule, or add an exception:

```gitignore
*.hcl
!.terraform.lock.hcl
```

Then commit the lock file.

---

## KAR-25 — CRLF line endings in Terraform files

**File:** `.gitattributes`

The working tree contains CRLF in `.tf`, `.tfvars` and `.md` files, while the committed versions are LF. Every `.tf` file shows as modified for line-ending-only changes.

### Recommendation

```gitattributes
*.tf        text eol=lf
*.tfvars    text eol=lf
*.md        text eol=lf
*.sh        text eol=lf
*.yml       text eol=lf
*.yaml      text eol=lf
```

Then renormalize:

```sh
git add --renormalize .
```

---

## KAR-26 — `modules/eks/main.tf` is not formatted — RESOLVED

**Status (2026-10-30):** `modules/eks/main.tf` was formatted as part of the KAR-01/KAR-02 changes.

**File:** `modules/eks/main.tf`

### Implementation

Ran `terraform fmt modules/eks/main.tf`. `terraform fmt -check modules/eks/main.tf` now passes. Other files still fail the recursive check and are outside this item.

---

## KAR-27 — `eks_cluster_name` is missing from `terraform.auto.tfvars`

**File:** `terraform.auto.tfvars`

The variable has no default, and the tfvars file does not set it. In CI it is injected via `TF_VAR_eks_cluster_name`, but a local `terraform plan` fails.

### Recommendation

Add it to `terraform.auto.tfvars`:

```hcl
eks_cluster_name = "devopslab-eks"
```

Or give the variable a default in `variables.tf`.

---

## KAR-28 — Root variables are untyped

**File:** `variables.tf`

```hcl
variable "vpc_name" {}
variable "vpc_cidr" {}
...
```

Terraform infers `any`, so there is no validation or documentation.

### Recommendation

Add types and descriptions, especially for `eks_managed_node_groups`, matching the object schema already defined in `modules/eks/variables.tf`.

---

## KAR-29 — Kubernetes version is hardcoded

**File:** `modules/eks/main.tf:8`

```hcl
kubernetes_version = "1.37"
```

### Recommendation

Expose it as a variable so upgrades are explicit and can be tested independently of the module source.

---

## KAR-30 — CI/CD improvements

**Files:** `.github/workflows/deploy.yml`, `.github/workflows/main.yml`, `.github/actions/setup-composite/action.yml`

### Findings

1. **Plan is not applied.** `deploy.yml:37-45` runs `terraform plan` and then `terraform apply -auto-approve` separately, so the applied plan may differ from the reviewed one.

   ```sh
   terraform plan -out=tfplan
   terraform apply tfplan
   ```

2. **No concurrency control.** Two workflow runs can overlap. Combined with KAR-23 (no state locking), this can corrupt state. Add:

   ```yaml
   concurrency:
     group: terraform-${{ github.ref }}
     cancel-in-progress: false
   ```

3. **Static AWS credentials.** `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` are long-lived secrets. Prefer GitHub OIDC federation to an IAM role.

4. **kubectl version.** The composite action does not install kubectl. The runner's preinstalled version may be several minors behind 1.37, outside the supported skew. Install a matching version explicitly.

5. **Terraform version is valid.** `1.16.5` exists (verified). The existing security report's suggestion to change it to `1.6.5` is incorrect.

6. **No smoke test.** Add a post-install check that actually exercises Karpenter:

   ```sh
   kubectl create deployment smoke --image=public.ecr.aws/nginx/nginx:stable --replicas=1
   kubectl set resources deployment smoke --requests=cpu=2
   kubectl wait --for=condition=Ready nodeclaim --all --timeout=10m
   ```

---

## KAR-31 — Unused `devops_role` and README inaccuracy

**File:** `modules/iam/main.tf:11-29`, `README.md:50`

`devops_role` is assumable by both users, but it has only the `kubeconfig_policy` (describe cluster). It has no EKS access entry. Meanwhile, the users themselves receive `AmazonEKSClusterAdminPolicy` via access entries in `modules/eks/main.tf:63-79`.

So assuming the role gives less access than using the user directly, and the role serves no purpose.

### Recommendation

Either:

- Grant `devops_role` an EKS access entry and use it as the cluster identity (better practice), or
- Remove the role and the `assume_role` policies.

Also update the README: it says the IAM module creates "users, groups, and policies", but no groups are created.

---

## KAR-32 — `sed` substitution for the Karpenter manifest is fragile

**File:** `.github/workflows/deploy.yml:63-65`

```sh
sed "s/CLUSTER_NAME/${{ inputs.eks_cluster_name }}/g" resources/manifests/karpenter-nodepool.yaml | kubectl apply -f -
```

Cluster names are restricted to alphanumerics and hyphens, so this works in practice, but `sed` special characters (`/`, `&`, `\`) would break it, and the input is interpolated directly into a shell command.

### Recommendation

Use `envsubst` with an exported variable, or manage the manifest with the Terraform Kubernetes provider so it is part of the apply graph.

---

## KAR-33 — No verification that Karpenter actually works

**File:** `.github/workflows/deploy.yml`

The workflow ends after applying the NodePool/EC2NodeClass. It does not verify that the controller can authenticate or that a node can be launched.

### Recommendation

Add a smoke test (see KAR-30.6) and fail the workflow if no NodeClaim becomes ready. At minimum, check the controller logs for `AccessDenied` / `UnauthorizedOperation`.

---

## KAR-34 — Existing security report overstates Karpenter compliance

**File:** `reports/report_v1.0.0.md:77-78`

The report marks as compliant:

- "Karpenter with IRSA configured" — **not true at the time of this review**: the controller role existed but was not attached to the service account. It now uses Pod Identity (KAR-01).
- "Karpenter policies with resource conditions" — **partially true at the time of this review**: the policies had some conditions but were missing required actions/resources (KAR-02). They now match the official v1.15.0 policy.

### Recommendation

Update the report to reflect the actual wiring. A compliance gate that reports Karpenter as green while it cannot provision nodes is misleading.

---

## KAR-35 — Report's Terraform version recommendation is wrong

**File:** `reports/report_v1.0.0.md:256`

The report suggests changing Terraform `1.16.5` → `1.6.5`. Terraform `1.16.5` exists and was used successfully for `terraform validate` in this review.

### Recommendation

Remove that item from the report's backlog.

---

# What Is Already Correct

The following items were verified and do not need changes:

| Item | Status |
|---|---|
| `terraform validate` | ✅ Passes |
| AWS provider `6.69.0` | ✅ Exists |
| EKS module `21.29.0` | ✅ Exists |
| VPC module `6.7.3` | ✅ Exists |
| Karpenter `1.15.0` | ✅ Exists |
| EKS 1.37 + Karpenter 1.15.x compatibility | ✅ Correct per current matrix |
| Karpenter node role + `EC2_LINUX` access entry | ✅ Correct pattern |
| Private subnet `karpenter.sh/discovery` tags | ✅ Correct |
| Node SG `ingress_self_all` rule | ✅ Correct |
| `before_compute` on `vpc-cni`, `kube-proxy`, `eks-pod-identity-agent` | ✅ Correct |
| EBS CSI driver IRSA role | ✅ Correct |
| NodePool v1 schema (`expireAfter` under `template.spec`) | ✅ Correct |
| `iam:PassRole` scoped to the node role with `iam:PassedToService` | ✅ Correct |
| Destroy workflow tears down controllers before `terraform destroy` | ✅ Correct approach |

---

# Recommended Action Plan

## Phase 1 — Karpenter readiness (P0)

Completed:

- **KAR-01:** controller identity implemented with EKS Pod Identity.
- **KAR-02:** controller IAM policies aligned with the official Karpenter v1.15.0 CloudFormation policy.
- **KAR-03:** `spec.role` is authorized; the unused Terraform-created instance profile remains optional cleanup.
- **KAR-04:** access entries now use the module-native `policy_associations`.

Remaining:

1. Deploy and verify with a smoke test (KAR-33).

## Phase 2 — Reliability and teardown (P1)

1. Remove the discovery tag from the generic `tags` map.
2. Make teardown wait for NodeClaims and instances.
3. Fix the hardcoded LB name and manage LBC IAM in Terraform.
4. Pin the LBC CRD source and clean up temporary files.

The interruption queue is intentionally out of scope for this lab (KAR-06).

## Phase 3 — HA and security (P2)

1. Decide on the NAT strategy (`single_nat_gateway = false` or VPC endpoints).
2. Add redundancy for system nodes and the Karpenter controller.
3. Restrict or disable the public EKS endpoint.
4. Enable control plane logging.
5. Move control plane ENIs to private subnets.
6. Disable `map_public_ip_on_launch`.
7. Enforce IMDSv2.

## Phase 4 — Cost and tuning (P3)

1. Set realistic NodePool limits.
2. Add an instance-size constraint.
3. Tune consolidation.
4. Add disruption budgets.

Spot capacity is intentionally out of scope for this lab (KAR-21).

## Phase 5 — Hygiene (P4)

1. Enable S3 backend encryption and native locking.
2. Commit `.terraform.lock.hcl`.
3. Normalize line endings and run `terraform fmt`.
4. Add `eks_cluster_name` to the tfvars.
5. Type the root variables.
6. Make the Kubernetes version a variable.
7. Improve the CI workflow (plan artifact, concurrency, OIDC, kubectl version, smoke test).
8. Clean up `devops_role` and the README.
9. Update the security report.

---

# References

- Karpenter getting started / official IAM policy:  
  <https://github.com/aws/karpenter-provider-aws/blob/v1.15.0/website/content/en/docs/getting-started/getting-started-with-karpenter/cloudformation.yaml>
- Karpenter compatibility matrix:  
  <https://karpenter.sh/docs/upgrading/compatibility/>
- Karpenter NodePool concepts:  
  <https://karpenter.sh/docs/concepts/nodepools/>
- Karpenter NodeClass concepts (role vs instanceProfile):  
  <https://karpenter.sh/docs/concepts/nodeclasses/>
- EKS module Karpenter submodule:  
  <https://github.com/terraform-aws-modules/terraform-aws-eks/tree/v21.29.0/modules/karpenter>
- Terraform S3 backend native locking:  
  <https://developer.hashicorp.com/terraform/language/backend/s3>

---

*Report generated from a manual review of the repository on 2026-10-30.*
