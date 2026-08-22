variable "role_name" {
  type = string
}

variable "role_arns" {
  type = list(string)
}

variable "default_sts_ttl" {
  description = "Default TTL (seconds) for assumed-role credentials this role hands out. AWS STS enforces a hard floor of 900 (15 min) on AssumeRole's DurationSeconds regardless of this value."
  type        = number
  default     = 3600
}
