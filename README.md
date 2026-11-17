# EKS Terraform Architecture

This project provides a modular Terraform configuration to provision an AWS EKS (Elastic Kubernetes Service) cluster, including VPC networking, IAM resources, and Karpenter for node autoscaling.

## Project Architecture
![image](https://raw.githubusercontent.com/RecursiveDeveloper/static-media-content/refs/heads/main/HA_Eks_Terraform-Diagram.jpg)

## Project Structure

```
eks-terraform/
├── main.tf
├── variables.tf
├── provider.tf
├── terraform.auto.tfvars
├── README.md
├── bootstrap/
│   ├── backend.tf
│   ├── main.tf
│   ├── outputs.tf
│   └── variables.tf
├── .github/
│   ├── actions/
│   │   └── setup-composite/
│   │       └── action.yml
│   └── workflows/
│       ├── main.yml
│       ├── deploy.yml
│       └── destroy.yml
├── modules/
│   ├── eks/
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   └── variables.tf
│   ├── iam/
│   │   ├── main.tf
│   │   └── outputs.tf
│   └── vpc/
│       ├── main.tf
│       ├── outputs.tf
│       └── variables.tf
└── resources/
    ├── scripts/
    │   ├── setup-lb-controller.sh
    │   ├── install-karpenter.sh
    │   ├── smoke-test-karpenter.sh
    │   ├── teardown-lb-controller.sh
    │   └── teardown-karpenter.sh
    └── manifests/
        └── karpenter-nodepool.yaml
```

## Features

- **VPC Module:** Provisions a VPC with public and private subnets across multiple AZs, tagged for Karpenter subnet discovery.
- **IAM Module:** Manages two IAM users for DevOps; their cluster access is granted through EKS access entries.
- **EKS Module:** Deploys an EKS cluster with managed node groups, EKS managed addons, Karpenter IAM roles, and access entries.
- **GitHub OIDC Bootstrap:** Manages the GitHub OIDC provider and the short-lived AWS role used by CI, in separate state that survives main-stack destroy cycles.

## EKS Managed Addons

The following addons are managed directly by EKS:

| Addon | Purpose |
|---|---|
| `coredns` | Cluster DNS |
| `kube-proxy` | Network proxy |
| `vpc-cni` | Pod networking |
| `aws-ebs-csi-driver` | EBS volume support |
| `eks-pod-identity-agent` | Pod identity |
| `metrics-server` | Resource metrics for HPA and kubectl top |

## Node Autoscaling

This project uses **Karpenter** for node autoscaling instead of the Cluster Autoscaler. Karpenter provisions EC2 instances directly via the EC2 fleet API, providing faster scale-up and better bin-packing than ASG-based scaling.

The NodePool is configured with:
- Architecture: `amd64`, OS: `linux`
- Capacity type: `on-demand`
- Instance sizes: `small`, `medium` (generation > 2)
- Aggregate limits: 20 CPUs and 60 GiB memory
- Balanced consolidation after 10 minutes, with a 10% disruption budget
- Node expiry: 30 days

## Prerequisites

Before deploying this Terraform configuration, ensure the following are in place:

### 1. S3 Backend Bucket

Create an S3 bucket named `tf-backend-lab-s3` in `us-east-1` to store the main and bootstrap Terraform state files:

```sh
aws s3 mb s3://tf-backend-lab-s3 --region us-east-1
```

> If you need to use a different bucket name, update the `bucket` field in both [`provider.tf`](provider.tf) and [`bootstrap/backend.tf`](bootstrap/backend.tf) before running `terraform init`. The bucket must be created outside Terraform because it stores the state for both stacks. Versioning, default encryption, and Block Public Access should be enabled on it.

### 2. One-Time GitHub OIDC Bootstrap

GitHub Actions authenticates to AWS with short-lived credentials obtained through GitHub OIDC. Long-lived AWS access keys are not stored as repository secrets.

The separate [`bootstrap/`](bootstrap/) stack creates the GitHub OIDC provider and the `github-actions-deploy` IAM role. Its state is independent from the main stack, so running the destroy workflow does not remove the role required by future deployments.

1. **Configure the repository subject.** The default `github_oidc_subject` in [`bootstrap/variables.tf`](bootstrap/variables.tf) allows only `workflow_dispatch` runs from this repository's `main` branch:
   ```hcl
   github_oidc_subject = "repo:RecursiveDeveloper/eks_terraform_ha-lab:ref:refs/heads/main"
   ```

   Repositories using GitHub's immutable subject claims instead require the owner and repository IDs:
   ```text
   repo:OWNER@OWNER-ID/REPOSITORY@REPOSITORY-ID:ref:refs/heads/main
   ```

2. **Check for an existing GitHub OIDC provider:**
   ```sh
   aws iam list-open-id-connect-providers
   ```
   AWS permits only one provider for `token.actions.githubusercontent.com` per account. If one already exists, import it after initialization in the next step instead of creating a duplicate.

3. **Authenticate locally with administrative AWS credentials and apply only the bootstrap stack:**
   ```sh
   cd bootstrap
   terraform init

   # Only when the provider already exists:
   terraform import aws_iam_openid_connect_provider.github <existing-provider-arn>

   terraform plan
   terraform apply
   terraform output -raw github_actions_role_arn
   ```

   Copy the returned role ARN for the next step. CI never manages this bootstrap stack; local administrative credentials are used for its initial apply and eventual destroy.

### 3. GitHub Actions Secret

Configure this secret in your GitHub repository:

| Secret | Description |
|---|---|
| `AWS_DEPLOY_ROLE_ARN` | ARN of the `github-actions-deploy` role created by the bootstrap stack |

Do not configure `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` for the workflows. The deploy role has `AdministratorAccess`, so protect `main` and review workflow changes carefully: only runs dispatched from `main` are allowed to assume it.

## Usage

### GitHub Actions Deployment

Trigger the workflow manually from the **Actions** tab using `workflow_dispatch` on `main`. Select either `deploy` or `destroy` as the action. The OIDC trust policy rejects dispatches from other branches.

The workflow is defined in `.github/workflows/main.yml` and delegates to:
- `.github/workflows/deploy.yml` — provisions infrastructure, installs controllers, and runs a Karpenter smoke test
- `.github/workflows/destroy.yml` — tears down controllers and destroys infrastructure

The smoke test creates a temporary, tainted `karpenter-smoke-test` NodePool that reuses the `default` EC2NodeClass. A test workload with the matching toleration and node selector triggers isolated capacity, verifies the resulting NodeClaim is `Ready`, and checks controller logs for AWS authorization errors. Cleanup removes the workload, temporary NodePool, and its owned NodeClaims without selecting or deleting nodes from the existing `default` NodePool. A failed test fails the deployment workflow. Each run temporarily creates one small on-demand EC2 instance.

### Local Deployment

1. **Configure your AWS credentials:**
   ```sh
   aws configure
   ```

2. **Review and update variables:**
   Edit `terraform.auto.tfvars` to match your desired configuration. Make sure to set `eks_cluster_name` since it is injected automatically by the workflow but has no default value:
   ```hcl
   eks_cluster_name = "devopslab-eks"
   ```

3. **Initialize Terraform:**
   ```sh
   terraform init
   ```

4. **Plan the deployment:**
   ```sh
   terraform plan
   ```

5. **Apply the configuration:**
   ```sh
   terraform apply
   ```

## Recreating and Completely Removing the Lab

For ordinary lab cycles, dispatch `destroy` and later `deploy` from `main`. These operations affect only the main stack; the bootstrap role and state persist and do not need to be recreated.

To remove the entire lab and its CI identity:

1. Dispatch the `destroy` workflow from `main` and wait for it to finish.
2. From a local administrative AWS session, destroy the bootstrap stack:
   ```sh
   cd bootstrap
   terraform destroy
   ```
3. Delete the `AWS_DEPLOY_ROLE_ARN` repository secret.
4. Delete the S3 backend bucket and both state objects.
5. Delete the local clone or GitHub repository if desired.

If the AWS account is shared with other projects, do not delete a GitHub OIDC provider that other roles still use. Remove only this lab's deploy role instead.

## Connecting to the EKS Cluster

1. **Update kubeconfig:**
   ```sh
   aws eks update-kubeconfig --region us-east-1 --name <cluster-name>
   ```

2. **Verify access:**
   ```sh
   kubectl get nodes
   kubectl get pods -A
   ```

The AWS identity used to deploy the cluster is automatically granted admin access via `enable_cluster_creator_admin_permissions`. Additional DevOps users are granted cluster admin access through EKS access entries.

## Modules

- [`modules/vpc`](modules/vpc/main.tf): Provisions the VPC, public/private subnets, NAT gateway, and Karpenter discovery tags.
- [`modules/iam`](modules/iam/main.tf): Manages the two DevOps IAM users.
- [`modules/eks`](modules/eks/main.tf): Deploys EKS, managed node groups, addons, Karpenter and AWS Load Balancer Controller IAM roles/policies, and access entries.

## Requirements

### Tooling

| Tool | Version |
|---|---|
| Terraform | >= 1.16.5 |
| AWS CLI | >= v2 |
| kubectl | compatible with Kubernetes 1.37 |
| helm | >= 3 |
| eksctl | latest |

### Provider and Module Versions

Pinned in [`provider.tf`](provider.tf) and the module sources:

| Component | Version | Source |
|---|---|---|
| AWS provider (`hashicorp/aws`) | `6.69.0` | [`provider.tf`](provider.tf) |
| `terraform-aws-modules/eks/aws` | `21.29.0` | [`modules/eks/main.tf`](modules/eks/main.tf) |
| `terraform-aws-modules/vpc/aws` | `6.7.3` | [`modules/vpc/main.tf`](modules/vpc/main.tf) |

### Kubernetes and Controllers

| Component | Version | Source |
|---|---|---|
| Kubernetes (EKS) | `1.37` | `kubernetes_version` in [`modules/eks/main.tf`](modules/eks/main.tf) |
| Karpenter | `1.15.0` | `KARPENTER_VERSION` in [`resources/scripts/install-karpenter.sh`](resources/scripts/install-karpenter.sh) |
| AWS Load Balancer Controller | `v2.14.1` | `LB_CONTROLLER_VERSION` in [`resources/scripts/setup-lb-controller.sh`](resources/scripts/setup-lb-controller.sh) |

EKS managed addons (`coredns`, `kube-proxy`, `vpc-cni`, `aws-ebs-csi-driver`, `eks-pod-identity-agent`, `metrics-server`) track the cluster's Kubernetes version automatically.

AWS account permissions required: EKS, VPC, IAM, EC2.

## Customization

Edit [`terraform.auto.tfvars`](terraform.auto.tfvars) to set:
- VPC name, CIDR, subnets, and AZs
- EKS cluster name and node group configuration

### Forking or Reusing the Lab

An independent operator needs their own GitHub repository and AWS account. A clone inherits the source code, not AWS access, GitHub secrets, or Terraform state.

Before deploying a fork:

1. Create a globally unique S3 backend bucket and update both backend configurations.
2. Set `github_oidc_subject` to the exact subject issued for the fork's repository and `main` branch, using the immutable format if applicable.
3. Update the cluster name and AWS region if necessary.
4. Run the one-time bootstrap locally and configure `AWS_DEPLOY_ROLE_ARN` in the fork.
5. Merge the configuration to `main` and dispatch the deploy workflow there.

Never commit `.tfstate` files, `.terraform/` directories, saved plans, or generated outputs. Commit the bootstrap source and its `.terraform.lock.hcl`; each operator's `bootstrap.tfstate` remains private in that operator's S3 backend.

## Notes

- The VPC and EKS modules use the official [terraform-aws-modules](https://github.com/terraform-aws-modules) for best practices.
- IAM resources are created for demonstration purposes and should be reviewed before production use.
- Karpenter interruption handling (SQS/EventBridge) is not configured since the cluster uses on-demand instances only.

## Authors

- [@RecursiveDeveloper](https://github.com/RecursiveDeveloper)


## License

[MIT](https://choosealicense.com/licenses/mit/)
