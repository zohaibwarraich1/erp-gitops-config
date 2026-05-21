# IAM Policy for External Secrets to read AWS Secrets Manager
resource "aws_iam_policy" "external_secrets" {
  name        = "${var.cluster_name}-external-secrets-policy"
  description = "Allow External Secrets Operator to read secrets from AWS Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        # Restrict it to the erp namespace secrets for better security (Phase 5 Hardening)
        Resource = "arn:aws:secretsmanager:${var.aws_region}:*:secret:erp/*"
      }
    ]
  })
}

# EKS IRSA (IAM Role for Service Accounts) Module
# Links the EKS Service Account to the AWS IAM Role
module "external_secrets_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-external-secrets-role"

  role_policy_arns = {
    external_secrets = aws_iam_policy.external_secrets.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
}
