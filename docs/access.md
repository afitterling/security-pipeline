# Ports and access (local mode)

Nothing in the cluster is exposed publicly. Every UI is reached through a `kubectl port-forward`.

```bash
scripts/start.sh          # or: make start — VM + kind node up, wait for pods, all forwards in the background
scripts/start.sh status   # VM / node / API server state and which URL answers
scripts/start.sh stop     # or: make stop — stop the forwards (cluster keeps running)
```

`start.sh` keeps each forward in a restart loop, so the UIs come back by themselves after a pod
restart (logs: `~/Library/Logs/security-pipeline/forward-*.log`). `make ui-argocd|ui-argo|ui-dtrack`
still start a single forward in the foreground; those stop when their pod restarts.

| What | URL on your Mac | Start with | Login | In-cluster service |
|---|---|---|---|---|
| **Argo CD** (GitOps: syncs this repo) | http://localhost:8443 | `make start` or `make ui-argocd` | `admin` / `make argocd-password` | `argocd-server.argocd:80` |
| **Argo Workflows** (scan runs, logs, history) | http://localhost:2746/workflows/security | `make start` or `make ui-argo` | none (server auth mode) | `argo-workflows-server.argo:2746` |
| **Dependency-Track UI** | http://localhost:8080 | `make start` or `make ui-dtrack` | `admin` / the password you set | `dependency-track-frontend.dependency-track:8080` |
| **Dependency-Track API** | http://localhost:8081 | same as the UI (one command starts both) | API key (`security/dtrack-api`) | `dependency-track-api-server.dependency-track:8080` |
| RustFS console (reports bucket) | http://localhost:9001 | `kubectl -n minio port-forward svc/rustfs-console 9001:9001` | `pipeline` / secret `minio/minio-credentials` | `rustfs.minio:9000` (S3 API) |

Notes
- Argo Workflows: the scans live in namespace **`security`**. The UI opens on another namespace and
  then looks empty; use http://localhost:2746/workflows/security (cron schedules:
  http://localhost:2746/cron-workflows/security, templates: http://localhost:2746/workflow-templates/security)
  or set the namespace filter to `security`.
- Argo CD listens on plain HTTP behind the forward (`server.insecure=true`), despite the port number 8443.
- The Dependency-Track UI calls the API from your browser at http://localhost:8081, so the API forward
  must be running too; `make ui-dtrack` starts both.
- Scripts that need the API (`scripts/status.sh`, `scripts/dtrack-tags.sh`, `scripts/dtrack-bootstrap.sh`)
  open their own temporary forward on 18081-18083, so they work without `make ui-dtrack`.
- App Store releases: pods reach the Mac's SSH server at `192.168.127.254:22` (podman gvproxy), see
  [workflow.md](workflow.md#upload-to-testflight-manual-upload-to-testflight-workflowtemplate-local-mode).

## Dependency-Track project tags

Every project is tagged from `projects.yaml`: `public` or `private` (field `visibility`, looked up on
GitHub by `scripts/add-projects.sh`) plus anything in `tags: [...]`. The scan sets them on each run
(`dtrack-policy` step); `scripts/dtrack-tags.sh [names]` applies them immediately. Tags added in the
UI are kept. Filter in the UI: Projects → Tags column, or click a tag.
