#!/usr/bin/env bash
# Append one or more repositories to projects.yaml.
#   scripts/add-projects.sh https://github.com/org/a.git https://github.com/org/b.git
#   scripts/add-projects.sh --file repos.txt            # one URL per line, '#' comments ok
#   scripts/add-projects.sh --ref develop URL...        # scan a different branch
# Names are derived from the URL (last path segment, lowercased, dashes). Schedules are
# staggered 10 min apart starting 03:00 so scans don't all hit the cluster at once.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v yq >/dev/null || { echo "yq is required (brew install yq)"; exit 1; }

ref=main; urls=()
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) ref="$2"; shift 2 ;;
    --file) while read -r l; do l="${l%%#*}"; l="$(echo "$l" | xargs)"; [ -n "$l" ] && urls+=("$l"); done < "$2"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) urls+=("$1"); shift ;;
  esac
done
[ ${#urls[@]} -gt 0 ] || { echo "no repositories given"; exit 1; }

count=$(yq '.projects | length' projects.yaml)
added=0
for url in "${urls[@]}"; do
  name=$(basename "${url%.git}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')
  if yq -e ".projects[] | select(.name == \"$name\")" projects.yaml >/dev/null 2>&1; then
    echo "skip   $name (already in projects.yaml)"; continue
  fi
  slot=$(( (count + added) % 12 ))
  minute=$(( slot * 10 ))
  hour=$(( 3 + (count + added) / 12 ))
  schedule=$(printf '%d %d * * *' "$minute" "$hour")
  NAME="$name" URL="$url" REF="$ref" SCHED="$schedule" \
    yq -i '.projects += [{"name": env(NAME), "repo": env(URL), "ref": env(REF), "schedule": env(SCHED)}]' projects.yaml
  echo "added  $name  ($url @ $ref, cron '$schedule')"
  added=$((added + 1))
done
echo
echo "$added project(s) added. Commit and push; Argo CD creates the CronWorkflows:"
echo "  git add projects.yaml && git commit -m 'scan: add $added project(s)' && git push"
echo "Run immediately after sync:  scripts/run-scans.sh --all"
