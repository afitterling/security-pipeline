#!/bin/bash
# TestFlight upload on this Mac, driven by the upload-to-testflight workflow.
#
# Three ways in:
#   (ssh forced command)   SSH_ORIGINAL_COMMAND="<project> <40-hex commit> <true|false>"
#                          Validates, queues the request for the worker and streams its log back.
#                          Installed by local/mac-release-setup.sh into ~/.ssh/authorized_keys.
#   --worker               Run by the LaunchAgent (GUI session: unlocked keychain for signing,
#                          gh credentials). Processes queued requests one by one.
#   --run <project> <commit> [true|false]   Build directly in this terminal (manual test).
#
# Nothing from the cluster is trusted except project name + commit: repo, path, schemes and
# platforms come from projects.yaml in this checkout, and the project needs the tag appleapp.
# The commit must be on the configured ref. Credentials: ~/.appstoreconnect (never printed).
set -uo pipefail
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
SPOOL="$HOME/Library/Application Support/security-pipeline/release"
LOGS="$HOME/Library/Logs/security-pipeline"
mkdir -p "$SPOOL/queue" "$SPOOL/results" "$LOGS"

die() { echo "ERROR: $*"; return 1; }

# ---------------------------------------------------------------- the actual build
release() {
  local project=$1 commit=$2 dry=$3
  echo "== release $project @ $commit (dry-run: $dry) on $(hostname -s), $(date '+%F %T')"
  local cfg
  cfg=$(/usr/bin/ruby -ryaml -e '
    name = ARGV[1]
    p = (YAML.load_file(ARGV[0])["projects"] || []).find { |x| x["name"] == name } or abort "unknown project #{name}"
    a = p["appstore"] || {}
    abort "#{name}: not tagged appleapp in projects.yaml" unless (p["tags"] || []).map { |t| t.to_s.downcase }.include?("appleapp")
    path = a["path"].to_s
    abort "#{name}: no appstore: { path, builds } block in projects.yaml" if path.empty?
    abort "#{name}: bad appstore.path" if path.start_with?("/") || path.split("/").include?("..")
    builds = a["builds"] || []
    abort "#{name}: appstore.builds is empty" if builds.empty?
    puts p["repo"], (p["ref"] || "main"), path
    builds.each do |b|
      s, pl = b["scheme"].to_s, b["platform"].to_s
      abort "#{name}: bad scheme #{s.inspect}" unless s =~ /\A[A-Za-z0-9 ._-]+\z/
      abort "#{name}: platform must be ios, macos or catalyst" unless %w[ios macos catalyst].include?(pl)
      puts "#{pl} #{s}"
    end' "$REPO_DIR/projects.yaml" "$project") || return 1
  local repo ref path; { read -r repo; read -r ref; read -r path; } <<<"$cfg"
  case "$repo" in https://github.com/*) ;; *) die "repo must be https://github.com/...: $repo" || return 1 ;; esac

  local tmp; tmp=$(mktemp -d /tmp/security-pipeline-release.XXXXXX)
  trap 'rm -rf "$tmp"' RETURN
  echo "-- clone $repo ($ref)"
  GIT_TERMINAL_PROMPT=0 git -c credential.helper= -c credential.helper='!gh auth git-credential' \
    clone --quiet --filter=blob:none --branch "$ref" "$repo" "$tmp/src" || { die "clone failed"; return 1; }
  cd "$tmp/src" || return 1
  git merge-base --is-ancestor "$commit" "origin/$ref" 2>/dev/null || { die "commit $commit is not on $ref"; return 1; }
  git -c advice.detachedHead=false checkout --quiet "$commit" || return 1

  local dir file; dir=$(dirname "$path"); file=$(basename "$path"); cd "$dir" || return 1
  local container=()
  case "$file" in
    project.yml|project.yaml) echo "-- xcodegen"; xcodegen generate --spec "$file" --quiet || return 1
                              container=(-project "$(ls -d ./*.xcodeproj | head -1)") ;;
    *.xcworkspace) container=(-workspace "$file") ;;
    *.xcodeproj)   container=(-project "$file") ;;
    *) die "appstore.path must point to project.yml, .xcodeproj or .xcworkspace"; return 1 ;;
  esac

  local ASC_DIR="$HOME/.appstoreconnect" ASC_ISSUER ASC_KEY_PATH ASC_KEY_ID
  ASC_ISSUER="$(tr -d '[:space:]' < "$ASC_DIR/issue_id.txt")"
  ASC_KEY_PATH="$(ls "$ASC_DIR"/private_keys/AuthKey_*.p8 | head -1)"
  ASC_KEY_ID="$(basename "$ASC_KEY_PATH" .p8 | sed 's/^AuthKey_//')"
  local auth=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH"
              -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER")

  local rc=0 platform scheme
  while read -r platform scheme <&3; do   # fd 3: xcodebuild must not eat the list
    [ -n "$platform" ] || continue
    local dest
    case "$platform" in
      ios) dest='generic/platform=iOS' ;; macos) dest='generic/platform=macOS' ;;
      catalyst) dest='generic/platform=macOS,variant=Mac Catalyst' ;;
    esac
    echo "-- $scheme ($platform)"
    local settings bid team mver localb remoteb build
    settings=$(xcodebuild "${container[@]}" -scheme "$scheme" -configuration Release -destination "$dest" -showBuildSettings 2>/dev/null)
    val() { awk -F' = ' -v k="$1" '$1 ~ "^ *"k"$" {print $2; exit}' <<<"$settings"; }
    bid=$(val PRODUCT_BUNDLE_IDENTIFIER); team=$(val DEVELOPMENT_TEAM); mver=$(val MARKETING_VERSION); localb=$(val CURRENT_PROJECT_VERSION)
    [ -n "$bid" ] && [ -n "$team" ] || { die "no bundle id / team for scheme $scheme"; rc=1; continue; }
    remoteb=$(/usr/bin/python3 "$HOME/.claude/scripts/asc.py" builds --bundle-id "$bid" --limit 50 2>/dev/null \
      | awk '{for (i = 1; i < NF; i++) if ($i == "build") print $(i + 1)}' | sort -n | tail -1)
    build=$(( $( (echo "${remoteb:-0}"; echo "${localb%%.*}") | grep -E '^[0-9]+$' | sort -n | tail -1) + 1 ))
    echo "   bundle $bid  version $mver  build $build (App Store Connect max ${remoteb:-none}, repo ${localb:-none})"

    local out="$tmp/build/$scheme-$platform"; mkdir -p "$out"
    echo "   archive …"
    if ! caffeinate -i xcodebuild "${container[@]}" -scheme "$scheme" -configuration Release -destination "$dest" \
         -archivePath "$out/App.xcarchive" "${auth[@]}" CURRENT_PROJECT_VERSION="$build" archive > "$out/archive.log" 2>&1; then
      grep -E 'error:|\*\* ARCHIVE FAILED' "$out/archive.log" | head -20; tail -5 "$out/archive.log"; rc=1; continue
    fi
    local destination=upload; [ "$dry" = true ] && destination=export
    /usr/bin/plutil -create xml1 "$out/ExportOptions.plist"
    /usr/bin/plutil -insert method -string app-store-connect "$out/ExportOptions.plist"
    /usr/bin/plutil -insert destination -string "$destination" "$out/ExportOptions.plist"
    /usr/bin/plutil -insert signingStyle -string automatic "$out/ExportOptions.plist"
    /usr/bin/plutil -insert teamID -string "$team" "$out/ExportOptions.plist"
    /usr/bin/plutil -insert manageAppVersionAndBuildNumber -bool false "$out/ExportOptions.plist"
    /usr/bin/plutil -insert uploadSymbols -bool true "$out/ExportOptions.plist"
    echo "   export ($destination) …"
    if ! caffeinate -i xcodebuild -exportArchive -archivePath "$out/App.xcarchive" -exportPath "$out/export" \
         -exportOptionsPlist "$out/ExportOptions.plist" "${auth[@]}" > "$out/export.log" 2>&1; then
      grep -E 'error:|\*\* EXPORT FAILED' "$out/export.log" | head -20; tail -5 "$out/export.log"; rc=1; continue
    fi
    if [ "$dry" = true ]; then
      echo "   dry run: exported $(ls "$out/export" | tr '\n' ' '), nothing uploaded"
    else
      echo "   uploaded $bid $mver ($build) — App Store Connect is processing it"
      echo "   check: /usr/bin/python3 ~/.claude/scripts/asc.py builds --bundle-id $bid --limit 3"
    fi
  done 3<<<"$(tail -n +4 <<<"$cfg")"
  return $rc
}

