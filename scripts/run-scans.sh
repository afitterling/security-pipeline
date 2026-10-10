#!/usr/bin/env bash
# Trigger scans now, outside the cron schedule.
#   scripts/run-scans.sh --all              # every project in the cluster
#   scripts/run-scans.sh fin-wise timewarp  # by name
#   scripts/run-scans.sh --all --wait       # block until all finished, exit 1 if any failed
#   scripts/run-scans.sh --local            # use projects.yaml instead of cluster CronWorkflows
set -euo pipefail
cd "$(dirname "$0")/.."
NS=${NS:-security}
ARGO_NS=${ARGO_NS:-argo}
# No local argo binary needed: run the CLI that ships in the Argo Workflows server pod.
argo() { kubectl -n "$ARGO_NS" exec deploy/argo-workflows-server -c argo-server -- argo "$@"; }

all=0; wait=0; local=0; names=()
for a in "$@"; do
  case "$a" in
    --all) all=1 ;; --wait) wait=1 ;; --local) local=1 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) names+=("$a") ;;
  esac
done

if [ $all -eq 1 ]; then
  # (while-read instead of mapfile: macOS ships bash 3.2)
  if [ $local -eq 1 ]; then
    list=$(yq '.projects[] | select(.enabled != false) | .name' projects.yaml)
  else
    list=$(kubectl -n "$NS" get cronworkflows -l app.kubernetes.io/part-of=security-pipeline \
      -o jsonpath='{range .items[?(@.spec.suspend!=true)]}{.metadata.name}{"\n"}{end}' | sed 's/^scan-//')
  fi
  while IFS= read -r n; do [ -n "$n" ] && names+=("$n"); done <<< "$list"
fi
[ ${#names[@]} -gt 0 ] || { echo "nothing to run (use --all or names)"; exit 1; }

submitted=()
for n in "${names[@]}"; do
  wf=$(argo submit -n "$NS" --from "cronwf/scan-$n" --generate-name "scan-$n-manual-" -o name)
  echo "submitted $wf  (project $n)"
  submitted+=("$wf")
done

echo
echo "watch:  kubectl -n $NS get wf -w     logs: kubectl -n $NS logs -l workflows.argoproj.io/workflow=${submitted[0]} -c main -f     ui: make ui-argo"
if [ $wait -eq 1 ]; then
  rc=0
  for wf in "${submitted[@]}"; do
    argo wait -n "$NS" "$wf" >/dev/null || rc=1
    status=$(kubectl -n "$NS" get wf "$wf" -o jsonpath='{.status.phase}')
    printf '%-50s %s\n' "$wf" "$status"
  done
  exit $rc
fi
