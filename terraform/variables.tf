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
