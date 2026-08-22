variable "kubernetes_host" {
  type = string
}

variable "kubernetes_ca_cert" {
  type      = string
  sensitive = true
}

variable "k8s_token_reviewer_jwt" {
  type      = string
  sensitive = true
}

variable "bound_service_account_names" {
  type = list(string)
}

variable "bound_service_account_namespaces" {
  type = list(string)
}

variable "role_name" {
  type = string
}

variable "token_policies" {
  type = list(string)
}
