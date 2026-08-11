locals {
  subnet_id = data.aws_subnets.default.ids[0]
}

# --- S3 bucket used as the transfer channel for Ansible's aws_ssm connection plugin ---

resource "aws_s3_bucket" "ssm_transfer" {
  bucket        = "${var.cluster_name}-ssm-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "ssm_transfer" {
  bucket                  = aws_s3_bucket.ssm_transfer.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- IAM role for the EC2 instances: SSM check-in + access to the transfer bucket ---

resource "aws_iam_role" "instance" {
  name = "${var.cluster_name}-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "ssm_transfer_bucket" {
  name = "ssm-transfer-bucket-access"
  role = aws_iam_role.instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetEncryptionConfiguration"]
        Resource = aws_s3_bucket.ssm_transfer.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.ssm_transfer.arn}/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.cluster_name}-instance-profile"
  role = aws_iam_role.instance.name
}

# --- Security group: no ingress from the internet, only cluster-internal traffic ---

resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-cluster"
  description = "RKE2 lab cluster - node-to-node traffic only, no internet ingress"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "cluster_internal" {
  type              = "ingress"
  description       = "all traffic between cluster nodes"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.cluster.id
  self              = true
}

# --- Nodes ---

resource "aws_instance" "control" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.control_instance_type
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.cluster.id]
  iam_instance_profile        = aws_iam_instance_profile.instance.name
  associate_public_ip_address = true

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
  }

  tags = {
    Name = "${var.cluster_name}-control"
    Role = "control"
  }
}

resource "aws_instance" "worker" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.worker_instance_type
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.cluster.id]
  iam_instance_profile        = aws_iam_instance_profile.instance.name
  associate_public_ip_address = true

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
  }

  tags = {
    Name = "${var.cluster_name}-worker"
    Role = "worker"
  }
}

# --- Hand the values Ansible needs off to it, without a manual copy/paste step ---

resource "local_file" "ansible_terraform_vars" {
  filename = "${path.module}/../ansible/group_vars/all/terraform.yml"

  content = yamlencode({
    aws_profile         = var.aws_profile
    aws_region          = var.aws_region
    cluster_name        = var.cluster_name
    ssm_bucket_name     = aws_s3_bucket.ssm_transfer.bucket
    control_instance_id = aws_instance.control.id
    control_private_ip  = aws_instance.control.private_ip
    oidc_bucket_name    = aws_s3_bucket.oidc.bucket
    oidc_issuer_url     = local.oidc_issuer_url
    oidc_jwks_uri       = "${local.oidc_issuer_url}/keys.json"
  })
}
