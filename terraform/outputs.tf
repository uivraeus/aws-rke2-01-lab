output "control_instance_id" {
  value = aws_instance.control.id
}

output "worker_instance_id" {
  value = aws_instance.worker.id
}

output "control_private_ip" {
  value = aws_instance.control.private_ip
}

output "worker_private_ip" {
  value = aws_instance.worker.private_ip
}

output "ssm_bucket_name" {
  value = aws_s3_bucket.ssm_transfer.bucket
}

output "aws_profile" {
  value = var.aws_profile
}

output "aws_region" {
  value = var.aws_region
}

output "cluster_name" {
  value = var.cluster_name
}

output "tunnel_command" {
  description = "Run this (in a separate shell) to reach the Kubernetes API from your laptop."
  value       = "aws ssm start-session --profile ${var.aws_profile} --region ${var.aws_region} --target ${aws_instance.control.id} --document-name AWS-StartPortForwardingSession --parameters '{\"portNumber\":[\"6443\"],\"localPortNumber\":[\"6443\"]}'"
}

output "oidc_bucket_name" {
  description = "S3 bucket kept in sync with the RKE2 cluster's OIDC discovery document and JWKS (see `make sync-oidc`)."
  value       = aws_s3_bucket.oidc.bucket
}

output "oidc_issuer_url" {
  description = "Value set as --service-account-issuer on the RKE2 kube-apiserver."
  value       = local.oidc_issuer_url
}

output "oidc_jwks_uri" {
  description = "Value set as --service-account-jwks-uri on the RKE2 kube-apiserver."
  value       = "${local.oidc_issuer_url}/keys.json"
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC identity provider, used as the Federated principal for other IRSA roles."
  value       = aws_iam_openid_connect_provider.cluster.arn
}

output "irsa_role_arn" {
  description = "Role ARN to set on the verification ServiceAccount's IRSA annotation (eks.amazonaws.com/role-arn)."
  value       = aws_iam_role.irsa_test.arn
}

output "irsa_test_bucket_name" {
  description = "Private bucket the IRSA role can read/write, used to verify IRSA end to end from a pod."
  value       = aws_s3_bucket.irsa_test.bucket
}

# The five outputs below are null when enable_vault = false (see vault.tf).

output "vault_instance_id" {
  description = "Instance ID of the standalone Vault instance, if enabled."
  value       = var.enable_vault ? aws_instance.vault[0].id : null
}

output "vault_private_ip" {
  description = "Private IP of the standalone Vault instance (used as VAULT_ADDR by Ansible and pods), if enabled."
  value       = var.enable_vault ? aws_instance.vault[0].private_ip : null
}

output "vault_test_role_arn" {
  description = "Role ARN Vault's AWS secrets engine assumes on behalf of pods (terraform-vault/modules/aws), if enabled."
  value       = var.enable_vault ? aws_iam_role.vault_test[0].arn : null
}

output "vault_test_bucket_name" {
  description = "Private bucket the Vault-issued role can read/write, used to verify the Vault credential chain end to end, if enabled."
  value       = var.enable_vault ? aws_s3_bucket.vault_test[0].bucket : null
}

output "vault_tunnel_command" {
  description = "Run this (in a separate shell) to reach the Vault API from your laptop - needed for terraform-vault/ runs and for the manual verification steps, if enabled."
  value       = var.enable_vault ? "aws ssm start-session --profile ${var.aws_profile} --region ${var.aws_region} --target ${aws_instance.vault[0].id} --document-name AWS-StartPortForwardingSession --parameters '{\"portNumber\":[\"8200\"],\"localPortNumber\":[\"8200\"]}'" : null
}

# The six outputs below are null when enable_rolesanywhere = false (see rolesanywhere.tf).

output "rolesanywhere_trust_anchor_arn" {
  description = "ARN of the Roles Anywhere trust anchor, if enabled."
  value       = var.enable_rolesanywhere ? aws_rolesanywhere_trust_anchor.cluster[0].arn : null
}

output "rolesanywhere_profile_arn" {
  description = "ARN of the Roles Anywhere profile, if enabled."
  value       = var.enable_rolesanywhere ? aws_rolesanywhere_profile.cluster[0].arn : null
}

output "rolesanywhere_role_arn" {
  description = "Role ARN the Roles Anywhere profile assumes for the verification workload, if enabled."
  value       = var.enable_rolesanywhere ? aws_iam_role.rolesanywhere_test[0].arn : null
}

output "rolesanywhere_test_bucket_name" {
  description = "Private bucket the Roles Anywhere-issued role can read/write, used to verify the credential chain end to end, if enabled."
  value       = var.enable_rolesanywhere ? aws_s3_bucket.rolesanywhere_test[0].bucket : null
}

output "rolesanywhere_ca_cert_pem" {
  description = "PEM-encoded certificate of the Roles Anywhere root CA - load into cert-manager's ClusterIssuer (see manifests/rolesanywhere-ca-issuer.yaml), if enabled."
  value       = var.enable_rolesanywhere ? tls_self_signed_cert.rolesanywhere_ca[0].cert_pem : null
}

output "rolesanywhere_ca_key_pem" {
  description = "PEM-encoded private key of the Roles Anywhere root CA - load into cert-manager's ClusterIssuer (see manifests/rolesanywhere-ca-issuer.yaml), if enabled. Sensitive: this is the key that can mint certificates AWS will trust."
  value       = var.enable_rolesanywhere ? tls_private_key.rolesanywhere_ca[0].private_key_pem : null
  sensitive   = true
}
