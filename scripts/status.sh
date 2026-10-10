#!/usr/bin/env bash
# Overview: Argo CD app health, recent workflows per project, Dependency-Track portfolio metrics.
set -euo pipefail
NS=${NS:-security}

echo "== Argo CD applications"
kubectl -n argocd get applications -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REV:.status.sync.revision' 2>/dev/null | cut -c1-110 || echo "  (no kubeconfig?)"

echo; echo "== Scheduled scans"
kubectl -n "$NS" get cronworkflows -o custom-columns='PROJECT:.metadata.labels.security-pipeline/project,SCHEDULE:.spec.schedule,SUSPENDED:.spec.suspend,LAST:.status.lastScheduledTime' 2>/dev/null || true

echo; echo "== Last workflows"
kubectl -n "$NS" get workflows --sort-by=.metadata.creationTimestamp \
  -o custom-columns='NAME:.metadata.name,PROJECT:.metadata.labels.security-pipeline/project,PHASE:.status.phase,STARTED:.status.startedAt,FINISHED:.status.finishedAt' 2>/dev/null | tail -n 25 || true

echo; echo "== Runtime: Gatekeeper audit violations"
kubectl get constraints -o json 2>/dev/null \
  | jq -r '.items[] | "\(.status.totalViolations // 0)\t\(.spec.enforcementAction)\t\(.kind)/\(.metadata.name)"' \
  | sort -rn | awk 'BEGIN{printf "%-6s %-7s %s\n","VIOL","ACTION","CONSTRAINT"}{printf "%-6s %-7s %s\n",$1,$2,$3}' || echo "  (gatekeeper not installed)"

echo; echo "== Runtime: vulnerable running images (Trivy Operator, top 15)"
kubectl get vulnerabilityreports -A -o json 2>/dev/null \
  | jq -r '[.items[] | {ns:.metadata.namespace, image:"\(.report.artifact.repository):\(.report.artifact.tag // "digest")", c:.report.summary.criticalCount, h:.report.summary.highCount}] | unique_by(.image) | sort_by(-.c,-.h)[:15][] | "\(.c)\t\(.h)\t\(.ns)\t\(.image)"' \
  | awk 'BEGIN{printf "%-5s %-5s %-18s %s\n","CRIT","HIGH","NS","IMAGE"}{printf "%-5s %-5s %-18s %s\n",$1,$2,$3,$4}' || echo "  (trivy-operator not installed)"

if [ -n "${DTRACK_URL:-}" ] && [ -n "${DTRACK_API_KEY:-}" ]; then
  echo; echo "== Dependency-Track portfolio ($DTRACK_URL)"
  curl -sS "$DTRACK_URL/api/v1/metrics/portfolio/current" -H "X-Api-Key: $DTRACK_API_KEY" \
    | jq -r '"projects: \(.projects)  components: \(.components)  vulnerable: \(.vulnerableProjects)  critical: \(.critical)  high: \(.high)  medium: \(.medium)  low: \(.low)  policyViolations: \(.policyViolationsTotal)"'
  curl -sS "$DTRACK_URL/api/v1/project?excludeInactive=true&pageSize=200" -H "X-Api-Key: $DTRACK_API_KEY" \
    | jq -r '.[] | [.name, .version, (.metrics.critical // 0), (.metrics.high // 0), (.lastBomImport // 0 | if . > 0 then (./1000 | todate) else "-" end)] | @tsv' \
    | sort | awk 'BEGIN{printf "%-30s %-12s %5s %5s  %s\n","PROJECT","VERSION","CRIT","HIGH","LAST BOM"} {printf "%-30s %-12s %5s %5s  %s\n",$1,$2,$3,$4,$5}'
else
  echo; echo "(set DTRACK_URL=http://localhost:8081 DTRACK_API_KEY=... with 'make ui-dtrack' running for portfolio metrics)"
fi
