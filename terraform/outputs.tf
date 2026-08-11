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
