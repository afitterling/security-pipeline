#!/usr/bin/env bash
# Port-forward one of the UIs. Nothing in this stack is exposed publicly by default.
set -euo pipefail
case "${1:-}" in
  argocd)
    echo "Argo CD      -> http://localhost:8443   (user admin, password: make argocd-password)"
    exec kubectl -n argocd port-forward svc/argocd-server 8443:80 ;;
  argo)
    echo "Argo Workflows -> http://localhost:2746/workflows/security   (scans are in namespace security)"
    exec kubectl -n argo port-forward svc/argo-workflows-server 2746:2746 ;;
  dtrack)
    echo "Dependency-Track UI -> http://localhost:8080   API -> http://localhost:8081"
    kubectl -n dependency-track port-forward svc/dependency-track-api-server 8081:8080 &
    trap 'kill %1' EXIT
    exec kubectl -n dependency-track port-forward svc/dependency-track-frontend 8080:8080 ;;
  *) echo "usage: scripts/ui.sh argocd|argo|dtrack"; exit 1 ;;
esac
