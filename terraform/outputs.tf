output "control_instance_id" {
  value = aws_instance.control.id
}

output "worker_instance_id" {
  value = aws_instance.worker.id
}

output "control_private_ip" {
  value = aws_instance.control.private_ip
}

output "worker_private_ip" {
  value = aws_instance.worker.private_ip
}

output "ssm_bucket_name" {
  value = aws_s3_bucket.ssm_transfer.bucket
}

output "aws_profile" {
  value = var.aws_profile
}

output "aws_region" {
  value = var.aws_region
}

output "cluster_name" {
  value = var.cluster_name
}

output "tunnel_command" {
  description = "Run this (in a separate shell) to reach the Kubernetes API from your laptop."
  value       = "aws ssm start-session --profile ${var.aws_profile} --region ${var.aws_region} --target ${aws_instance.control.id} --document-name AWS-StartPortForwardingSession --parameters '{\"portNumber\":[\"6443\"],\"localPortNumber\":[\"6443\"]}'"
}
