# --- AWS secrets engine ---
#
# Deliberately no access_key/secret_key here - the plugin falls back to the AWS SDK's
# default credential chain, which resolves to the Vault EC2 instance's own IAM
# instance profile via IMDS (terraform/vault.tf: aws_iam_role.vault_instance). That's
# the only AWS credential Vault itself ever holds, and it's never a static key.

resource "vault_aws_secret_backend" "this" {
  path = "aws"
}

resource "vault_aws_secret_backend_role" "this" {
  backend         = vault_aws_secret_backend.this.path
  name            = var.role_name
  credential_type = "assumed_role"
  role_arns       = var.role_arns
  default_sts_ttl = var.default_sts_ttl
}
