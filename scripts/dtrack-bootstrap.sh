#!/usr/bin/env bash
# One-time Dependency-Track setup, run from your laptop with kubeconfig + AWS creds:
#   1. forces the initial admin password change (admin/admin -> $DTRACK_ADMIN_PASSWORD)
#   2. creates team "security-pipeline" with BOM_UPLOAD, PROJECT_CREATION_UPLOAD, VIEW_PORTFOLIO,
#      VIEW_VULNERABILITY, PORTFOLIO_MANAGEMENT
#   3. generates an API key for that team
#   4. stores it in AWS Secrets Manager (security-pipeline/dependency-track) -> ESO -> workflows
# Env: DTRACK_ADMIN_PASSWORD (required, new admin password)  AWS_PROFILE/REGION as usual
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DTRACK_ADMIN_PASSWORD:?set DTRACK_ADMIN_PASSWORD to the new admin password}"
REGION=${REGION:-eu-central-1}
SECRET=${SECRET:-security-pipeline/dependency-track}
TEAM=${TEAM:-security-pipeline}
API=http://localhost:18081

kubectl -n dependency-track port-forward svc/dependency-track-api-server 18081:8080 >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null' EXIT
for i in $(seq 1 30); do curl -sf "$API/api/version" >/dev/null && break; sleep 1; done
echo "Dependency-Track $(curl -s $API/api/version | jq -r .version)"

login() { curl -s -X POST "$API/api/v1/user/login" -d "username=admin" -d "password=$1" -w '\n%{http_code}'; }
out=$(login "$DTRACK_ADMIN_PASSWORD"); code=$(tail -n1 <<<"$out"); jwt=$(head -n1 <<<"$out")
if [ "$code" != "200" ]; then
  echo "admin login with new password failed ($code) — trying first-login password change"
  curl -sf -X POST "$API/api/v1/user/forceChangePassword" \
    -d username=admin -d password=admin \
    -d "newPassword=$DTRACK_ADMIN_PASSWORD" -d "confirmPassword=$DTRACK_ADMIN_PASSWORD" >/dev/null
  out=$(login "$DTRACK_ADMIN_PASSWORD"); code=$(tail -n1 <<<"$out"); jwt=$(head -n1 <<<"$out")
  [ "$code" = "200" ] || { echo "login still failing ($code)"; exit 1; }
  echo "admin password changed"
fi
auth=(-H "Authorization: Bearer $jwt" -H "Content-Type: application/json")

team_uuid=$(curl -s "$API/api/v1/team" "${auth[@]}" | jq -r ".[] | select(.name==\"$TEAM\") | .uuid")
if [ -z "$team_uuid" ]; then
  team_uuid=$(curl -sf -X PUT "$API/api/v1/team" "${auth[@]}" -d "{\"name\":\"$TEAM\"}" | jq -r .uuid)
  echo "created team $TEAM ($team_uuid)"
fi
for perm in BOM_UPLOAD PROJECT_CREATION_UPLOAD VIEW_PORTFOLIO VIEW_VULNERABILITY PORTFOLIO_MANAGEMENT; do
  curl -s -o /dev/null -X POST "$API/api/v1/permission/$perm/team/$team_uuid" "${auth[@]}"
done
echo "permissions set"

key=$(curl -sf -X PUT "$API/api/v1/team/$team_uuid/key" "${auth[@]}" | jq -r .key)
if [ "${1:-}" = "--local" ]; then
  kubectl -n security create secret generic dtrack-api --from-literal=apiKey="$key" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "API key stored in secret security/dtrack-api (local mode)"
else
  aws secretsmanager put-secret-value --region "$REGION" --secret-id "$SECRET" \
    --secret-string "$(jq -cn --arg k "$key" '{apiKey:$k}')" >/dev/null
  echo "API key stored in Secrets Manager: $SECRET"
  echo "ESO refreshes within 5 min; force it with:"
  echo "  kubectl -n security annotate externalsecret dtrack-api force-sync=\$(date +%s) --overwrite"
fi
