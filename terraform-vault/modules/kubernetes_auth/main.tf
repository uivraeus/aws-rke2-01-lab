# --- Kubernetes auth method ---
#
# Vault runs on its own EC2 instance, outside the RKE2 cluster, so unlike the common
# "Vault-in-cluster" setup it can't use its own in-cluster ServiceAccount as the
# TokenReview caller. Instead it's handed a standing reviewer JWT
# (k8s_token_reviewer_jwt, bound to the vault-auth-delegator ServiceAccount / the
# system:auth-delegator ClusterRole - see manifests/vault-k8s-auth.yaml) and calls
# kubernetes_host directly on every login to validate the pod's own token.

resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
  path = "kubernetes"
}

resource "vault_kubernetes_auth_backend_config" "this" {
  backend            = vault_auth_backend.kubernetes.path
  kubernetes_host    = var.kubernetes_host
  kubernetes_ca_cert = var.kubernetes_ca_cert
  token_reviewer_jwt = var.k8s_token_reviewer_jwt
}

resource "vault_kubernetes_auth_backend_role" "this" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = var.role_name
  bound_service_account_names      = var.bound_service_account_names
  bound_service_account_namespaces = var.bound_service_account_namespaces
  token_policies                   = var.token_policies
  token_ttl                        = 300
}
