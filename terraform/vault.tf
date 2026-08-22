# --- Dedicated Vault instance, evaluated as a second (independent) path for pods to
# get scoped AWS credentials, alongside the IRSA setup in irsa.tf. Ansible installs and
# bootstraps Vault itself (ansible/roles/vault_*); this file only provisions what Vault
# needs from AWS: its own EC2 instance/IAM role, network access to/from the cluster, and
# the IAM role its AWS secrets engine will assume on behalf of pods.
#
# Entirely optional - gated behind var.enable_vault (default false) since the Vault
# evaluation is independent of the base cluster/IRSA. Every resource below is
# count-gated on it rather than living in a submodule, matching this root's existing
# flat style (see irsa.tf). If you toggle this from true back to false, destroy
# terraform-vault's resources first (`make destroy-vault`, or just `make destroy-all`) -
# otherwise its state is left pointing at a Vault server this apply just removed.

# --- IAM role for the Vault EC2 instance: SSM check-in + sts:AssumeRole on whatever
# target role(s) the AWS secrets engine is configured to hand out ---

resource "aws_iam_role" "vault_instance" {
  count = var.enable_vault ? 1 : 0

  name = "${var.cluster_name}-vault-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "vault_ssm_core" {
  count = var.enable_vault ? 1 : 0

  role       = aws_iam_role.vault_instance[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Vault's AWS secrets engine is deliberately configured (terraform-vault/modules/aws)
# without a static access key/secret - it falls back to the AWS SDK's default
# credential chain, which resolves to this instance's own IAM role via IMDS. That's
# the only AWS credential Vault itself ever holds, so this is the one place the
# blast radius of "what can Vault's AWS secrets engine actually assume" is defined.
resource "aws_iam_role_policy" "vault_instance_assume_targets" {
  count = var.enable_vault ? 1 : 0

  name = "assume-vault-managed-roles"
  role = aws_iam_role.vault_instance[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = [aws_iam_role.vault_test[0].arn]
    }]
  })
}

resource "aws_iam_instance_profile" "vault" {
  count = var.enable_vault ? 1 : 0

  name = "${var.cluster_name}-vault-instance-profile"
  role = aws_iam_role.vault_instance[0].name
}

# --- Security group: Vault reachable from cluster nodes on 8200, no internet ingress ---

resource "aws_security_group" "vault" {
  count = var.enable_vault ? 1 : 0

  name        = "${var.cluster_name}-vault"
  description = "RKE2 lab Vault instance - reachable only from the cluster, no internet ingress"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "vault_from_cluster" {
  count = var.enable_vault ? 1 : 0

  type                     = "ingress"
  description              = "Vault API, reachable from cluster nodes (pod traffic is masqueraded to the node ENI IP for anything leaving the pod CIDR, so this matches at the SG boundary)"
  from_port                = 8200
  to_port                  = 8200
  protocol                 = "tcp"
  security_group_id        = aws_security_group.vault[0].id
  source_security_group_id = aws_security_group.cluster.id
}

# Vault's Kubernetes auth method calls back into kube-apiserver (TokenReview) on every
# login, so the cluster security group needs to let the Vault instance reach it - the
# existing `cluster_internal` rule only covers traffic between cluster members.
resource "aws_security_group_rule" "apiserver_from_vault" {
  count = var.enable_vault ? 1 : 0

  type                     = "ingress"
  description              = "kube-apiserver, reachable from Vault (Kubernetes auth method TokenReview calls)"
  from_port                = 6443
  to_port                  = 6443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.cluster.id
  source_security_group_id = aws_security_group.vault[0].id
}

# --- The Vault instance itself ---

resource "aws_instance" "vault" {
  count = var.enable_vault ? 1 : 0

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.vault_instance_type
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.vault[0].id]
  iam_instance_profile        = aws_iam_instance_profile.vault[0].name
  associate_public_ip_address = true

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
  }

  tags = {
    Name = "${var.cluster_name}-vault"
    Role = "vault"
  }
}

# --- IAM role Vault's AWS secrets engine hands out to pods (via assumed_role) ---
#
# Trusts the Vault instance's own role directly - a plain sts:AssumeRole, not
# AssumeRoleWithWebIdentity/Federated. Vault itself is the caller here (using its
# instance-profile credentials), so unlike IRSA this never needs AWS STS to fetch an
# OIDC discovery document at all.

data "aws_iam_policy_document" "vault_test_trust" {
  count = var.enable_vault ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.vault_instance[0].arn]
    }
  }
}

resource "aws_iam_role" "vault_test" {
  count = var.enable_vault ? 1 : 0

  name               = "${var.cluster_name}-vault-test"
  assume_role_policy = data.aws_iam_policy_document.vault_test_trust[0].json
}

# --- Test bucket used purely to prove the Vault-issued credential chain works end to end ---

resource "random_id" "vault_test_bucket_suffix" {
  count = var.enable_vault ? 1 : 0

  byte_length = 4
}

resource "aws_s3_bucket" "vault_test" {
  count = var.enable_vault ? 1 : 0

  bucket        = "${var.cluster_name}-vault-test-${random_id.vault_test_bucket_suffix[0].hex}"
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "vault_test" {
  count = var.enable_vault ? 1 : 0

  bucket = aws_s3_bucket.vault_test[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "vault_test" {
  count = var.enable_vault ? 1 : 0

  bucket = aws_s3_bucket.vault_test[0].id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "vault_test" {
  count = var.enable_vault ? 1 : 0

  bucket = aws_s3_bucket.vault_test[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_iam_policy_document" "vault_test_bucket_access" {
  count = var.enable_vault ? 1 : 0

  statement {
    sid       = "ListVaultTestBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.vault_test[0].arn]
  }

  statement {
    sid       = "ReadWriteVaultTestBucketObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.vault_test[0].arn}/*"]
  }
}

resource "aws_iam_policy" "vault_test_bucket_access" {
  count = var.enable_vault ? 1 : 0

  name   = "${var.cluster_name}-vault-test-bucket-access"
  policy = data.aws_iam_policy_document.vault_test_bucket_access[0].json
}

resource "aws_iam_role_policy_attachment" "vault_test_bucket_access" {
  count = var.enable_vault ? 1 : 0

  role       = aws_iam_role.vault_test[0].name
  policy_arn = aws_iam_policy.vault_test_bucket_access[0].arn
}
