# --- AWS Roles Anywhere, evaluated as a third (independent) path for pods to get scoped
# AWS credentials, alongside IRSA (irsa.tf) and Vault (vault.tf). Unlike those two, Roles
# Anywhere authenticates callers via X.509 client certificates against a registered CA
# ("Trust Anchor"), not a Kubernetes-native token - so cert-manager (already installed via
# `make cert-manager` for the IRSA webhook) is the bridge that hands pods an X.509 identity
# in the first place. See docs/rolesanywhere.md for the full write-up, including the
# workload-id:// URI SAN convention used to map a certificate to an IAM role.
#
# Entirely optional - gated behind var.enable_rolesanywhere (default false), matching
# enable_vault's pattern. Every resource below is count-gated on it rather than living in a
# submodule, matching this root's existing flat style (see irsa.tf/vault.tf).

# --- Self-signed root CA, registered directly with AWS as the Trust Anchor's certificate
# bundle. The same cert+key pair is also handed to cert-manager (via
# manifests/rolesanywhere-ca-issuer.yaml, applied separately - see that file) so it can sign
# leaf certificates that AWS will actually trust. A self-signed CA (free) is used instead of
# AWS Private CA (~$400/mo minimum) - wildly disproportionate for a throwaway lab, matching
# this repo's existing cost-consciousness (see Vault's tls_disable = 1).

resource "tls_private_key" "rolesanywhere_ca" {
  count = var.enable_rolesanywhere ? 1 : 0

  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "rolesanywhere_ca" {
  count = var.enable_rolesanywhere ? 1 : 0

  private_key_pem = tls_private_key.rolesanywhere_ca[0].private_key_pem

  subject {
    common_name  = "${var.cluster_name} Roles Anywhere root CA"
    organization = var.cluster_name
  }

  validity_period_hours = 24 * 365 * 10 # 10 years - a lab root CA, not a production one
  is_ca_certificate     = true

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "key_encipherment",
    "digital_signature",
  ]
}

resource "aws_rolesanywhere_trust_anchor" "cluster" {
  count = var.enable_rolesanywhere ? 1 : 0

  name    = "${var.cluster_name}-rolesanywhere"
  enabled = true

  source {
    source_type = "CERTIFICATE_BUNDLE"

    source_data {
      x509_certificate_data = tls_self_signed_cert.rolesanywhere_ca[0].cert_pem
    }
  }
}

# --- Roles Anywhere profile: the set of role(s) a session created against this Trust Anchor
# may assume. duration_seconds is kept short (AWS's own 900s floor) so cert-manager's
# rotation of the leaf certificate is observable quickly when evaluating that path - raise it
# back toward AWS's own default (3600s) once done evaluating rotation itself.

resource "aws_rolesanywhere_profile" "cluster" {
  count = var.enable_rolesanywhere ? 1 : 0

  name    = "${var.cluster_name}-rolesanywhere"
  enabled = true

  role_arns        = [aws_iam_role.rolesanywhere_test[0].arn]
  duration_seconds = var.rolesanywhere_sts_duration_seconds
}

# --- IAM role assumable via Roles Anywhere by the verification workload ---
#
# Scoped to only the test bucket below, for one specific workload identity - see
# docs/rolesanywhere.md for the workload-id:// URI SAN convention this condition matches
# against (the Roles Anywhere analog of IRSA's `sub` claim condition in irsa.tf).

locals {
  rolesanywhere_test_workload_uri = "workload-id://${var.cluster_name}.internal/ns/${var.rolesanywhere_namespace}/sa/${var.rolesanywhere_service_account_name}"
}

data "aws_iam_policy_document" "rolesanywhere_test_trust" {
  count = var.enable_rolesanywhere ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["rolesanywhere.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_rolesanywhere_trust_anchor.cluster[0].arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/x509SAN/URI"
      values   = [local.rolesanywhere_test_workload_uri]
    }
  }
}

resource "aws_iam_role" "rolesanywhere_test" {
  count = var.enable_rolesanywhere ? 1 : 0

  name               = "${var.cluster_name}-rolesanywhere-test"
  assume_role_policy = data.aws_iam_policy_document.rolesanywhere_test_trust[0].json
}

# --- Test bucket used purely to prove the Roles Anywhere credential chain works end to end ---

resource "random_id" "rolesanywhere_test_bucket_suffix" {
  count = var.enable_rolesanywhere ? 1 : 0

  byte_length = 4
}

resource "aws_s3_bucket" "rolesanywhere_test" {
  count = var.enable_rolesanywhere ? 1 : 0

  bucket        = "${var.cluster_name}-rolesanywhere-test-${random_id.rolesanywhere_test_bucket_suffix[0].hex}"
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "rolesanywhere_test" {
  count = var.enable_rolesanywhere ? 1 : 0

  bucket = aws_s3_bucket.rolesanywhere_test[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "rolesanywhere_test" {
  count = var.enable_rolesanywhere ? 1 : 0

  bucket = aws_s3_bucket.rolesanywhere_test[0].id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "rolesanywhere_test" {
  count = var.enable_rolesanywhere ? 1 : 0

  bucket = aws_s3_bucket.rolesanywhere_test[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_iam_policy_document" "rolesanywhere_test_bucket_access" {
  count = var.enable_rolesanywhere ? 1 : 0

  statement {
    sid       = "ListRolesAnywhereTestBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.rolesanywhere_test[0].arn]
  }

  statement {
    sid       = "ReadWriteRolesAnywhereTestBucketObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.rolesanywhere_test[0].arn}/*"]
  }
}

resource "aws_iam_policy" "rolesanywhere_test_bucket_access" {
  count = var.enable_rolesanywhere ? 1 : 0

  name   = "${var.cluster_name}-rolesanywhere-test-bucket-access"
  policy = data.aws_iam_policy_document.rolesanywhere_test_bucket_access[0].json
}

resource "aws_iam_role_policy_attachment" "rolesanywhere_test_bucket_access" {
  count = var.enable_rolesanywhere ? 1 : 0

  role       = aws_iam_role.rolesanywhere_test[0].name
  policy_arn = aws_iam_policy.rolesanywhere_test_bucket_access[0].arn
}
