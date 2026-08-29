variable "aws_profile" {
  description = "AWS SSO profile to use (run `aws sso login --profile <name>` first)."
  type        = string
}

variable "aws_region" {
  description = "AWS region to deploy the lab cluster into."
  type        = string
}

variable "cluster_name" {
  description = "Short name used to tag/name all resources for this lab cluster."
  type        = string
  default     = "rke2-lab"
}

variable "control_instance_type" {
  description = "Instance type for the RKE2 control (server) node."
  type        = string
  default     = "t3.medium"
}

variable "worker_instance_type" {
  description = "Instance type for the RKE2 worker (agent) node."
  type        = string
  default     = "t3.medium"
}

variable "enable_vault" {
  description = "Provision the standalone Vault instance and its wiring (see vault.tf) - an independent, optional evaluation alongside IRSA. Defaults to off. If you turn this off after having turned it on, destroy terraform-vault's resources first (`make destroy-vault`/`make destroy-all`), otherwise that root's state is left pointing at a Vault server this apply just removed."
  type        = bool
  default     = false
}

variable "vault_instance_type" {
  description = "Instance type for the standalone Vault instance (only used if enable_vault = true)."
  type        = string
  default     = "t3.small"
}

variable "root_volume_size" {
  description = "Root EBS volume size (GiB) for each node."
  type        = number
  default     = 20
}

variable "irsa_namespace" {
  description = "Kubernetes namespace of the service account used to verify IRSA."
  type        = string
  default     = "irsa-test"
}

variable "irsa_service_account_name" {
  description = "Kubernetes service account name used to verify IRSA."
  type        = string
  default     = "irsa-test"
}

variable "enable_rolesanywhere" {
  description = "Provision the AWS Roles Anywhere trust anchor/profile/test role and its wiring (see rolesanywhere.tf) - an independent, optional evaluation alongside IRSA and Vault. Defaults to off."
  type        = bool
  default     = false
}

variable "rolesanywhere_namespace" {
  description = "Kubernetes namespace of the service account used to verify Roles Anywhere."
  type        = string
  default     = "rolesanywhere-test"
}

variable "rolesanywhere_service_account_name" {
  description = "Kubernetes service account name used to verify Roles Anywhere."
  type        = string
  default     = "rolesanywhere-test"
}

variable "rolesanywhere_sts_duration_seconds" {
  description = "Session duration for credentials issued via the Roles Anywhere profile. Kept at AWS's own 900s floor by default so cert-manager's rotation of the leaf certificate is observable quickly - raise it back toward AWS's own default (3600) once done evaluating rotation itself."
  type        = number
  default     = 900
}
