# EKS + Karpenter Terraform Review

**Repository:** `eks_terraform_ha-lab`  
**Reviewed commit:** `28ed218` (plus uncommitted line-ending changes)  
**Review date:** 2026-10-30  
**Scope:** Terraform modules, Karpenter IAM/installation, NodePool/EC2NodeClass, VPC, CI/CD workflows, teardown scripts  
**Method:** Manual review + `terraform validate` + version checks against upstream registries/repositories

> **Implementation update (2026-11-03):** KAR-01 through KAR-05, KAR-07 through KAR-10, KAR-12, KAR-14 through KAR-20, KAR-22, KAR-25 and KAR-26 are implemented. KAR-06, KAR-11, KAR-13 and KAR-21 are accepted lab trade-offs. KAR-23 backend settings are implemented, with bucket-level settings to verify; KAR-24's lock file still needs a commit. See the relevant KAR sections for implementation details.

---

## Executive Summary

The overall architecture is sound: a VPC with private subnets for nodes, an EKS managed node group for system components, Karpenter for workload capacity, and EKS managed addons. `terraform validate` passes and the pinned module/provider versions resolve correctly.

The initial review identified three independent blockers. **KAR-01 (controller AWS identity) and KAR-02 (controller IAM permissions) have since been implemented.** KAR-03's `spec.role` approach is now covered by the official instance-profile permissions and the redundant Terraform-created profile has been removed:

1. **Resolved — KAR-01:** The Karpenter controller pod had no AWS identity. It now uses EKS Pod Identity.
2. **Implemented — KAR-02:** Controller IAM policies now match the official Karpenter v1.15.0 policy statements, including `CreateFleet`, scoped resource tagging/deletion, instance-profile management and regional discovery.
3. **Resolved — KAR-03:** `EC2NodeClass` uses `spec.role`, so Karpenter manages its instance profile. The unused `aws_iam_instance_profile.karpenter_node` has been removed.

Beyond Karpenter, there are HA, security, teardown and CI hygiene issues. KAR-04, KAR-05, KAR-07 through KAR-10, KAR-12, KAR-14 through KAR-20, KAR-22 and KAR-25 have been implemented. KAR-11 and KAR-13 are accepted lab risks. The repository still has limitations such as a single NAT gateway and no strict per-AZ capacity guarantee.

### Severity Summary

| Severity | Count | Meaning |
|---|---:|---|
| **P0 — Blocker** | 4 | Karpenter cannot work, or Terraform can fail during apply |
| **P1 — High** | 6 | Reliability, teardown, or security gaps likely to cause incidents |
| **P2 — Medium** | 7 | HA and security hardening |
| **P3 — Low / Cost** | 5 | Cost control and Karpenter tuning |
| **P4 — Hygiene** | 11 | Terraform/CI/repository maintainability |

> **Status note (2026-11-03):** Counts reflect the initial review. KAR-01 through KAR-05, KAR-07 through KAR-10, KAR-12, KAR-14 through KAR-20, KAR-22, KAR-25 and KAR-26 are implemented; KAR-06, KAR-11, KAR-13 and KAR-21 are accepted for this lab. KAR-23 needs bucket-level verification, and KAR-24's lock file awaits commit.

---

## Verification Performed

| Check | Result |
|---|---|
| `terraform validate` with Terraform `1.16.5` | ✅ Passed |
| `terraform fmt -check modules/eks/main.tf` | ✅ Passed after implementation |
| Karpenter `1.15.0` exists | ✅ |
| Karpenter ↔ Kubernetes compatibility | ✅ K8s `1.37` requires Karpenter `1.15.x` per the current compatibility matrix |

> **Note:** `.terraform.lock.hcl` is now allowed by `.gitignore` and present in the working tree; commit it to preserve the provider selections (KAR-24).

---

# P0 — Blockers

## KAR-01 — Karpenter controller has no AWS identity — RESOLVED ✅

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

## KAR-02 — Controller IAM policy is missing required permissions — IMPLEMENTED ✅

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

## KAR-03 — `EC2NodeClass` uses `role`, but the created instance profile is unused — RESOLVED ✅

**Status (2026-10-30):** RESOLVED. The official IAM integration policy added for KAR-02 grants the scoped instance-profile permissions that `spec.role` requires, and the unused Terraform-created instance profile has been removed.

**Files:** `resources/manifests/karpenter-nodepool.yaml:40`, `modules/eks/main.tf`

### Current implementation

- `resources/manifests/karpenter-nodepool.yaml` sets `role: "KarpenterNodeRole-CLUSTER_NAME"`, so Karpenter manages a generated instance profile for that role.
- `modules/eks/main.tf` no longer creates the unused `aws_iam_instance_profile.karpenter_node`.

