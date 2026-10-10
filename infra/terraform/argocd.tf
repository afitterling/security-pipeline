resource "kubernetes_namespace" "argocd" {
  metadata { name = "argocd" }
  depends_on = [module.eks]
}

resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  wait       = true
  timeout    = 600

  values = [yamlencode({
    global = { domain = "argocd.local" }
    configs = {
      params = {
        "server.insecure" = true # TLS terminated by port-forward/ingress, not the pod
      }
      cm = {
        "timeout.reconciliation"                                 = "180s"
        "resource.customizations.health.argoproj.io_Application" = <<-LUA
          hs = {}
          hs.status = "Progressing"
          hs.message = ""
          if obj.status ~= nil then
            if obj.status.health ~= nil then
              hs.status = obj.status.health.status
              if obj.status.health.message ~= nil then
                hs.message = obj.status.health.message
              end
            end
          end
          return hs
        LUA
      }
    }
    server        = { resources = { requests = { cpu = "100m", memory = "256Mi" } } }
    controller    = { resources = { requests = { cpu = "250m", memory = "512Mi" } } }
    repoServer    = { resources = { requests = { cpu = "100m", memory = "256Mi" } } }
    dex           = { enabled = false }
    notifications = { enabled = true }
  })]
}

# Repo credential for a private repo (label makes Argo CD pick it up)
resource "kubernetes_secret" "repo_creds" {
  count = var.git_token != "" ? 1 : 0

  metadata {
    name      = "repo-security-pipeline"
    namespace = kubernetes_namespace.argocd.metadata[0].name
    labels    = { "argocd.argoproj.io/secret-type" = "repository" }
  }
  data = {
    type     = "git"
    url      = var.git_repo_url
    username = var.git_username
    password = var.git_token
  }
  depends_on = [helm_release.argocd]
}

# Root application (app-of-apps). Everything else is GitOps from here on.
resource "helm_release" "root_app" {
  name      = "security-pipeline-root"
  namespace = kubernetes_namespace.argocd.metadata[0].name
  chart     = "${path.module}/../../argocd/bootstrap"

  values = [yamlencode({
    repoURL        = var.git_repo_url
    targetRevision = var.git_revision
    aws = {
      region        = var.region
      reportsBucket = aws_s3_bucket.reports.bucket
      roles = {
        argoWorkflows   = module.irsa_argo_workflows.iam_role_arn
        externalSecrets = module.irsa_external_secrets.iam_role_arn
        deployer        = module.irsa_deployer.iam_role_arn
      }
    }
  })]

  depends_on = [helm_release.argocd, kubernetes_secret.repo_creds, kubernetes_storage_class.gp3]
}
