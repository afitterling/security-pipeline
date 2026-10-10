#!/usr/bin/env bash
# Bring the local stack up and keep every UI reachable.
#   scripts/start.sh          # podman VM → kind node → wait for pods → port-forwards (background)
#   scripts/start.sh status   # what runs, which ports answer
#   scripts/start.sh stop     # stop the port-forwards (cluster keeps running)
# Port-forwards run in a restart loop, so they come back by themselves when a pod restarts.
#   Argo CD             http://localhost:8443   admin / make argocd-password
#   Argo Workflows      http://localhost:2746
#   Dependency-Track    http://localhost:8080   (API http://localhost:8081)
# Logs: ~/Library/Logs/security-pipeline/forward-*.log. Details: docs/access.md
set -euo pipefail
cd "$(dirname "$0")/.."
NODE=security-pipeline-control-plane
LOGS="$HOME/Library/Logs/security-pipeline"
RUN="$HOME/Library/Application Support/security-pipeline/forwards"
mkdir -p "$LOGS" "$RUN"

# name  namespace  service  local:remote
FORWARDS="argocd argocd svc/argocd-server 8443:80
argo argo svc/argo-workflows-server 2746:2746
dtrack-api dependency-track svc/dependency-track-api-server 8081:8080
dtrack-ui dependency-track svc/dependency-track-frontend 8080:8080"

stop_forwards() {
  for f in "$RUN"/*.pid; do
    [ -f "$f" ] || continue
    pid=$(cat "$f"); pkill -P "$pid" 2>/dev/null || true; kill "$pid" 2>/dev/null || true; rm -f "$f"
  done
  # forwards started by hand (make ui-*, scripts/ui.sh) on the same ports
  for p in 8443 2746 8080 8081; do
    for pid in $(lsof -nP -tiTCP:$p -sTCP:LISTEN -c kubectl 2>/dev/null); do kill "$pid" 2>/dev/null || true; done
  done
}

status() {
  echo "podman VM : $(podman machine inspect --format '{{.State}}' 2>/dev/null || echo '?')"
  echo "kind node : $(podman inspect -f '{{.State.Status}}' $NODE 2>/dev/null || echo missing)"
  echo "API server: $(kubectl get --request-timeout=10s --raw /readyz 2>/dev/null || echo 'not ready')"
  echo
  printf '%-16s %-28s %s\n' UI URL ANSWER
  for u in "Argo CD|http://localhost:8443" "Argo Workflows|http://localhost:2746" \
           "D-Track UI|http://localhost:8080" "D-Track API|http://localhost:8081/api/version"; do
    code=$(curl -s -m3 -o /dev/null -w '%{http_code}' "${u#*|}" || true)
    printf '%-16s %-28s %s\n' "${u%%|*}" "${u#*|}" "$([ "$code" = 000 ] && echo down || echo "$code")"
  done
}

case "${1:-start}" in
  stop)   stop_forwards; echo "port-forwards stopped"; exit 0 ;;
  status) status; exit 0 ;;
  start)  ;;
  *)      sed -n '2,11p' "$0"; exit 1 ;;
esac

# ---- 1. podman VM + kind node
if [ "$(podman machine inspect --format '{{.State}}' 2>/dev/null)" != running ]; then
  echo "starting podman machine …"; podman machine start >/dev/null
fi
state=$(podman inspect -f '{{.State.Status}}' $NODE 2>/dev/null || echo missing)
if [ "$state" = missing ]; then echo "no kind cluster: run local/up.sh"; exit 1; fi
[ "$state" = running ] || { echo "starting kind node …"; podman start $NODE >/dev/null; }
kubectl config use-context kind-security-pipeline >/dev/null

# ---- 2. API server + the pods behind the UIs
printf 'waiting for the API server '
for i in $(seq 1 60); do kubectl get --request-timeout=5s --raw /readyz >/dev/null 2>&1 && break; printf .; sleep 3; done; echo
for d in "argocd deploy/argocd-server" "argocd deploy/argocd-repo-server" "argo deploy/argo-workflows-server" \
         "argo deploy/argo-workflows-workflow-controller" "dependency-track deploy/dependency-track-frontend" \
         "dependency-track sts/dependency-track-api-server"; do
  set -- $d
  kubectl -n "$1" rollout status "$2" --timeout=300s >/dev/null 2>&1 && echo "ready     $1/$2" || echo "NOT READY $1/$2 (kubectl -n $1 describe $2)"
done

# ---- 3. port-forwards, each in a restart loop
stop_forwards
while read -r name ns svc ports; do
  ( while true; do
      kubectl -n "$ns" port-forward "$svc" "$ports" >>"$LOGS/forward-$name.log" 2>&1 || true
      sleep 2   # pod restarted or API hiccup: reconnect
    done ) </dev/null >/dev/null 2>&1 &
  echo $! > "$RUN/$name.pid"
done <<<"$FORWARDS"
disown -a 2>/dev/null || true
sleep 4
echo
status
echo
echo "Argo CD password: make argocd-password      stop forwards: scripts/start.sh stop"