---

## KAR-04 — Access policy association can race the access entry — RESOLVED ✅

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

## KAR-05 — Discovery tag is applied to the cluster security group too — RESOLVED ✅

**Status: RESOLVED (2026-11-03).**

**File:** `modules/eks/main.tf`

### Implementation

Removed `karpenter.sh/discovery` from the module's generic `tags` map. The tag now exists only in `node_security_group_tags`:

```hcl
node_security_group_tags = {
  "karpenter.sh/discovery" = var.eks_cluster_name
}
```

As a result, `securityGroupSelectorTerms` in the `EC2NodeClass` matches only the node security group. Validation: `terraform validate` and `terraform fmt -check modules/eks/main.tf` pass.

---

## KAR-06 — No interruption queue (SQS/EventBridge) — ACCEPTED (lab, no spot) ✅

**Status (2026-10-30):** Accepted risk for this lab. The NodePool is on-demand only and there is no plan to use spot capacity, so spot interruption handling is not required.

**File:** `resources/scripts/install-karpenter.sh`

**Decision:** Keep the chart installed without `settings.interruptionQueue`. No SQS queue, EventBridge rules, or SQS IAM permissions are added.

**Residual risk:** On-demand instances can still receive AWS Health scheduled maintenance events. Karpenter will not react to those through an interruption queue in this lab. If spot capacity is ever introduced, add the interruption queue first.

---

## KAR-07 — Teardown can leave EC2 instances and block VPC deletion — RESOLVED ✅

**Status: RESOLVED (2026-11-03).**

**File:** `resources/scripts/teardown-karpenter.sh`

### Implementation

The teardown script now:

- deletes NodePools without blocking, then waits up to 10 minutes for NodeClaims to be deleted;
- deletes any remaining NodeClaims and waits up to 5 minutes;
- deletes EC2NodeClasses only after NodeClaims are gone;
- polls for Karpenter-tagged EC2 instances in `pending`, `running`, `stopping` or `stopped` state and waits until none remain, using a 10-minute default timeout (`INSTANCE_WAIT_SECONDS` and `INSTANCE_POLL_SECONDS` override the timeout and poll interval);
- uninstalls Karpenter only after the instances are gone.

If the instance query fails or times out, the script prints a warning and continues. Validation: `bash -n resources/scripts/teardown-karpenter.sh` passes.

---

## KAR-08 — LB teardown hardcodes a load balancer name — RESOLVED ✅

**Status: RESOLVED (2026-11-03).**

**Files:** `resources/scripts/teardown-lb-controller.sh`, `.github/workflows/destroy.yml`

### Implementation

The teardown script now receives the cluster name and AWS region, enumerates load balancers in that region, and checks each resource's `elbv2.k8s.aws/cluster` tag using `aws elbv2 describe-tags`. It deletes and waits for deletion only for load balancers tagged for the target cluster. The hardcoded `shareduniralb` name is removed. `aws elbv2 describe-load-balancers` is used only to retrieve ARNs; tags are queried separately because that operation does not include tags.

---

## KAR-09 — Load Balancer Controller IAM is outside Terraform — RESOLVED ✅

**Status: RESOLVED (2026-11-03).**

**Files:** `modules/eks/main.tf`, `resources/policies/aws-load-balancer-controller-iam-policy-v2.14.1.json`, `resources/scripts/setup-lb-controller.sh`

### Implementation

- Terraform manages the versioned v2.14.1 LBC IAM policy, IRSA role, OIDC trust restricted to the `kube-system/aws-load-balancer-controller` service account, and policy attachment.
- The setup script retrieves that Terraform-created role and annotates the Kubernetes service account with its ARN; it no longer creates IAM resources with `aws iam` or `eksctl`.
- The role and policy are removed with the Terraform destroy.

---

## KAR-10 — LBC setup downloads unpinned CRDs and writes files into the repo — RESOLVED ✅

**Status: RESOLVED (2026-11-03).**

**File:** `resources/scripts/setup-lb-controller.sh`

### Implementation

- The controller image is pinned to `v2.14.1`, and the Helm chart is pinned to `1.14.1` (the chart release for controller `v2.14.1`).
- Both CRDs are fetched from the controller's `v2.14.1` Git tag with `curl -fsSL`.
- Downloads are stored under a `mktemp` directory and removed by an exit trap.
- IAM policy JSON is a checked-in, versioned file consumed by Terraform rather than downloaded into the working directory during setup.

---

# P2 — Medium (HA and security)

