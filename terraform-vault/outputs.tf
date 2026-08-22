output "kubernetes_auth_role" {
  description = "Vault Kubernetes auth role name the test pod logs in as."
  value       = module.kubernetes_auth.role_name
}

output "aws_creds_path" {
  description = "Vault path the test pod reads to get AWS credentials (vault read -format=json <this>)."
  value       = module.aws.creds_path
}
