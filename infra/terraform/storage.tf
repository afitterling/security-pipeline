resource "random_id" "suffix" {
  byte_length = 3
}

# Scan reports (SBOMs, trivy/semgrep/gitleaks JSON, logs) archived per project per run
resource "aws_s3_bucket" "reports" {
  bucket        = "${local.name}-reports-${random_id.suffix.hex}"
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket                  = aws_s3_bucket.reports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "reports" {
  bucket = aws_s3_bucket.reports.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id
  rule {
    id     = "expire-reports"
    status = "Enabled"
    filter {}
    expiration { days = var.reports_retention_days }
    noncurrent_version_expiration { noncurrent_days = 30 }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}

# ---------- Secrets Manager placeholders (values are set out-of-band, never in TF) ----------
# security-pipeline/dependency-track : {"apiKey": "..."}         <- scripts/dtrack-bootstrap.sh
# security-pipeline/git              : {"username": "...", "token": "..."}  <- you
resource "aws_secretsmanager_secret" "dtrack" {
  name                    = "${local.name}/dependency-track"
  description             = "Dependency-Track API key used by scan workflows (BOM upload)"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret" "git" {
  name                    = "${local.name}/git"
  description             = "Read-only git credentials used to clone scanned repositories"
  recovery_window_in_days = 7
}

# Seed empty-but-valid JSON so ExternalSecrets resolve before real values exist
resource "aws_secretsmanager_secret_version" "git_seed" {
  secret_id     = aws_secretsmanager_secret.git.id
  secret_string = jsonencode({ username = "git", token = "" })
  lifecycle { ignore_changes = [secret_string] }
}

resource "aws_secretsmanager_secret_version" "dtrack_seed" {
  secret_id     = aws_secretsmanager_secret.dtrack.id
  secret_string = jsonencode({ apiKey = "" })
  lifecycle { ignore_changes = [secret_string] }
}
