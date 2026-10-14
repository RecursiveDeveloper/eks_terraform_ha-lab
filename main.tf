module "vpc" {
  source = "./modules/vpc"

  vpc_name            = var.vpc_name
  vpc_cidr            = var.vpc_cidr
  vpc_azs             = var.vpc_azs
  vpc_private_subnets = var.vpc_private_subnets
  vpc_public_subnets  = var.vpc_public_subnets
  eks_cluster_name    = var.eks_cluster_name
}

module "iam" {
  source = "./modules/iam"
}

module "eks" {
  source = "./modules/eks"

  devops_user1_arn        = module.iam.devops_user1_arn
  devops_user2_arn        = module.iam.devops_user2_arn
  vpc_id                  = module.vpc.vpc_id
  vpc_public_subnets      = module.vpc.vpc_public_subnet_ids
  vpc_private_subnets     = module.vpc.vpc_private_subnet_ids
  eks_cluster_name        = var.eks_cluster_name
  eks_managed_node_groups = var.eks_managed_node_groups
}

output "karpenter_node_role_arn" {
  description = "ARN of the Karpenter node IAM role"
  value       = module.eks.karpenter_node_role_arn
}

output "karpenter_controller_role_arn" {
  description = "ARN of the Karpenter controller IRSA role"
  value       = module.eks.karpenter_controller_role_arn
}