# Permissions for the terraform-operator AppRole used by Terraform (terraform-vault/)
# to manage ongoing Vault configuration: the Kubernetes auth method and the AWS
# secrets engine.

path "sys/auth/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "sys/auth" {
  capabilities = ["read"]
}

path "sys/mounts/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "sys/mounts" {
  capabilities = ["read"]
}

path "auth/kubernetes/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "aws/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "sys/policies/acl" {
  capabilities = ["list"]
}

# Used by the Vault Terraform provider to check its own capabilities on startup
path "sys/capabilities-self" {
  capabilities = ["update"]
}

# Required for the Vault Terraform provider to create a short-lived child token
# per run. Vault prevents privilege escalation: child tokens cannot receive
# policies the creator does not already hold.
path "auth/token/create" {
  capabilities = ["update"]
}
