output "backend_path" {
  value = vault_auth_backend.kubernetes.path
}

output "role_name" {
  value = vault_kubernetes_auth_backend_role.this.role_name
}
