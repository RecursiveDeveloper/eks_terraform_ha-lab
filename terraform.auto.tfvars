vpc_name              = "devopslab-vpc"
vpc_cidr              = "10.0.0.0/16"
vpc_azs               = ["us-east-1a", "us-east-1b", "us-east-1c"]
vpc_private_subnets   = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
vpc_public_subnets    = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]

eks_managed_node_groups = {
  "devopslab-node-group" = {
    capacity_type  = "ON_DEMAND"
    ami_type       = "AL2023_x86_64_STANDARD"
    instance_types = ["t3a.medium"]
    min_size       = 1
    max_size       = 4
    desired_size   = 1
  }
}
