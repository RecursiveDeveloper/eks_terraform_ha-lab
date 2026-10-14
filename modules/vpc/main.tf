module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = var.vpc_name
  cidr = var.vpc_cidr

  azs             = var.vpc_azs
  private_subnets = var.vpc_private_subnets
  public_subnets  = var.vpc_public_subnets

  enable_dns_hostnames      = true
  enable_dns_support        = true
  enable_nat_gateway        = true
  single_nat_gateway        = true
  map_public_ip_on_launch   = true

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }

  private_subnet_tags = {
    "karpenter.sh/discovery" = var.eks_cluster_name
  }
}