output "backend_path" {
  value = vault_aws_secret_backend.this.path
}

output "role_name" {
  value = vault_aws_secret_backend_role.this.name
}

output "creds_path" {
  value = "${vault_aws_secret_backend.this.path}/creds/${vault_aws_secret_backend_role.this.name}"
}
