# --- IRSA (IAM Roles for Service Accounts) against this non-EKS RKE2 cluster ---
#
# AWS STS needs to fetch the cluster's OIDC discovery document
# ("/.well-known/openid-configuration") and JWKS ("/keys.json") over the public
# internet to validate tokens presented via IRSA, but this cluster's control plane
# isn't publicly reachable. So this mirrors those documents to a public-but-scoped S3
# location instead and points the cluster's OIDC issuer at that S3 URL - the same
# pattern used by kOps and other self-managed IRSA setups. Ansible
# (roles/rke2_server) configures kube-apiserver with the matching
# --service-account-issuer/--service-account-jwks-uri flags and uploads the live
# discovery doc/JWKS here after each bootstrap/sync run.

resource "random_id" "oidc_bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "oidc" {
  bucket = "${var.cluster_name}-oidc-${random_id.oidc_bucket_suffix.hex}"
  # The OIDC mirror sync (ansible/roles/rke2_server) writes real objects into this
  # bucket on every run, and versioning is enabled below, so a bare `terraform destroy`
  # fails with BucketNotEmpty otherwise.
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  # ACLs are disabled by BucketOwnerEnforced above, so ACL-related blocks are moot;
  # access is granted solely via the bucket policy below, scoped to specific keys.
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_versioning" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_iam_policy_document" "oidc_bucket_public_read" {
  statement {
    sid     = "PublicReadOidcDiscoveryDocuments"
    effect  = "Allow"
    actions = ["s3:GetObject"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    resources = [
      "${aws_s3_bucket.oidc.arn}/*/.well-known/openid-configuration",
      "${aws_s3_bucket.oidc.arn}/*/keys.json",
    ]
  }
}

resource "aws_s3_bucket_policy" "oidc" {
  bucket = aws_s3_bucket.oidc.id
  policy = data.aws_iam_policy_document.oidc_bucket_public_read.json

  depends_on = [aws_s3_bucket_public_access_block.oidc]
}

# --- IAM OIDC identity provider trusting the S3-mirrored discovery documents ---
#
# The issuer URL must exactly match the "issuer" field kube-apiserver is configured
# with (--service-account-issuer) and the path under which the discovery documents
# are mirrored in the bucket above.

locals {
  oidc_issuer_host = "${aws_s3_bucket.oidc.bucket}.s3.${var.aws_region}.amazonaws.com"
  oidc_issuer_url  = "https://${local.oidc_issuer_host}/${var.cluster_name}"
}

# S3 bucket endpoints all present the same AWS-managed certificate chain, but we
# derive the thumbprint from the live endpoint rather than hardcoding it so it can't
# silently go stale if AWS rotates the signing chain.
data "tls_certificate" "oidc_issuer" {
  url = "https://${local.oidc_issuer_host}"
}

resource "aws_iam_openid_connect_provider" "cluster" {
  url             = local.oidc_issuer_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc_issuer.certificates[length(data.tls_certificate.oidc_issuer.certificates) - 1].sha1_fingerprint]
}

# --- IAM role assumable via IRSA by the verification service account ---
#
# Scoped to only the test bucket below, for the verification ServiceAccount
# (var.irsa_namespace/var.irsa_service_account_name) on this cluster.

data "aws_iam_policy_document" "irsa_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}/${var.cluster_name}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}/${var.cluster_name}:sub"
      values   = ["system:serviceaccount:${var.irsa_namespace}:${var.irsa_service_account_name}"]
    }
  }
}

resource "aws_iam_role" "irsa_test" {
  name               = "${var.cluster_name}-irsa-test"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust.json
}

# --- Test bucket used purely to prove the IRSA chain works end to end ---

resource "random_id" "irsa_test_bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "irsa_test" {
  bucket = "${var.cluster_name}-irsa-test-${random_id.irsa_test_bucket_suffix.hex}"
  # The IRSA verification pod writes real objects into this bucket, so a bare
  # `terraform destroy` fails with BucketNotEmpty otherwise.
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "irsa_test" {
  bucket = aws_s3_bucket.irsa_test.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "irsa_test" {
  bucket = aws_s3_bucket.irsa_test.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "irsa_test" {
  bucket = aws_s3_bucket.irsa_test.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_iam_policy_document" "irsa_test_bucket_access" {
  statement {
    sid     = "ListIrsaTestBucket"
    effect  = "Allow"
    actions = ["s3:ListBucket"]
    resources = [
      aws_s3_bucket.irsa_test.arn,
    ]
  }

  statement {
    sid     = "ReadWriteIrsaTestBucketObjects"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "${aws_s3_bucket.irsa_test.arn}/*",
    ]
  }
}

resource "aws_iam_policy" "irsa_test_bucket_access" {
  name   = "${var.cluster_name}-irsa-test-bucket-access"
  policy = data.aws_iam_policy_document.irsa_test_bucket_access.json
}

resource "aws_iam_role_policy_attachment" "irsa_test_bucket_access" {
  role       = aws_iam_role.irsa_test.name
  policy_arn = aws_iam_policy.irsa_test_bucket_access.arn
}
