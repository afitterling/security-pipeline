variable "name" {
  description = "Base name for every resource"
  type        = string
  default     = "security-pipeline"
}

variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "aws_profile" {
  description = "AWS CLI profile (empty = default credential chain)"
  type        = string
  default     = ""
}

variable "cluster_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.35"
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the EKS API. Keep this tight."
  type        = list(string)
}

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.xlarge"]
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "git_repo_url" {
  description = "HTTPS URL of this repository (Argo CD source)"
  type        = string
}

variable "git_revision" {
  type    = string
  default = "main"
}

variable "git_username" {
  description = "Username for the Argo CD repo credential (only for private repos)"
  type        = string
  default     = "git"
}

variable "git_token" {
  description = "Token for the Argo CD repo credential. Leave empty for a public repo. Pass via TF_VAR_git_token."
  type        = string
  default     = ""
  sensitive   = true
}

variable "argocd_chart_version" {
  description = "argo-cd helm chart version (argoproj.github.io/argo-helm)"
  type        = string
  default     = "10.8.3"
}

variable "reports_retention_days" {
  description = "Days to keep scan reports in S3"
  type        = number
  default     = 180
}

variable "tags" {
  type = map(string)
  default = {
    Project   = "security-pipeline"
    ManagedBy = "terraform"
  }
}
