output "cluster_name" { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "region" { value = var.region }
output "reports_bucket" { value = aws_s3_bucket.reports.bucket }
output "argo_workflows_role_arn" { value = module.irsa_argo_workflows.iam_role_arn }
output "external_secrets_role_arn" { value = module.irsa_external_secrets.iam_role_arn }
output "deployer_role_arn" { value = module.irsa_deployer.iam_role_arn }
output "secret_dtrack" { value = aws_secretsmanager_secret.dtrack.name }
output "secret_git" { value = aws_secretsmanager_secret.git.name }
output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
