#!/usr/bin/env bash
# Overview: Argo CD app health, recent workflows per project, Dependency-Track portfolio metrics.
set -euo pipefail
NS=${NS:-security}

echo "== Argo CD applications"
kubectl -n argocd get applications -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REV:.status.sync.revision' 2>/dev/null | cut -c1-110 || echo "  (no kubeconfig?)"

echo; echo "== Scheduled scans"
kubectl -n "$NS" get cronworkflows -o custom-columns='PROJECT:.metadata.labels.security-pipeline/project,SCHEDULE:.spec.schedules[0],SUSPENDED:.spec.suspend,LAST:.status.lastScheduledTime' 2>/dev/null || true

echo; echo "== Last workflows"
kubectl -n "$NS" get workflows --sort-by=.metadata.creationTimestamp \
  -o custom-columns='NAME:.metadata.name,PROJECT:.metadata.labels.security-pipeline/project,PHASE:.status.phase,STARTED:.status.startedAt,FINISHED:.status.finishedAt' 2>/dev/null | tail -n 25 || true

echo; echo "== App Store release candidates (scripts/release.sh <project>)"
kubectl -n "$NS" get configmap -l security-pipeline/release-candidate=true \
  -o custom-columns='PROJECT:.data.project,COMMIT:.data.commit,FROM:.data.workflow' 2>/dev/null || true

echo; echo "== Runtime: Gatekeeper audit violations"
kubectl get constraints -o json 2>/dev/null \
  | jq -r '.items[] | "\(.status.totalViolations // 0)\t\(.spec.enforcementAction)\t\(.kind)/\(.metadata.name)"' \
  | sort -rn | awk 'BEGIN{printf "%-6s %-7s %s\n","VIOL","ACTION","CONSTRAINT"}{printf "%-6s %-7s %s\n",$1,$2,$3}' || echo "  (gatekeeper not installed)"

echo; echo "== Runtime: vulnerable running images (Trivy Operator, top 15)"
kubectl get vulnerabilityreports -A -o json 2>/dev/null \
  | jq -r '[.items[] | {ns:.metadata.namespace, image:"\(.report.artifact.repository):\(.report.artifact.tag // "digest")", c:.report.summary.criticalCount, h:.report.summary.highCount}] | unique_by(.image) | sort_by(-.c,-.h)[:15][] | "\(.c)\t\(.h)\t\(.ns)\t\(.image)"' \
  | awk 'BEGIN{printf "%-5s %-5s %-18s %s\n","CRIT","HIGH","NS","IMAGE"}{printf "%-5s %-5s %-18s %s\n",$1,$2,$3,$4}' || echo "  (trivy-operator not installed)"

# Dependency-Track: defaults to a temporary port-forward + the pipeline's API key from the cluster
if [ -z "${DTRACK_URL:-}" ] && kubectl -n dependency-track get svc dependency-track-api-server >/dev/null 2>&1; then
  kubectl -n dependency-track port-forward svc/dependency-track-api-server 18082:8080 >/dev/null 2>&1 &
  PF=$!; trap 'kill $PF 2>/dev/null' EXIT
  DTRACK_URL=http://localhost:18082
  for i in $(seq 1 20); do curl -sf "$DTRACK_URL/api/version" >/dev/null && break; sleep 0.5; done
fi
DTRACK_API_KEY=${DTRACK_API_KEY:-$(kubectl -n "$NS" get secret dtrack-api -o jsonpath='{.data.apiKey}' 2>/dev/null | base64 -d)}
if [ -n "${DTRACK_URL:-}" ] && [ -n "${DTRACK_API_KEY:-}" ]; then
  echo; echo "== Dependency-Track portfolio ($DTRACK_URL)"
  curl -sS "$DTRACK_URL/api/v1/metrics/portfolio/current" -H "X-Api-Key: $DTRACK_API_KEY" \
    | jq -r '"projects: \(.projects)  components: \(.components)  vulnerable: \(.vulnerableProjects)  critical: \(.critical)  high: \(.high)  medium: \(.medium)  low: \(.low)  policyViolations: \(.policyViolationsTotal)"'
  # EPSS = probability (0-1) that a CVE gets exploited in the next 30 days; from the findings API
  curl -sS "$DTRACK_URL/api/v1/project?excludeInactive=true&pageSize=500" -H "X-Api-Key: $DTRACK_API_KEY" \
    | jq -r '.[] | select(.name | startswith("runtime/") | not) | [.uuid, .name, .version, (.metrics.critical // 0), (.metrics.high // 0), (.metrics.policyViolationsFail // 0), (.lastBomImport // 0 | if . > 0 then (./1000 | todate | .[0:16]) else "-" end)] | @tsv' \
    | sort -k2 | while IFS=$'\t' read -r uuid name ver crit high pfail last; do
        epss=$(curl -sS "$DTRACK_URL/api/v1/finding/project/$uuid?suppressed=false" -H "X-Api-Key: $DTRACK_API_KEY" \
          | jq -r '[([.[].vulnerability.epssScore // 0] | max // 0), ([.[] | select((.vulnerability.epssScore // 0) >= 0.1)] | length)] | "\(.[0]) \(.[1])"')
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$ver" "$crit" "$high" "$pfail" ${epss} "$last"
      done | sort -t$'\t' -k6,6gr \
    | awk -F'\t' 'BEGIN{printf "%-26s %-8s %5s %5s %6s %9s %9s  %s\n","PROJECT","VERSION","CRIT","HIGH","P-FAIL","EPSS-MAX","EPSS>=.1","LAST BOM"} {printf "%-26s %-8s %5s %5s %6s %9.4f %9s  %s\n",$1,$2,$3,$4,$5,$6,$7,$8}'
else
  echo; echo "(set DTRACK_URL=http://localhost:8081 DTRACK_API_KEY=... with 'make ui-dtrack' running for portfolio metrics)"
fi
