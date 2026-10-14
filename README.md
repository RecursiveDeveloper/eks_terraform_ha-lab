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
    │   ├── teardown-lb-controller.sh
    │   └── teardown-karpenter.sh
    └── manifests/
        └── karpenter-nodepool.yaml
```

## Features

- **VPC Module:** Provisions a VPC with public and private subnets across multiple AZs, tagged for Karpenter subnet discovery.
- **IAM Module:** Creates IAM users, groups, and policies for DevOps access.
- **EKS Module:** Deploys an EKS cluster with managed node groups, EKS managed addons, Karpenter IAM roles, and access entries.

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
- Instance categories: `c`, `m`, `r` (generation > 2)
- Consolidation policy: `WhenEmptyOrUnderutilized`
- Node expiry: 30 days

## Prerequisites

Before deploying this Terraform configuration, ensure the following are in place:

### 1. S3 Backend Bucket

Create an S3 bucket named `tf-backend-lab-s3` in `us-east-1` to store the Terraform state file:

```sh
aws s3 mb s3://tf-backend-lab-s3 --region us-east-1
```

> If you need to use a different bucket name, update the `bucket` field in [`provider.tf`](provider.tf) before running `terraform init`:
> ```hcl
> backend "s3" {
>   bucket = "your-bucket-name"
>   ...
> }
> ```

### 2. GitHub Actions Secrets

Configure the following secrets in your GitHub repository:

| Secret | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | AWS access key ID |
| `AWS_SECRET_ACCESS_KEY` | AWS secret access key |

The IAM user behind these credentials needs permissions to create EKS, VPC, IAM, and EC2 resources.

## Usage

### GitHub Actions Deployment

Trigger the workflow manually from the **Actions** tab using `workflow_dispatch`. Select either `deploy` or `destroy` as the action.

The workflow is defined in `.github/workflows/main.yml` and delegates to:
- `.github/workflows/deploy.yml` — provisions infrastructure and installs controllers
- `.github/workflows/destroy.yml` — tears down controllers and destroys infrastructure

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

The IAM user used to deploy the cluster is automatically granted admin access via `enable_cluster_creator_admin_permissions`. Additional DevOps users are granted cluster admin access through EKS access entries.

## Modules

- [`modules/vpc`](modules/vpc/main.tf): Provisions the VPC, public/private subnets, NAT gateway, and Karpenter discovery tags.
- [`modules/iam`](modules/iam/main.tf): Manages IAM users, groups, and policies for DevOps access.
- [`modules/eks`](modules/eks/main.tf): Deploys the EKS cluster, managed node groups, EKS addons, Karpenter node and controller IAM roles, instance profile, and access entries.

## Requirements

| Tool | Version |
|---|---|
| Terraform | >= 1.16.5 |
| AWS CLI | >= v2 |
| kubectl | compatible with Kubernetes 1.33 |
| helm | >= 3 |
| eksctl | latest |

AWS account permissions required: EKS, VPC, IAM, EC2.

## Customization

Edit [`terraform.auto.tfvars`](terraform.auto.tfvars) to set:
- VPC name, CIDR, subnets, and AZs
- EKS cluster name and node group configuration

## Notes

- The VPC and EKS modules use the official [terraform-aws-modules](https://github.com/terraform-aws-modules) for best practices.
- IAM resources are created for demonstration purposes and should be reviewed before production use.
- Karpenter interruption handling (SQS/EventBridge) is not configured since the cluster uses on-demand instances only.

## Authors

- [@RecursiveDeveloper](https://github.com/RecursiveDeveloper)


## License

[MIT](https://choosealicense.com/licenses/mit/)