## KAR-11 — Single NAT gateway — ACCEPTED (lab, cost trade-off) ✅

**Status (2026-11-03):** Accepted risk for this lab.

**File:** `modules/vpc/main.tf`

**Decision:** Keep `single_nat_gateway = true` to limit lab costs. This is not a highly available NAT design: an outage in the NAT gateway's AZ can remove egress from private subnets. Revisit if the cluster becomes production or HA-critical.

---

## KAR-12 — Managed node and Karpenter replica redundancy — IMPLEMENTED ✅

**Files:** `terraform.auto.tfvars`, `resources/scripts/install-karpenter.sh`

**Current configuration checked and updated (2026-11-03):**

- The managed node group is configured with `min_size = 2`, `desired_size = 2`, and `max_size = 3` using `t3a.medium` instances. It receives the three private subnets in three Availability Zones, so the Auto Scaling group can balance the minimum two nodes across AZs.
- Karpenter runs two replicas with an explicit zone topology spread constraint (`maxSkew: 1`, `DoNotSchedule`). The chart also has required pod anti-affinity across nodes.
- The Karpenter PodDisruptionBudget is explicitly set to `maxUnavailable: 1`, allowing at most one controller replica to be voluntarily disrupted at a time.

The managed group now retains at least two nodes, while the two controllers are spread across zones and protected from simultaneous voluntary eviction. Auto Scaling balances across the configured subnets, but this is not a strict per-AZ guarantee during capacity shortages or AZ failures. Karpenter requests remain 1 CPU and 1 GiB per replica, so the managed nodes must have enough schedulable capacity for system addons and both replicas.

---

## KAR-13 — Public EKS endpoint open to `0.0.0.0/0` — ACCEPTED (lab) ✅

**Status (2026-11-03):** Accepted risk for this lab.

**File:** `modules/eks/main.tf`

**Decision:** Keep `endpoint_public_access = true` with the module's default public access CIDR. This allows cluster administration from changing lab/client networks without maintaining an allowlist or operating private access infrastructure. The EKS API endpoint is publicly reachable; authentication and EKS access policies remain required. Restrict the CIDR or use private access before production use.

---

## KAR-14 — Control plane logging is disabled — RESOLVED ✅

**Status: RESOLVED (2026-11-03).**

**File:** `modules/eks/main.tf`

### Implementation

The EKS module now enables all five control-plane log types: `audit`, `api`, `authenticator`, `controllerManager` and `scheduler`, using the module's `enabled_log_types` argument. The EKS module manages the associated CloudWatch log group.

---

## KAR-15 — Control plane ENIs are placed in public subnets — RESOLVED ✅

**Status: RESOLVED (2026-11-03).**

**File:** `modules/eks/main.tf`

### Implementation

`control_plane_subnet_ids` now uses `var.vpc_private_subnets`, the same private subnets used by the EKS managed node group. Public EKS API endpoint access is configured separately and remains enabled per the accepted KAR-13 lab decision.

---

## KAR-16 — Public subnets auto-assign public IPs — RESOLVED ✅

**Status: RESOLVED (2026-11-03).**

**File:** `modules/vpc/main.tf`

### Implementation

Set `map_public_ip_on_launch = false`. Instances launched in public subnets no longer receive public IPv4 addresses automatically. EKS managed and Karpenter nodes are in private subnets and were not affected by this setting.

---

## KAR-17 — IMDSv2 is not enforced on Karpenter nodes — RESOLVED ✅

**Status: RESOLVED (2026-11-03).**

**File:** `resources/manifests/karpenter-nodepool.yaml`

### Implementation

The `EC2NodeClass` now enables the metadata endpoint, requires IMDSv2 tokens, and sets `httpPutResponseHopLimit: 1`. Workloads should use their assigned pod identity rather than retrieving node-role credentials from IMDS.

---

# P3 — Low / Cost

## KAR-18 — NodePool CPU limit is effectively unlimited — RESOLVED ✅

**Status: RESOLVED (2026-11-03).**

**File:** `resources/manifests/karpenter-nodepool.yaml`

### Implementation

The NodePool now caps aggregate capacity at `20` CPUs and `60Gi` memory.

---

## KAR-19 — No instance-size constraint — RESOLVED ✅

**Status: RESOLVED (2026-11-03).**

**File:** `resources/manifests/karpenter-nodepool.yaml`

### Implementation

The NodePool limits eligible instances to `small` and `medium` sizes, and requires instance generation greater than 2.

---

## KAR-20 — Aggressive consolidation — RESOLVED ✅

**Status: RESOLVED (2026-11-03).**

