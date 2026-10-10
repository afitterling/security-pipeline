# ---------- EBS CSI ----------
module "irsa_ebs_csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.52"

  role_name             = "${local.name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

# ---------- Argo Workflows: S3 artifact repository ----------
data "aws_iam_policy_document" "reports" {
  statement {
    sid       = "ListBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.reports.arn]
  }
  statement {
    sid       = "ObjectRW"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
    resources = ["${aws_s3_bucket.reports.arn}/*"]
  }
}

resource "aws_iam_policy" "reports" {
  name   = "${local.name}-reports-s3"
  policy = data.aws_iam_policy_document.reports.json
}

module "irsa_argo_workflows" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.52"

  role_name        = "${local.name}-argo-workflows"
  role_policy_arns = { s3 = aws_iam_policy.reports.arn }

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      namespace_service_accounts = [
        "argo:argo-workflows-controller",
        "argo:argo-workflows-server",
        "security:security-scan",
      ]
    }
  }
}

# ---------- Deployer: identity for `npx sst deploy` inside the pipeline ----------
# SST/Pulumi needs wide service permissions. PowerUserAccess + scoped IAM role management,
# with explicit denies that keep it away from this pipeline's own roles, users and the cluster.
data "aws_iam_policy_document" "deployer" {
  statement {
    sid = "IamForSstRoles"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole", "iam:TagRole", "iam:UntagRole",
      "iam:PassRole", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:UpdateAssumeRolePolicy",
      "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy", "iam:GetPolicyVersion",
      "iam:CreatePolicyVersion", "iam:DeletePolicyVersion", "iam:ListPolicyVersions",
      "iam:CreateServiceLinkedRole", "iam:GetOpenIDConnectProvider",
    ]
    resources = ["*"]
  }
  statement {
    sid     = "ProtectPipelineAndUsers"
    effect  = "Deny"
    actions = ["iam:*"]
    resources = [
      "arn:aws:iam::${local.account_id}:role/${local.name}-*",
      "arn:aws:iam::${local.account_id}:user/*",
    ]
  }
  statement {
    sid       = "NoUserCredentials"
    effect    = "Deny"
    actions   = ["iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile", "eks:*", "organizations:*", "account:*"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "deployer" {
  name   = "${local.name}-deployer"
  policy = data.aws_iam_policy_document.deployer.json
}

module "irsa_deployer" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.52"

  role_name = "${local.name}-deployer"
  role_policy_arns = {
    poweruser = "arn:aws:iam::aws:policy/PowerUserAccess"
    iam       = aws_iam_policy.deployer.arn
  }
  max_session_duration = 3600

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["security:security-deploy"]
    }
  }
}

# ---------- External Secrets: read security-pipeline/* in Secrets Manager ----------
data "aws_iam_policy_document" "external_secrets" {
  statement {
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecretVersionIds",
    ]
    resources = ["arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:${local.name}/*"]
  }
}

resource "aws_iam_policy" "external_secrets" {
  name   = "${local.name}-external-secrets"
  policy = data.aws_iam_policy_document.external_secrets.json
}

module "irsa_external_secrets" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.52"

  role_name        = "${local.name}-external-secrets"
  role_policy_arns = { sm = aws_iam_policy.external_secrets.arn }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
}
