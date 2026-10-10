#!/usr/bin/env bash
# Run the whole pipeline on a local kind cluster (or any non-EKS cluster: k3s on a VPS/EC2).
#
#   local/up.sh                      # create kind cluster + bootstrap everything
#   local/up.sh --no-kind            # use current kubeconfig context (e.g. k3s), just bootstrap
#   local/up.sh --refresh-secrets    # re-copy ~/.aws, git token, dtrack key into the cluster
#
# Env (all optional):
#   REPO_URL      git URL Argo CD pulls from   default: git remote origin
#   REPO_REV      branch                       default: current branch
#   GIT_TOKEN     read-only token for private repos (Argo CD + clone step); may live in ./.env (gitignored)
#   GIT_USERNAME  default: git
#   DTRACK_API_KEY  if you already have one (else run scripts/dtrack-bootstrap.sh --local later)
#   AWS_DIR       default: ~/.aws   (mounted into the deploy step so `npx sst deploy` works)
set -euo pipefail
cd "$(dirname "$0")/.."
# Optional .env (gitignored) for GIT_TOKEN, GIT_USERNAME, DTRACK_API_KEY, REPO_URL. Env vars already set win.
if [ -f .env ]; then
  while IFS='=' read -r k v; do
    k="${k%%#*}"; k="$(echo "$k" | xargs)"; [ -n "$k" ] || continue
    v="${v%\"}"; v="${v#\"}"
    [ -z "${!k:-}" ] && export "$k=$v"
  done < .env
  echo ".env loaded"
fi
for t in kubectl helm; do command -v $t >/dev/null || { echo "$t missing: brew install kubectl helm kind"; exit 1; }; done

use_kind=1; refresh=0
for a in "$@"; do case "$a" in --no-kind) use_kind=0 ;; --refresh-secrets) refresh=1 ;; esac; done

origin_url=$(git remote get-url origin 2>/dev/null || true)
if [ -n "${REPO_URL:-}" ] && [ -n "$origin_url" ] && [ "${REPO_URL%.git}" != "${origin_url%.git}" ] \
   && [ "${REPO_URL%.git}" != "https://github.com/${origin_url#git@github.com:}" ]; then
  echo "WARNING: REPO_URL=$REPO_URL is set in your environment but this repo's origin is $origin_url."
  echo "         Argo CD will pull charts from REPO_URL. If that is a leftover from another project: unset REPO_URL"
  read -r -p "Continue with REPO_URL? [y/N] " ans; [ "${ans:-n}" = y ] || exit 1
fi
REPO_URL=${REPO_URL:-$origin_url}
REPO_REV=${REPO_REV:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)}
[ -n "$REPO_URL" ] || { echo "REPO_URL not set and no git remote 'origin'. Push this repo first."; exit 1; }
case "$REPO_URL" in git@github.com:*) REPO_URL="https://github.com/${REPO_URL#git@github.com:}" ;; esac
GIT_USERNAME=${GIT_USERNAME:-git}
AWS_DIR=${AWS_DIR:-$HOME/.aws}

if [ $use_kind -eq 1 ]; then
  command -v kind >/dev/null || { echo "kind missing: brew install kind"; exit 1; }
  if ! kind get clusters 2>/dev/null | grep -qx security-pipeline; then
    kind create cluster --config local/kind-config.yaml --wait 120s
  fi
  kubectl config use-context kind-security-pipeline >/dev/null
fi
echo "cluster: $(kubectl config current-context)"

# ---- namespaces + secrets (what External Secrets does on EKS)
for ns in argocd argo security minio; do kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f - >/dev/null; done
mk() { kubectl -n "$1" create secret generic "$2" "${@:3}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; }

if ! kubectl -n minio get secret minio-credentials >/dev/null 2>&1; then
  pw=$(openssl rand -hex 16)
  for ns in minio argo security; do mk $ns minio-credentials --from-literal=rootUser=pipeline --from-literal=rootPassword="$pw"; done
  echo "minio credentials created"
fi

if [ $refresh -eq 1 ] || ! kubectl -n security get secret git-credentials >/dev/null 2>&1; then
  mk security git-credentials --from-literal=username="$GIT_USERNAME" --from-literal=token="${GIT_TOKEN:-}"
  if [ -n "${GIT_TOKEN:-}" ]; then
    kubectl -n argocd create secret generic repo-security-pipeline --dry-run=client -o yaml \
      --from-literal=type=git --from-literal=url="$REPO_URL" \
      --from-literal=username="$GIT_USERNAME" --from-literal=password="$GIT_TOKEN" \
      | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml | kubectl apply -f - >/dev/null
  fi
fi
if [ $refresh -eq 1 ] || ! kubectl -n security get secret dtrack-api >/dev/null 2>&1; then
  mk security dtrack-api --from-literal=apiKey="${DTRACK_API_KEY:-}"
fi
if [ -d "$AWS_DIR" ] && { [ $refresh -eq 1 ] || ! kubectl -n security get secret aws-credentials >/dev/null 2>&1; }; then
  args=()
  [ -f "$AWS_DIR/credentials" ] && args+=(--from-file=credentials="$AWS_DIR/credentials")
  [ -f "$AWS_DIR/config" ] && args+=(--from-file=config="$AWS_DIR/config")
  [ ${#args[@]} -gt 0 ] && mk security aws-credentials "${args[@]}" && echo "~/.aws copied into the cluster for the deploy step (secret security/aws-credentials)"
fi

# ---- Argo CD
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd -n argocd --wait --timeout 10m \
  --set configs.params."server\.insecure"=true \
  --set dex.enabled=false \
  --set notifications.enabled=false \
  --set applicationSet.enabled=false \
  --set controller.resources.requests.memory=256Mi \
  --set repoServer.resources.requests.memory=128Mi \
  --set server.resources.requests.memory=128Mi >/dev/null
echo "argo cd installed"

# ---- root app (mode=local → MinIO, no IRSA, no External Secrets)
helm upgrade --install security-pipeline-root argocd/bootstrap -n argocd \
  --set mode=local --set repoURL="$REPO_URL" --set targetRevision="$REPO_REV" >/dev/null
echo "root application installed (repo $REPO_URL @ $REPO_REV)"

cat <<EOF

Argo CD is syncing: minio, gatekeeper, argo-workflows, dependency-track, trivy-operator,
gatekeeper-policies, security-scans. First sync pulls ~2 GB of images; give it 5-10 minutes.

  kubectl -n argocd get applications -w
  make ui-argocd            # http://localhost:8443  admin / make argocd-password
  make ui-dtrack            # http://localhost:8080  then:
  DTRACK_ADMIN_PASSWORD=... scripts/dtrack-bootstrap.sh --local
  scripts/add-projects.sh <repo urls>; git commit -am 'add repos'; git push
  scripts/run-scans.sh --all
EOF
