module "kubernetes_auth" {
  source = "./modules/kubernetes_auth"

  kubernetes_host                  = var.kubernetes_host
  kubernetes_ca_cert               = var.kubernetes_ca_cert
  k8s_token_reviewer_jwt           = var.k8s_token_reviewer_jwt
  bound_service_account_names      = [var.vault_service_account_name]
  bound_service_account_namespaces = [var.vault_namespace]
  role_name                        = "vault-test"
  token_policies                   = [vault_policy.vault_test_aws.name]
}

module "aws" {
  source = "./modules/aws"

  role_name       = "vault-test"
  role_arns       = [var.vault_test_role_arn]
  default_sts_ttl = var.default_sts_ttl
}

# Grants exactly what the test pod's initContainer needs: read the AWS credentials
# the "vault-test" role hands out, nothing else.
resource "vault_policy" "vault_test_aws" {
  name   = "vault-test-aws"
  policy = <<-EOT
    path "${module.aws.creds_path}" {
      capabilities = ["read"]
    }
  EOT
}
