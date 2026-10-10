#!/usr/bin/env bash
# Trigger scans now, outside the cron schedule. Rolling by default: one workflow at a time,
# the next one is submitted only after the previous finished (keeps a small cluster responsive).
#   scripts/run-scans.sh --all              # every project in the cluster, one after another
#   scripts/run-scans.sh fin-wise timewarp  # by name, in that order
#   scripts/run-scans.sh --all --parallel   # old behaviour: submit everything at once, don't wait
#   scripts/run-scans.sh --all --local      # use projects.yaml instead of cluster CronWorkflows
#   scripts/run-scans.sh --all --resume     # skip projects that already have a finished manual run
# Exit code 1 if any run did not succeed. Ctrl-C stops submitting; the current run keeps going.
set -euo pipefail
cd "$(dirname "$0")/.."
NS=${NS:-security}
ARGO_NS=${ARGO_NS:-argo}
POLL=${POLL:-10}   # seconds between status checks while waiting
# No local argo binary needed: run the CLI that ships in the Argo Workflows server pod.
argo() { kubectl -n "$ARGO_NS" exec deploy/argo-workflows-server -c argo-server -- argo "$@"; }

all=0; parallel=0; local=0; resume=0; names=()
for a in "$@"; do
  case "$a" in
    --all) all=1 ;; --parallel) parallel=1 ;; --local) local=1 ;; --resume) resume=1 ;;
    --wait) ;;   # kept for old call sites: waiting is the default now
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
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

if [ $resume -eq 1 ]; then
  done_list=$(kubectl -n "$NS" get wf -l security-pipeline/project \
    -o jsonpath='{range .items[?(@.status.phase=="Succeeded")]}{.metadata.labels.security-pipeline/project}{"\n"}{end}' | sort -u)
  kept=()
  for n in "${names[@]}"; do
    if grep -qx "$n" <<< "$done_list"; then echo "skip      $n (already succeeded)"; else kept+=("$n"); fi
  done
  names=("${kept[@]+"${kept[@]}"}")
  [ ${#names[@]} -gt 0 ] || { echo "nothing left to run"; exit 0; }
fi

submit() { argo submit -n "$NS" --from "cronwf/scan-$1" --generate-name "scan-$1-manual-" -o name; }

# Gate summary of a finished run, e.g. "crit=0 high=3 leaks=0 sg=12" (empty if the gate never ran)
summary() {
  kubectl -n "$NS" get wf "$1" -o json 2>/dev/null | jq -r '
    [.status.nodes[]? | select(.displayName=="gate") | .outputs.parameters[]? | select(.name=="summary") | .value][0]
    // "" | if . == "" then "" else (fromjson | "crit=\(.critical) high=\(.high) leaks=\(.gitleaks) sg=\(.semgrep)") end'
}

if [ $parallel -eq 1 ]; then
  first=""
  for n in "${names[@]}"; do
    wf=$(submit "$n"); echo "submitted $wf  (project $n)"; : "${first:=$wf}"
  done
  echo
  echo "watch:  kubectl -n $NS get wf -w     logs: kubectl -n $NS logs -l workflows.argoproj.io/workflow=$first -c main -f     ui: make ui-argo"
  exit 0
fi

# ---- rolling: submit, wait, next
stop=0; trap 'stop=1; echo; echo "interrupted: no further scans will be submitted"' INT
total=${#names[@]}; i=0; failed=0; ran=()
echo "rolling scan of $total project(s), one at a time (ui: make ui-argo)"
for n in "${names[@]}"; do
  [ $stop -eq 1 ] && break
  i=$((i+1))
  wf=$(submit "$n")
  start=$(date +%s)
  printf '[%d/%d] %-32s %s ' "$i" "$total" "$n" "$wf"
  phase=""
  while [ $stop -eq 0 ]; do
    phase=$(kubectl -n "$NS" get wf "$wf" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    case "$phase" in Succeeded|Failed|Error) break ;; esac
    sleep "$POLL"
  done
  if [ $stop -eq 1 ]; then echo "(still running)"; break; fi
  secs=$(( $(date +%s) - start ))
  printf '%-9s %3dm%02ds  %s\n' "$phase" $((secs/60)) $((secs%60)) "$(summary "$wf")"
  ran+=("$wf $phase")
  [ "$phase" = Succeeded ] || failed=$((failed+1))
done

echo
echo "finished ${#ran[@]}/$total, failed: $failed"
[ $failed -eq 0 ]
