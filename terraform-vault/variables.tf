variable "vault_addr" {
  description = "Vault server address (http://localhost:8200) - reached over a tunnel the *-vault Make targets manage automatically, or `make tunnel-vault` if running terraform-vault commands by hand."
  type        = string
}

variable "vault_role_id" {
  description = "AppRole role_id for terraform-operator (from local/terraform-operator-*.env, written by `make bootstrap-vault`/`make create-operator-vault`)."
  type        = string
  ephemeral   = true
}

variable "vault_secret_id" {
  description = "AppRole secret_id for terraform-operator (from local/terraform-operator-*.env, written by `make bootstrap-vault`/`make create-operator-vault`)."
  type        = string
  ephemeral   = true
}

variable "kubernetes_host" {
  description = "RKE2 API server address as reachable from the Vault instance itself (control node private IP, not the SSM tunnel) - Vault calls this directly on every Kubernetes auth login."
  type        = string
}

variable "kubernetes_ca_cert" {
  description = "PEM-encoded CA certificate used to validate the RKE2 API server's TLS certificate (extracted from ../kubeconfig)."
  type        = string
  sensitive   = true
}

variable "k8s_token_reviewer_jwt" {
  description = "Token for the vault-auth-delegator ServiceAccount (system:auth-delegator), used by Vault to call the TokenReview API on every Kubernetes auth login. See manifests/vault-k8s-auth.yaml."
  type        = string
  sensitive   = true
}

variable "vault_namespace" {
  description = "Kubernetes namespace of the service account used to verify the Vault-issued AWS credential chain."
  type        = string
  default     = "vault-test"
}

variable "vault_service_account_name" {
  description = "Kubernetes service account name used to verify the Vault-issued AWS credential chain."
  type        = string
  default     = "vault-test"
}

variable "vault_test_role_arn" {
  description = "IAM role ARN Vault's AWS secrets engine assumes on behalf of pods (terraform output vault_test_role_arn from the main terraform/ root)."
  type        = string
}

variable "default_sts_ttl" {
  description = "Default TTL (seconds) for AWS credentials the vault-test role hands out. Defaults short (900s, AWS STS's own floor for AssumeRole) to make rotation testing fast - raise toward 3600 once rotation itself is proven, since 15-minute credentials aren't something you'd want outside testing."
  type        = number
  default     = 900
}
