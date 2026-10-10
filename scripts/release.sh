#!/usr/bin/env bash
# Ship a gate-passed commit to App Store Connect / TestFlight (local mode).
#   scripts/release.sh <project> [--dry-run] [--wait]
# Needs a release candidate: a scan of <project> with appstore.enabled: true whose gate passed
# (ConfigMap security/release-candidate-<project>). The build runs on the Mac (local/mac-release.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
NS=${NS:-security}
ARGO_NS=${ARGO_NS:-argo}
argo() { kubectl -n "$ARGO_NS" exec deploy/argo-workflows-server -c argo-server -- argo "$@"; }

name=""; dry=false; wait=0
for a in "$@"; do
  case "$a" in
    --dry-run) dry=true ;; --wait) wait=1 ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) name=$a ;;
  esac
done
[ -n "$name" ] || { sed -n '2,5p' "$0"; exit 1; }

echo "candidates:"
kubectl -n "$NS" get configmap -l security-pipeline/release-candidate=true \
  -o custom-columns='NAME:.data.project,COMMIT:.data.commit,FROM:.data.workflow' 2>/dev/null | sed 's/^/  /'
kubectl -n "$NS" get configmap "release-candidate-$name" >/dev/null 2>&1 \
  || { echo "no release candidate for $name (appstore.enabled true + a scan whose gate passed)"; exit 1; }

wf=$(argo submit -n "$NS" --from wftmpl/appstore-release --generate-name "release-$name-" \
  -p project="$name" -p dry-run="$dry" -o name)
echo "submitted $wf (dry-run: $dry)"
echo "logs: kubectl -n $NS logs -l workflows.argoproj.io/workflow=$wf -c main -f     ui: make ui-argo"
if [ $wait -eq 1 ]; then
  argo wait -n "$NS" "$wf" >/dev/null || true
  kubectl -n "$NS" logs -l workflows.argoproj.io/workflow="$wf" -c main --tail=40 2>/dev/null || true
  phase=$(kubectl -n "$NS" get wf "$wf" -o jsonpath='{.status.phase}'); echo "$wf: $phase"
  [ "$phase" = Succeeded ]
fi