# ---------------------------------------------------------------- worker (LaunchAgent)
worker() {
  local lock="$SPOOL/worker.lock"
  if ! mkdir "$lock" 2>/dev/null; then
    kill -0 "$(cat "$lock/pid" 2>/dev/null)" 2>/dev/null && exit 0
    rm -rf "$lock"; mkdir "$lock" || exit 0
  fi
  echo $$ > "$lock/pid"; trap 'rm -rf "$lock"' EXIT
  local req id
  while req=$(ls "$SPOOL/queue"/*.req 2>/dev/null | head -1) && [ -n "$req" ]; do
    id=$(basename "$req" .req)
    read -r p c d < "$req"; rm -f "$req"
    ( release "$p" "$c" "$d" ) > "$SPOOL/results/$id.log" 2>&1
    echo $? > "$SPOOL/results/$id.rc"
    cp "$SPOOL/results/$id.log" "$LOGS/release-$id-$p.log"
  done
  find "$SPOOL/results" -type f -mtime +7 -delete 2>/dev/null
}

# ---------------------------------------------------------------- ssh entry (forced command)
request() {
  local project commit dry extra
  read -r project commit dry extra <<<"${SSH_ORIGINAL_COMMAND:-}"
  [[ "$project" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || { echo "refused: bad project"; echo "RESULT rc=2"; exit 2; }
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "refused: bad commit"; echo "RESULT rc=2"; exit 2; }
  [[ "$dry" =~ ^(true|false)$ ]] && [ -z "$extra" ] || { echo "refused: usage <project> <commit> <true|false>"; echo "RESULT rc=2"; exit 2; }
  local id; id="$(date +%Y%m%d-%H%M%S)-$$"
  echo "$project $commit $dry" > "$SPOOL/queue/$id.tmp" && mv "$SPOOL/queue/$id.tmp" "$SPOOL/queue/$id.req"
  echo "queued $id; waiting for the release worker (LaunchAgent tech.sp33c.security-pipeline.release)"
  local log="$SPOOL/results/$id.log" rcf="$SPOOL/results/$id.rc" waited=0
  while [ ! -f "$log" ]; do
    sleep 2; waited=$((waited + 2))
    if [ $waited -ge 120 ]; then
      rm -f "$SPOOL/queue/$id.req"
      echo "worker did not pick the request up in 120s: is the Mac logged in? run local/mac-release-setup.sh"
      echo "RESULT rc=3"; exit 3
    fi
  done
  tail -n +1 -f "$log" & local tailpid=$!
  while [ ! -f "$rcf" ] && [ $waited -lt 5400 ]; do sleep 3; waited=$((waited + 3)); done
  sleep 1; kill $tailpid 2>/dev/null
  local rc; rc=$(cat "$rcf" 2>/dev/null || echo 4)
  echo "RESULT rc=$rc"; exit "$rc"
}

case "${1:-}" in
  --worker) worker ;;
  --run)    shift; release "$1" "$2" "${3:-true}"; rc=$?; echo "RESULT rc=$rc"; exit $rc ;;
  "")       [ -n "${SSH_ORIGINAL_COMMAND:-}" ] || { sed -n '2,15p' "$0"; exit 1; }; request ;;
  *)        sed -n '2,15p' "$0"; exit 1 ;;
esac