**File:** `resources/manifests/karpenter-nodepool.yaml`

### Implementation

The NodePool uses `consolidationPolicy: Balanced` and `consolidateAfter: 10m`.

---

## KAR-21 — On-demand only, no spot capacity — ACCEPTED (intentional) ✅

**Status (2026-10-30):** Intentional for this lab. Spot capacity will not be used.

**File:** `resources/manifests/karpenter-nodepool.yaml:15-17`

```yaml
- key: karpenter.sh/capacity-type
  operator: In
  values: ["on-demand"]
```

**Decision:** Keep the NodePool on-demand only. Spot cost savings are not a goal for this lab, and avoiding spot also removes the need for interruption handling (KAR-06).

---

## KAR-22 — No disruption budgets — RESOLVED ✅

**Status: RESOLVED (2026-11-03).**

**File:** `resources/manifests/karpenter-nodepool.yaml`

### Implementation

The NodePool sets a disruption budget of `10%` (`disruption.budgets[].nodes`), limiting voluntary Karpenter disruptions.

---

# P4 — Hygiene

## KAR-23 — S3 backend has no encryption or state locking — IMPLEMENTED ✅

**Status (2026-11-03):** Backend configuration fix implemented.

**File:** `provider.tf`

### Implementation

The S3 backend now sets `encrypt = true` and `use_lockfile = true`, enabling encrypted state and native S3 state locking. Bucket versioning and Block Public Access are bucket-level settings not configured in this Terraform backend block; verify they are enabled on the existing bucket.

---

## KAR-24 — `.terraform.lock.hcl` is ignored — IMPLEMENTED (commit pending)

**Status (2026-11-03):** The ignore exception is in place and the generated lock file is present in the working tree, but it remains untracked and still needs to be committed.

**Files:** `.gitignore`, `.terraform.lock.hcl`

### Implementation

`.gitignore` now retains the general `*.hcl` ignore rule while adding `!.terraform.lock.hcl`. The lock file pins the resolved provider versions and checksums. Add and commit `.terraform.lock.hcl` with the project changes.

---

## KAR-25 — CRLF line endings in Terraform files — RESOLVED ✅

**Status: RESOLVED (2026-11-03).**

**File:** `.gitattributes`

### Implementation

Added explicit LF rules for Terraform (`.tf`, `.tfvars`, `.hcl`), Markdown, shell scripts, YAML and JSON, plus `text=auto` for other text files. Normalized the current working-tree files to LF without staging them, preserving existing edits. Git will now check out the configured files with LF endings, and future commits will have normalized line endings.

---

## KAR-26 — `modules/eks/main.tf` is not formatted — RESOLVED ✅

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

2. **No concurrency control.** Two workflow runs can overlap. Native S3 state locking is now enabled (KAR-23), but workflow serialization still prevents duplicate concurrent deploy/destroy operations. Add:

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
- **KAR-03:** `spec.role` is authorized; the unused Terraform-created instance profile has been removed.
- **KAR-04:** access entries now use the module-native `policy_associations`.

Remaining:

1. Deploy and verify with a smoke test (KAR-33).

## Phase 2 — Reliability and teardown (P1)

Completed:

- **KAR-05:** discovery tag scoped to the node security group.
- **KAR-07:** teardown waits for NodeClaims and EC2 instances.
- **KAR-08:** teardown discovers cluster load balancers by tag.
- **KAR-09:** LBC IAM policy and IRSA role managed by Terraform.
- **KAR-10:** LBC chart and CRDs are version-pinned; downloads are temporary.

The interruption queue and single NAT gateway are accepted lab trade-offs (KAR-06 and KAR-11).

## Phase 3 — HA and security (P2)

Implemented:

- **KAR-14:** all EKS control-plane log types enabled.
- **KAR-15:** control-plane ENIs use private subnets.
- **KAR-16:** public subnet auto-assignment of public IPs disabled.
- **KAR-17:** IMDSv2 required on Karpenter-launched nodes.

Accepted for the lab:

- **KAR-13:** public EKS API endpoint access.

Restrict public API access before production use. Public subnet auto-assignment is already disabled.

## Phase 4 — Cost and tuning (P3)

Implemented: NodePool limits (KAR-18), instance-size constraints (KAR-19), balanced consolidation (KAR-20), and disruption budgets (KAR-22).

Spot capacity is intentionally out of scope for this lab (KAR-21).

## Phase 5 — Hygiene (P4)

1. Verify S3 bucket versioning and Block Public Access (KAR-23).
2. Commit `.terraform.lock.hcl` (KAR-24).
3. Finish formatting untouched Terraform files (KAR-26).
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
