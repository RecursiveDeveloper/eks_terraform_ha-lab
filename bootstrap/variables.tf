variable "github_oidc_subject" {
  description = "Exact GitHub OIDC subject allowed to assume the deploy role"
  type        = string
  default     = "repo:RecursiveDeveloper/eks_terraform_ha-lab:ref:refs/heads/main"
}
