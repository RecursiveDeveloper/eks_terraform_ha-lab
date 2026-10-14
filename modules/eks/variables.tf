variable "devops_user1_arn" {
  description = "ARN of the IAM DevOps user 1"
  type        = string
}

variable "devops_user2_arn" {
  description = "ARN of the IAM DevOps user 2"
  type        = string
}

variable "vpc_id" {
  description = "The VPC ID where the EKS cluster will be created"
  type        = string
}

variable "vpc_public_subnets" {
  description = "List of public subnet IDs for the EKS cluster"
  type        = list(string)
}

variable "vpc_private_subnets" {
  description = "List of private subnet IDs for the EKS cluster"
  type        = list(string)
}

variable "eks_cluster_name" {
  description = "The name of the EKS cluster"
  type        = string
}

variable "eks_managed_node_groups" {
  description      = "EKS managed node groups configuration"
  type             = map(object({
    capacity_type  = string
    ami_type       = string
    instance_types = list(string)
    min_size       = number
    max_size       = number
    desired_size   = number
  }))
}