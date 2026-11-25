## 🚀 About Me

I'm a junior DevOps engineer with some expertise in BackEnd development using Java and Node.js; scripting skills with Python, Bash and JavaScript; besides CI/CD and cloud knowledge of AWS and Azure DevOps.

<p align="center">
<img src="https://c4.wallpaperflare.com/wallpaper/694/164/1000/digital-art-animals-eagle-bird-of-prey-birds-hd-wallpaper-preview.jpg" alt="Logo" width="400" height="230">
</p>

![linux](https://img.shields.io/badge/Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black)
![python](https://img.shields.io/badge/Python-3774AB?style=for-the-badge&logo=python&logoColor=white)
![javascript](https://img.shields.io/badge/JavaScript-F7DF1E?style=for-the-badge&logo=javascript&logoColor=black)
![nodejs](https://img.shields.io/badge/Node.js-43853D?style=for-the-badge&logo=node.js&logoColor=white)
![mysql](https://img.shields.io/badge/MySQL-005C84?style=for-the-badge&logo=mysql&logoColor=white)
![jenkins](https://img.shields.io/badge/Jenkins-D24939?style=for-the-badge&logo=Jenkins&logoColor=white)
![aws](https://img.shields.io/badge/Amazon_AWS-FF9900?style=for-the-badge&logo=amazonaws&logoColor=white)
![azuredevops](https://img.shields.io/badge/Azure_DevOps-0078D7?style=for-the-badge&logo=azure-devops&logoColor=white)

## 🔗 Portfolio

[![portfolio](https://img.shields.io/badge/GitHub-100000?style=for-the-badge&logo=github&logoColor=white)](https://github.com/RecursiveDeveloper)
[![linkedin](https://img.shields.io/badge/linkedin-0A66C2?style=for-the-badge&logo=linkedin&logoColor=white)](https://www.linkedin.com/in/jhoan-jesus-ortiz-sandoval-a66152198/)

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

This project uses **Karpenter** for node autoscaling instead of the Cluster Autoscaler. Karpenter provisions EC2 instances directly via the EC2 fleet API, providing faster scale-up and better bin-packing than Kubernetes-managed node groups.

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

> If you need to use a different bucket name, update the `bucket` field in both [`provider.tf`](provider.tf) and [`bootstrap/backend.tf`](bootstrap/backend.tf) before running `terraform init`. The bucket name must be globally unique.

### 2. One-Time GitHub OIDC Bootstrap

GitHub Actions authenticates to AWS with short-lived credentials obtained through GitHub OIDC. Long-lived AWS access keys are not stored as repository secrets.

The separate [`bootstrap/`](bootstrap/) stack creates the GitHub OIDC provider and the `github-actions-deploy` IAM role. Its state is independent from the main stack, so running the destroy workflow does not remove the CI identity.

1. **Configure the repository subject.** The default `github_oidc_subject` in [`bootstrap/variables.tf`](bootstrap/variables.tf) allows only `workflow_dispatch` runs from this repository's `main` branch:
   ```text
   repo:RecursiveDeveloper/eks_terraform_ha-lab:ref:refs/heads/main
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

Do not configure `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` for the workflows. The deploy role has `AdministratorAccess`, so protect `main` and review workflow changes carefully: only runs dispatched from `main` may assume it.

## Usage

### GitHub Actions Deployment

Trigger the workflow manually from the **Actions** tab using `workflow_dispatch` on `main`. Select either `deploy` or `destroy` as the action. The OIDC trust policy rejects dispatches from other branches or workflows.

The workflow is defined in `.github/workflows/main.yml` and delegates to:
- `.github/workflows/deploy.yml` — provisions infrastructure, installs controllers, and runs a Karpenter smoke test
- `.github/workflows/destroy.yml` — tears down controllers and destroys infrastructure

The smoke test creates a temporary, tainted `karpenter-smoke-test` NodePool that reuses the `default` EC2NodeClass. A test workload with the matching toleration and node selector triggers isolated capacity. The test pool is tainted with `laboratory=true:NoSchedule`, so only its designated workload can use it.

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

The AWS identity used to deploy the cluster is automatically granted admin access via `enable_cluster_creator_admin_permissions`. Additional DevOps users are granted cluster admin access through the IAM module's access entries.

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

Never commit `.tfstate` files, `.terraform/` directories, saved plans, or generated outputs. Commit the bootstrap source and its `.terraform.lock.hcl`; each operator's `bootstrap.tfstate` remains local and is ignored.

## Notes

- The VPC and EKS modules use the official [terraform-aws-modules](https://github.com/terraform-aws-modules) for best practices.
- IAM resources are created for demonstration purposes and should be reviewed before production use.
- Karpenter interruption handling (SQS/EventBridge) is not configured since the cluster uses on-demand instances only.

## Authors

- [@RecursiveDeveloper](https://github.com/RecursiveDeveloper)


## License

[MIT](https://choosealicense.com/licenses/mit/)
