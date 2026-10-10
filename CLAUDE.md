# CLAUDE.md

GitOps security-scanning pipeline on AWS. Terraform builds an EKS cluster with Argo CD; Argo CD
syncs this repo (app-of-apps) and installs Argo Workflows, Dependency-Track, External Secrets and
the `security-scans` chart. That chart turns `projects.yaml` into one CronWorkflow per repo
(clone → detect → build/test ‖ syft SBOM → Dependency-Track ‖ trivy ‖ gitleaks ‖ semgrep →
severity gate → deploy (e.g. `npx sst deploy --stage <stage>`) → reports to S3).

Detection lives in `charts/security-scans/files/detect.js` (mounted as a ConfigMap). It writes
`plan.json`; precedence: auto-detect < `.security-pipeline.json` in the repo < `commands:` in
`projects.yaml`. The deploy step runs under the `security-deploy` SA → `security-pipeline-deployer`
IAM role (iam.tf). Scanners use `security-scan` → S3-only role. Keep that split.

## Layout
- `projects.yaml` — the only file you edit to add/remove repos. Source of truth.
- `infra/terraform/` — VPC, EKS (managed node group), IRSA roles, S3 reports bucket, Secrets
  Manager placeholders, Argo CD helm release + root Application. State backend: `backend.hcl`
  (gitignored, see `backend.hcl.example`).
- `argocd/bootstrap/` — helm chart rendering the root app's children (`Application` objects).
  Terraform passes it the IRSA ARNs, bucket, region and repo URL. Sync waves: ESO (0) →
  Argo Workflows + Dependency-Track (1) → security-scans (2).
- `charts/security-scans/` — WorkflowTemplate `security-scan`, one CronWorkflow per project,
  ExternalSecrets (`dtrack-api`, `git-credentials`), ClusterSecretStore, RBAC.
- `policies/gatekeeper/` — ConstraintTemplates (`templates/`, wave 0) and Constraints
  (`constraints/`, wave 1) synced by the `gatekeeper-policies` app. `deny.yaml` blocks, `warn.yaml`
  only counts. Runtime chain = gatekeeper + trivy-operator apps + `runtime-sync` CronWorkflow in
  the scan chart (Trivy Operator SBOMs → Dependency-Track `runtime/<image>`).
- `local/` — `up.sh` runs the identical app-of-apps on kind (or any cluster with `--no-kind`)
  with `mode=local`: MinIO instead of S3, plain secrets instead of External Secrets, `~/.aws`
  mounted into the deploy step. `mode` is a value on both charts; keep every AWS-only resource
  behind `{{ if eq .Values.mode "aws" }}`.
- `scripts/` — `add-projects.sh`, `run-scans.sh`, `status.sh`, `dtrack-bootstrap.sh [--local] [--policies]`,
  `release.sh`, `dtrack-tags.sh`, `start.sh` (VM + node + all UI forwards, self-healing), `ui.sh`. Ports/logins: `docs/access.md` (Argo CD 8443, Argo
  Workflows 2746, Dependency-Track 8080 UI + 8081 API). D-Track projects are tagged public/private
  from `visibility:` in `projects.yaml`.
- Gate = trivy counts + gitleaks + Dependency-Track policy violations (`dtrack-policy` task, FAIL
  blocks unless approved in D-Track; starter set in `policies/dependency-track/policies.json`).
- App Store releases (local mode): `appstore:` in `projects.yaml` → `release-candidate-<name>`
  ConfigMap (SA `security-release`, never the scanner SA) → `appstore-release` WorkflowTemplate →
  SSH forced command `local/mac-release.sh` → LaunchAgent worker builds/uploads on the Mac. The
  App Store key stays in `~/.appstoreconnect`; the cluster only gets the restricted SSH key.
- `Makefile` — thin wrappers; run `make help`.

## Commands
```bash
make init apply                 # terraform (asks for confirmation)
make kubeconfig                 # aws eks update-kubeconfig
make ui-argocd | ui-argo | ui-dtrack   # port-forwards (nothing is exposed publicly)
scripts/dtrack-bootstrap.sh     # once: admin pw, API key -> Secrets Manager
scripts/add-projects.sh URL...  # append repos to projects.yaml
git commit -am "add repos" && git push   # Argo CD syncs within ~3 min
scripts/run-scans.sh --all      # trigger scans now (or by name)
scripts/status.sh               # workflow + Dependency-Track overview
```

## Rules
- Secrets only in AWS Secrets Manager under `security-pipeline/*`; ESO syncs them. Never put
  tokens in values files or manifests.
- No public endpoints by default (UIs via port-forward). If an ingress is added, put it behind
  Cognito/OIDC and WAF per `2026/claude-aws-sst-secure-default-rulebook`.
- Pin chart versions in `argocd/bootstrap/values.yaml`; Renovate-style bumps go through a PR so
  Argo CD shows the diff.
- Don't `terraform destroy` or `argocd app delete` without the user asking; both wipe scan history.
