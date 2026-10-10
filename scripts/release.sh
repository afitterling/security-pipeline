#!/usr/bin/env bash
# Upload a gate-passed commit to TestFlight (local mode): submits the upload-to-testflight workflow.
#   scripts/release.sh <project> [--dry-run] [--wait]
# Only for projects tagged appleapp with an appstore: { path, builds } block in projects.yaml, and only
# after a scan whose gate passed (ConfigMap security/release-candidate-<project>).
# The build runs on the Mac (local/mac-release.sh).
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

echo "TestFlight candidates:"
kubectl -n "$NS" get configmap -l security-pipeline/release-candidate=true \
  -o custom-columns='NAME:.data.project,COMMIT:.data.commit,FROM:.data.workflow' 2>/dev/null | sed 's/^/  /'
kubectl -n "$NS" get configmap "release-candidate-$name" >/dev/null 2>&1 \
  || { echo "no TestFlight candidate for $name (tag appleapp + appstore: block + a scan whose gate passed)"; exit 1; }

wf=$(argo submit -n "$NS" --from wftmpl/upload-to-testflight --generate-name "testflight-$name-" \
  -p project="$name" -p dry-run="$dry" -o name)
echo "submitted $wf (dry-run: $dry)"
echo "logs: kubectl -n $NS logs -l workflows.argoproj.io/workflow=$wf -c main -f     ui: make ui-argo"
if [ $wait -eq 1 ]; then
  argo wait -n "$NS" "$wf" >/dev/null || true
  kubectl -n "$NS" logs -l workflows.argoproj.io/workflow="$wf" -c main --tail=40 2>/dev/null || true
  phase=$(kubectl -n "$NS" get wf "$wf" -o jsonpath='{.status.phase}'); echo "$wf: $phase"
  [ "$phase" = Succeeded ]
fi
