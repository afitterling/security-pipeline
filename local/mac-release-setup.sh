#!/bin/bash
# One-time setup on the Mac for App Store releases from the pipeline (local mode).
#   1. SSH key ~/.ssh/security-pipeline-release, allowed ONLY to run local/mac-release.sh
#      (authorized_keys: restrict + command= + from=localhost; asks before writing)
#   2. LaunchAgent tech.sp33c.security-pipeline.release: the worker that builds in your GUI
#      session (keychain for signing, gh for cloning)
#   3. Cluster: secret security/mac-release-ssh (key + pinned host key), Mac user in the root app
# Needs Remote Login (System Settings → General → Sharing → Remote Login, or
# `sudo systemsetup -setremotelogin on`). Undo: delete the authorized_keys line + the LaunchAgent.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
KEY="$HOME/.ssh/security-pipeline-release"
HOST_IP=${MAC_HOST:-192.168.127.254}     # how pods reach the Mac (podman gvproxy)
LABEL=tech.sp33c.security-pipeline.release
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SPOOL="$HOME/Library/Application Support/security-pipeline/release"

# ---- 1. key + authorized_keys
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -C "security-pipeline-release" -f "$KEY"
pub=$(cut -d' ' -f1,2 "$KEY.pub")
line="restrict,command=\"$ROOT/local/mac-release.sh\",from=\"127.0.0.1,::1\" $pub security-pipeline-release"
touch "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"
if grep -qF "$pub" "$HOME/.ssh/authorized_keys"; then
  echo "authorized_keys: key already present"
else
  echo "This line goes into ~/.ssh/authorized_keys (the key can run nothing but mac-release.sh):"
  echo "  $line"
  read -r -p "Add it? [y/N] " ans
  [ "${ans:-n}" = y ] || { echo "aborted"; exit 1; }
  echo "$line" >> "$HOME/.ssh/authorized_keys"
  echo "authorized_keys: added"
fi

# ---- 2. LaunchAgent worker
mkdir -p "$SPOOL/queue" "$HOME/Library/Logs/security-pipeline" "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$ROOT/local/mac-release.sh</string><string>--worker</string>
  </array>
  <key>WatchPaths</key><array><string>$SPOOL/queue</string></array>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/security-pipeline/worker.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/security-pipeline/worker.log</string>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "LaunchAgent $LABEL loaded"

# ---- 3. cluster secret + Mac user
if ! nc -z -w 2 127.0.0.1 22 2>/dev/null; then
  echo
  echo "Remote Login is OFF. Turn it on: System Settings → General → Sharing → Remote Login"
  echo "(or: sudo systemsetup -setremotelogin on), limited to your user, then rerun this script."
  exit 1
fi
known=$(mktemp); trap 'rm -f "$known"' EXIT
awk -v h="$HOST_IP" '{print h, $1, $2}' /etc/ssh/ssh_host_ed25519_key.pub > "$known"
kubectl -n security create secret generic mac-release-ssh --dry-run=client -o yaml \
  --from-file=id_ed25519="$KEY" --from-file=known_hosts="$known" | kubectl apply -f - >/dev/null
echo "secret security/mac-release-ssh written"
helm upgrade security-pipeline-root argocd/bootstrap -n argocd --reuse-values \
  --set local.mac.host="$HOST_IP" --set local.mac.user="$USER" >/dev/null
echo "root app: appstore.macUser=$USER macHost=$HOST_IP (Argo CD re-syncs security-scans)"
echo
echo "Next: an app tagged appleapp with an appstore: block in projects.yaml: scan it (gate must pass),"
echo "then: scripts/release.sh <name> --dry-run"
