#!/usr/bin/env bash
# One-time Dependency-Track setup, run from your laptop with kubeconfig + AWS creds:
#   1. forces the initial admin password change (admin/admin -> $DTRACK_ADMIN_PASSWORD)
#   2. creates team "security-pipeline" with BOM_UPLOAD, PROJECT_CREATION_UPLOAD, VIEW_PORTFOLIO,
#      VIEW_VULNERABILITY, VIEW_POLICY_VIOLATION, PORTFOLIO_MANAGEMENT
#   3. enables the OSV ecosystems (npm, PyPI, Go, Maven, SwiftURL …) and the EPSS feed
#   4. generates an API key for that team (skip with --no-key: the existing key keeps working and
#      picks up new team permissions)
#   5. stores it in AWS Secrets Manager (security-pipeline/dependency-track) -> ESO -> workflows,
#      or with --local in the plain secret security/dtrack-api
#   --policies: create the starter policies from policies/dependency-track/policies.json
#      (existing policies with the same name are left as they are)
# Usage: scripts/dtrack-bootstrap.sh [--local] [--policies] [--no-key]
# Env: DTRACK_ADMIN_PASSWORD (required, new admin password)  AWS_PROFILE/REGION as usual
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DTRACK_ADMIN_PASSWORD:?set DTRACK_ADMIN_PASSWORD to the new admin password}"
REGION=${REGION:-eu-central-1}
SECRET=${SECRET:-security-pipeline/dependency-track}
TEAM=${TEAM:-security-pipeline}
API=http://localhost:18081
OSV_ECOSYSTEMS=${OSV_ECOSYSTEMS:-npm;PyPI;Go;Maven;SwiftURL;crates.io;NuGet;RubyGems;Packagist}
local=0; policies=0; newkey=1
for a in "$@"; do
  case "$a" in
    --local) local=1 ;; --policies) policies=1 ;; --no-key) newkey=0 ;;
    *) echo "unknown option $a"; exit 1 ;;
  esac
done

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
for perm in BOM_UPLOAD PROJECT_CREATION_UPLOAD VIEW_PORTFOLIO VIEW_VULNERABILITY VIEW_POLICY_VIOLATION PORTFOLIO_MANAGEMENT; do
  curl -s -o /dev/null -X POST "$API/api/v1/permission/$perm/team/$team_uuid" "${auth[@]}"
done
echo "permissions set"

# ---- vulnerability sources: OSV (much better than NVD for npm/PyPI/Go/Swift) + EPSS
cfg() { jq -cn --arg g "$1" --arg n "$2" --arg v "$3" '[{groupName:$g, propertyName:$n, propertyValue:$v}]'; }
curl -sf -o /dev/null -X POST "$API/api/v1/configProperty/aggregate" "${auth[@]}" \
  -d "$(cfg vuln-source google.osv.enabled "$OSV_ECOSYSTEMS")" && echo "OSV ecosystems: $OSV_ECOSYSTEMS" \
  || echo "WARNING: could not set OSV ecosystems (Administration → Vulnerability Sources → Google OSV)"
curl -sf -o /dev/null -X POST "$API/api/v1/configProperty/aggregate" "${auth[@]}" \
  -d "$(cfg vuln-source epss.enabled true)" && echo "EPSS feed enabled" \
  || echo "WARNING: could not enable EPSS (Administration → Vulnerability Sources → EPSS)"

# ---- starter policies
if [ $policies -eq 1 ]; then
  existing=$(curl -sf "$API/api/v1/policy?pageSize=500" "${auth[@]}" | jq -r '.[].name')
  groups=$(curl -sf "$API/api/v1/licenseGroup?pageSize=500" "${auth[@]}" || echo '[]')
  jq -c '.policies[]' policies/dependency-track/policies.json | while IFS= read -r pol; do
    name=$(jq -r .name <<<"$pol")
    if grep -qxF "$name" <<<"$existing"; then echo "policy exists, unchanged: $name"; continue; fi
    puuid=$(curl -sf -X PUT "$API/api/v1/policy" "${auth[@]}" -d "$(jq -c '{name, operator, violationState}' <<<"$pol")" | jq -r .uuid) \
      || { echo "WARNING: could not create policy $name"; continue; }
    jq -c '.conditions[]' <<<"$pol" | while IFS= read -r c; do
      if [ "$(jq -r .subject <<<"$c")" = LICENSE_GROUP ]; then   # the API wants the group's uuid
        g=$(jq -r --arg n "$(jq -r .value <<<"$c")" '.[] | select(.name == $n) | .uuid' <<<"$groups")
        [ -n "$g" ] || { echo "WARNING: license group '$(jq -r .value <<<"$c")' not found; condition skipped"; continue; }
        c=$(jq -c --arg g "$g" '.value = $g' <<<"$c")
      fi
      curl -sf -o /dev/null -X PUT "$API/api/v1/policy/$puuid/condition" "${auth[@]}" -d "$c" \
        || echo "WARNING: policy '$name': condition $(jq -c '{subject, operator}' <<<"$c") rejected"
    done
    echo "policy created: $name ($(jq -r .violationState <<<"$pol"))"
  done
fi

[ $newkey -eq 1 ] || { echo "API key unchanged (--no-key)"; exit 0; }
key=$(curl -sf -X PUT "$API/api/v1/team/$team_uuid/key" "${auth[@]}" | jq -r .key)
if [ $local -eq 1 ]; then
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
