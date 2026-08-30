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

# --- TEMPORARY WORKAROUND: aws_rolesanywhere_profile has no attribute_mappings argument in
# hashicorp/terraform-provider-aws (confirmed from the provider's own source -
# internal/service/rolesanywhere/ only implements profile.go and trust_anchor.go, no
# attribute-mapping resource at all), even though the underlying AWS API and
# CloudFormation's own AWS::RolesAnywhere::Profile both support it - awscc_rolesanywhere_profile
# (the CloudFormation-Cloud-Control-API-generated provider) already has it natively. Without
# this, every Roles Anywhere session fails with a generic AccessDeniedException regardless
# of how correct the trust policy's condition is - the certificate's SAN is never turned
# into a principal tag for that condition to match against (see docs/rolesanywhere.md).
#
# Tracked upstream: https://github.com/hashicorp/terraform-provider-aws/issues/48211 - an
# implementation already exists (https://github.com/hashicorp/terraform-provider-aws/pull/48493),
# stuck only on a maintainer running acceptance tests (the author has no AWS account with
# Roles Anywhere access). Delete this resource and switch to a plain attribute_mappings
# argument on aws_rolesanywhere_profile once that ships in a release.
#
# terraform_data (not a provisioner attached directly to aws_rolesanywhere_profile) so the
# mapping values themselves are real triggers, not just the profile's id - otherwise this
# would only ever run once, at creation, exactly like a provisioner on the resource itself
# (nothing in aws_rolesanywhere_profile's own schema represents "the attribute mapping", so
# Terraform has no other way to know a change here matters). Deliberately NOT triggered on
# every apply (e.g. a random/timestamp trigger) either - that would make every `terraform
# apply` show a diff even when nothing changed. The real limitation this doesn't solve: a
# local-exec provisioner has no read step, so this can't detect or repair drift if the
# mapping is changed or removed outside Terraform - acceptable for a workaround with a known
# removal path, not acceptable as a permanent design.

locals {
  rolesanywhere_attribute_mapping_field     = "x509SAN"
  rolesanywhere_attribute_mapping_specifier = "URI"
}

resource "terraform_data" "rolesanywhere_test_attribute_mapping" {
  count = var.enable_rolesanywhere ? 1 : 0

  triggers_replace = [
    aws_rolesanywhere_profile.cluster[0].id,
    local.rolesanywhere_attribute_mapping_field,
    local.rolesanywhere_attribute_mapping_specifier,
  ]

  provisioner "local-exec" {
    # --profile here is the AWS CLI's SSO profile (var.aws_profile) - unrelated to, and not
    # to be confused with, the Roles Anywhere "profile" (--profile-id) this command targets.
    command = join(" ", [
      "aws rolesanywhere put-attribute-mapping",
      "--region ${var.aws_region}",
      "--profile ${var.aws_profile}",
      "--profile-id ${aws_rolesanywhere_profile.cluster[0].id}",
      "--certificate-field ${local.rolesanywhere_attribute_mapping_field}",
      "--mapping-rules specifier=${local.rolesanywhere_attribute_mapping_specifier}",
    ])
  }
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
    effect = "Allow"
    # sts:SetSourceIdentity is not optional in practice: every Roles Anywhere session sets a
    # source identity from the certificate's Subject CN (confirmed live - omitting this
    # action from the trust policy makes AssumeRole fail with a generic "Unable to assume
    # role" for every request, not a source-identity-specific error, which makes it easy to
    # miss).
    actions = ["sts:AssumeRole", "sts:TagSession", "sts:SetSourceIdentity"]

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
