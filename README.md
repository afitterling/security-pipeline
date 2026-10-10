# security-pipeline

GitOps CI/security pipeline on AWS for many repositories at once.

```
projects.yaml ──git push──▶ Argo CD ──▶ one CronWorkflow per repo (Argo Workflows, EKS)
                                              │
   clone ─┬─ detect ── build/test ───┐        │ nightly / on demand
          ├─ syft SBOM ── upload ────┤        ▼
          ├─ trivy ──────────────────┼─ gate ─▶ deploy (npx sst deploy --stage …) ─▶ reports → S3
          ├─ gitleaks ───────────────┤   │
          └─ semgrep ────────────────┘   └─ Dependency-Track (SBOM portfolio, continuous re-analysis)
```

- **Argo CD** tracks this repo. Changing `projects.yaml` is the only thing you do to add or
  remove repositories; Argo CD creates/deletes the schedules. It also installs the runtime chain:
  OPA Gatekeeper (policies in `policies/gatekeeper/`), Trivy Operator, and the hourly
  `runtime-sync` that feeds runtime SBOMs into Dependency-Track.
- **Argo Workflows** runs the pipeline; its UI is the run history ("steady pipe tracking").
- **Dependency-Track** keeps every SBOM and re-evaluates it daily against NVD/OSV/GitHub
  Advisories, so a new CVE shows up without a rescan.
- **Detection**: the pipeline inspects each repo. `sst.config.ts` → `npm ci` + `npx sst deploy
  --stage <stage>`; plain `package.json` → build/test only; Python, Terraform, Swift (scan-only).
  Override with `commands:` in `projects.yaml` or `.security-pipeline.json` in the repo.
- **Gate before deploy**: deploy runs only if trivy CRITICAL/HIGH counts are within the
  project's `gate` and gitleaks found nothing.
- **Reports** (SBOMs, trivy/semgrep/gitleaks JSON+SARIF, build/deploy logs, summary.json) land in
  S3 under `security/<project>/<date>/<run>/`.

## Runtime detection (in-cluster, also managed by Argo CD)

- **OPA Gatekeeper** (`policies/gatekeeper/`): admission control plus a 60-second audit of
  everything already running. `deny`: privileged containers, host namespaces, and in the
  `security` namespace only images from the pinned scanner registries. `warn` (counted, not
  blocked): allowed registries cluster-wide, privilege escalation, missing memory limits,
  floating tags, required labels. Promote warn → deny in `constraints/warn.yaml` once
  `scripts/status.sh` shows zero violations.
- **Trivy Operator**: generates an SBOM and a vulnerability report for every running image,
  rescans as new CVEs are published, and audits workload config and RBAC.
- **runtime-sync** CronWorkflow (hourly): pushes the Trivy Operator SBOMs into Dependency-Track
  as `runtime/<image>` projects, and archives the vulnerability and Gatekeeper audit summaries to
  the reports bucket. Set `runtime.gate.critical` in `charts/security-scans/values.yaml` to make
  it fail when a running image exceeds the threshold.

## Running it locally (free)

The same Argo CD app-of-apps runs on a kind cluster on your Mac. MinIO replaces S3, plain
Kubernetes secrets replace Secrets Manager, your `~/.aws` is mounted into the deploy step so
`npx sst deploy` works with your normal profiles. Docker Desktop / OrbStack with about 6 CPU and
12 GB RAM; Dependency-Track alone wants ~2 GB.

```bash
brew install docker kind kubectl helm argo yq jq     # once
git remote add origin https://github.com/<you>/security-pipeline.git && git push -u origin main
GIT_TOKEN=<read-only PAT> make local-up             # ~10 min, pulls ~2 GB of images
make ui-dtrack &                                     # http://localhost:8080
DTRACK_ADMIN_PASSWORD='<new pw>' scripts/dtrack-bootstrap.sh --local
scripts/add-projects.sh https://github.com/<you>/some-sst-app.git
git commit -am "add repos" && git push              # Argo CD syncs in ~3 min
scripts/run-scans.sh --all                           # or wait for the nightly cron
make ui-argo                                         # http://localhost:2746 run history
make local-down                                      # delete everything
```

Argo CD still needs the repo on GitHub (free, private is fine), because it pulls from git.
`make local-secrets` re-copies `~/.aws`, the git token and the Dependency-Track key after changes.
`local/up.sh --no-kind` bootstraps any existing cluster the same way, e.g. k3s on one small VM.

## Prerequisites (AWS/EKS variant)

`terraform ≥ 1.6`, `aws` CLI with access to account 327261196437, `kubectl`, `helm`, `argo`
(`brew install helm kubectl argo yq jq`). This repo must be pushed to a git remote Argo CD can
read (GitHub, HTTPS). For a private repo create a read-only token.

## First deployment (one-time, ~25 min)

