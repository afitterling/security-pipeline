#!/usr/bin/env bash
# Tag Dependency-Track projects from projects.yaml now: visibility (public|private) + tags:.
# Every scan does the same in its dtrack-policy step; this is for existing projects or after
# editing projects.yaml. Tags added in the D-Track UI are kept; public/private replace each other.
#   scripts/dtrack-tags.sh            # all projects
#   scripts/dtrack-tags.sh lucerna    # by name
set -euo pipefail
cd "$(dirname "$0")/.."
NS=${NS:-security}
command -v yq >/dev/null || { echo "yq is required (brew install yq)"; exit 1; }

if [ -z "${DTRACK_URL:-}" ]; then
  kubectl -n dependency-track port-forward svc/dependency-track-api-server 18083:8080 >/dev/null 2>&1 &
  PF=$!; trap 'kill $PF 2>/dev/null' EXIT
  DTRACK_URL=http://localhost:18083
  for i in $(seq 1 30); do curl -sf "$DTRACK_URL/api/version" >/dev/null && break; sleep 0.5; done
fi
DTRACK_API_KEY=${DTRACK_API_KEY:-$(kubectl -n "$NS" get secret dtrack-api -o jsonpath='{.data.apiKey}' | base64 -d)}
api() { curl -sS --fail-with-body -H "X-Api-Key: $DTRACK_API_KEY" "$@"; }

merge='($want | ascii_downcase | split(",") | map(select(. != ""))) as $w
  | ([.tags[]?.name] as $have
     | ($have | map(select(. as $t | (["public","private"] | index($t)) == null or ($w | index($t)) != null)))
       + $w | unique) as $new
  | if ($new | sort) == ([.tags[]?.name] | sort) then empty else {tags: ($new | map({name: .}))} end'

filter='.projects[] | select(.repo | test("<") | not)'
only=" $* "
changed=0; missing=0
while IFS=$'\t' read -r name version want; do
  [ -n "$want" ] || continue
  [ "$only" = "  " ] || [[ "$only" == *" $name "* ]] || continue
  uuid=$(api -G "$DTRACK_URL/api/v1/project/lookup" --data-urlencode "name=$name" --data-urlencode "version=$version" 2>/dev/null | jq -r '.uuid // empty' 2>/dev/null || true)
  if [ -z "$uuid" ]; then printf '%-40s %s\n' "$name" "not in Dependency-Track yet (scan it first)"; missing=$((missing+1)); continue; fi
  body=$(api "$DTRACK_URL/api/v1/project/$uuid" | jq -c --arg want "$want" "$merge")
  if [ -z "$body" ]; then printf '%-40s %s\n' "$name" "ok ($want)"; continue; fi
  api -X PATCH -H "Content-Type: application/json" -d "$body" "$DTRACK_URL/api/v1/project/$uuid" >/dev/null
  printf '%-40s %s\n' "$name" "tagged: $(jq -r '[.tags[].name] | join(",")' <<<"$body")"
  changed=$((changed+1))
done < <(yq -r "$filter | [.name, (.version // .ref // \"main\"), ([.visibility] + (.tags // []) | map(select(. != null)) | join(\",\"))] | @tsv" projects.yaml)
echo; echo "$changed project(s) updated, $missing not scanned yet"
