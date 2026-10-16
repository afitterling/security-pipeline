# Where the data lives (local mode)

A restart of the Mac (or `podman machine stop/start`) keeps all scan data. Everything sits on the
podman VM disk (60 GB), which a reboot does not touch: the kind node keeps its whole `/var` on a
podman volume, and every PVC (local-path provisioner) plus the cluster's etcd live under it.

| Data | Stored in | Kept |
|---|---|---|
| Dependency-Track: projects, SBOMs, findings, policies, tags, API key, admin password | PVC `dependency-track/data-dependency-track-api-server-0` (embedded H2) | until deleted |
| Reports: `summary.json`, `epss.json`, `dtrack-policy.json`, SBOMs | PVC `minio/rustfs-data`, bucket `reports` | until deleted |
| Workflow runs (Argo UI history, logs) | etcd | 7 days after completion (`ttlStrategy`), at most 5 passed / 10 failed per project |
| CronWorkflows, WorkflowTemplates, secrets, `release-candidate-*` ConfigMaps | etcd | until deleted (Argo CD recreates the chart objects) |
| Scan work volume (source checkout, tool caches) | PVC `security/scan-…-work` | deleted when the run ends (`volumeClaimGC`) |

## After a reboot

The kind node container has no restart policy, so the cluster does not come back on its own:

```bash
make start      # podman VM + kind node up, wait for the pods, UI port-forwards (see access.md)
```

- A scan running at shutdown is aborted; a running `scripts/run-scans.sh --all` loop (it runs on the
  Mac) stops too. Start it again; already scanned projects are simply scanned again.
- Missed cron runs are started late if the cluster is back within an hour of the schedule
  (`startingDeadlineSeconds: 3600`); otherwise the project waits for its next schedule.

## What deletes the data

- `local/down.sh` / `make local-down` (`kind delete cluster`), the "destroy first" step before a fresh `local/up.sh`
- `podman machine rm` or `podman system reset`
- deleting the Dependency-Track or RustFS PVCs, or their namespaces

There is no backup: the VM disk is the only copy. To keep a copy before a destroy, export what you
need first (Dependency-Track: per project *Export BOM* / the API; reports: copy the `reports` bucket
from the RustFS console, http://localhost:9001).
