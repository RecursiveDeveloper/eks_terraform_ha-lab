variable "vpc_name" {
  description = "Name of the VPC"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "vpc_azs" {
  description = "Availability Zones for the VPC"
  type        = list(string)
}

variable "vpc_private_subnets" {
  description = "List of private subnet CIDR blocks"
  type        = list(string)
}

variable "vpc_public_subnets" {
  description = "List of public subnet CIDR blocks"
  type        = list(string)
}

variable "eks_cluster_name" {
  description = "EKS cluster name, used for Karpenter subnet discovery tag"
  type        = string
}