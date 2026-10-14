output "karpenter_node_role_arn" {
  description = "ARN of the Karpenter node IAM role"
  value       = aws_iam_role.karpenter_node.arn
}

output "karpenter_controller_role_arn" {
  description = "ARN of the Karpenter controller IRSA role"
  value       = aws_iam_role.karpenter_controller.arn
}