```bash
cd infra/terraform
cp backend.hcl.example backend.hcl          # S3 state bucket + lock table
cp terraform.tfvars.example terraform.tfvars  # repo URL, your IP for the EKS endpoint
cd ../..
make init
TF_VAR_git_token=<read-only token> make apply   # omit TF_VAR_git_token for a public repo
make kubeconfig
```

Terraform creates VPC, EKS (2× t3.xlarge, gp3, IMDSv2, KMS secrets encryption), four IRSA roles
(EBS CSI, workflows→S3, External Secrets→Secrets Manager, deployer), the reports bucket, two
Secrets Manager entries, Argo CD, and the root Application. Argo CD then installs everything else
from `argocd/bootstrap` within a few minutes:

```bash
make ui-argocd           # http://localhost:8443, admin / `make argocd-password`
kubectl -n argocd get applications      # external-secrets, argo-workflows, dependency-track, security-scans
```

### Dependency-Track API key and git credentials

```bash
make ui-dtrack &                                   # UI http://localhost:8080 (admin/admin first login)
DTRACK_ADMIN_PASSWORD='<new strong pw>' scripts/dtrack-bootstrap.sh
# -> changes admin pw, creates team + API key, writes it to Secrets Manager security-pipeline/dependency-track

aws secretsmanager put-secret-value --secret-id security-pipeline/git \
  --secret-string '{"username":"git","token":"<read-only PAT>"}'
```

External Secrets syncs both into the `security` namespace within 5 minutes.

## Adding projects (many at once)

```bash
scripts/add-projects.sh https://github.com/you/fin-wise.git https://github.com/you/timewarp.git
# or
scripts/add-projects.sh --file repos.txt
git add projects.yaml && git commit -m "scan: add 2 projects" && git push
```

Argo CD syncs and creates `security/scan-<name>` CronWorkflows (staggered from 03:00
Europe/Berlin). Per-project options (branch, SST stage, gate thresholds, custom commands) are
documented at the top of `projects.yaml`.

Run them now instead of waiting for the schedule:

```bash
scripts/run-scans.sh --all            # everything
scripts/run-scans.sh fin-wise         # one
scripts/run-scans.sh --all --wait     # block, non-zero exit if any run failed
make ui-argo                          # http://localhost:2746 — DAG, logs, history
scripts/status.sh                     # apps, schedules, last runs, Dependency-Track portfolio
```

## How deploy works

`detect` writes `plan.json` (kind, install, build, test, deploy, SST profiles found in
`sst.config.ts`). `build-test` runs install/build/test on a per-run PVC. After `gate` passes,
`deploy` runs the deploy command under the `security-deploy` service account, which assumes the
`security-pipeline-deployer` IAM role (PowerUserAccess + scoped IAM, denies on the pipeline's own
roles, users, EKS). Profiles pinned in `sst.config.ts` (e.g. `alex1-dev`) are mapped to that
identity via a generated `~/.aws/config`, so configs that hardcode a profile deploy unchanged.

To deploy a stage other than `dev`, set `deploy.stage` per project. To scan without deploying,
`deploy.enabled: false`.

## Security posture

No public endpoints: all UIs via `kubectl port-forward`. EKS API restricted to your CIDRs.
Secrets only in Secrets Manager (`security-pipeline/*`), synced by External Secrets; nothing in git.
Scanner pods hold a role that can only write the reports bucket; only the deploy pod can assume
the deployer role. Node IMDS hop limit 1 blocks pods from the node role.

Before exposing a UI: Argo CD → SSO/Cognito, Argo Workflows `authModes: [sso]`, Dependency-Track
OIDC, all behind an ALB with WAF per `2026/claude-aws-sst-secure-default-rulebook`.

## Costs (eu-central-1, rough)

| Option | €/month | Notes |
|---|---|---|
| Local kind cluster (`make local-up`) | 0 | Only while your Mac runs; scans run when it is awake |
| k3s on one spot EC2 (t4g.large / t3.large), `local/up.sh --no-kind` | 20–35 | No EKS fee, no NAT; single node, stop it at night |
| EKS, 1× t3.xlarge spot, NAT | ~130 | `node_desired_size = 1`, spot capacity type |
| EKS as configured, 2× t3.xlarge on-demand, NAT | ~240 | Control plane 70, nodes 120, NAT 35, storage/logs 15 |

The deploy targets (your SST stages) cost the same wherever the pipeline runs.

## Upgrading

Chart versions are pinned as ranges in `argocd/bootstrap/values.yaml`; Argo CD picks up new
patch versions on the next refresh. Bump majors via PR. Terraform providers/modules are pinned
in `infra/terraform/versions.tf` and the module blocks.

## Dependency-Track on RDS (recommended for production)

Set `dependencyTrack.postgresql.enabled: false` in `argocd/bootstrap/values.yaml`, create an RDS
PostgreSQL in the VPC (Terraform), and add `ALPINE_DATABASE_URL/USERNAME/PASSWORD` to
`apiServer.extraEnv` via an ExternalSecret.
