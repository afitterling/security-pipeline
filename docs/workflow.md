# Scan workflow (Argo Workflows)

What one run of the `security-scan` WorkflowTemplate does, which tool runs in each step and in which
image. Source of truth: `charts/security-scans/templates/workflowtemplate.yaml`; detection logic in
`charts/security-scans/files/detect.js`. Every entry in `projects.yaml` becomes one CronWorkflow
(`scan-<name>`) that references this template, so the DAG below is identical for every repo.

## Per-repo scan DAG

```mermaid
flowchart TD
    cron([CronWorkflow scan-&lt;project&gt;<br/>default 03:00 Europe/Berlin, staggered]) --> clone

    subgraph source["Source"]
        clone["clone<br/><b>git clone --depth 1</b><br/><i>alpine/git</i>"]
        detect["detect<br/><b>node detect.js → plan.json</b><br/>sst / npm / python / terraform / swift<br/><i>node:22-bookworm</i>"]
    end

    subgraph parallel["Fan-out — runs in parallel after clone"]
        build["build-test<br/><b>install → build → test</b><br/>from plan.json<br/><i>node:22-bookworm</i>"]
        sbom["sbom<br/><b>syft scan dir:</b><br/>CycloneDX + SPDX<br/><i>anchore/syft</i>"]
        upload["upload-bom<br/><b>curl POST /api/v1/bom</b><br/><i>curlimages/curl</i>"]
        dpol["dtrack-policy<br/><b>wait for analysis → policy violations + EPSS</b><br/>dtrack-policy.json, epss.json<br/><i>alpine/k8s</i>"]
        trivy["trivy<br/><b>trivy fs</b> vuln, secret, misconfig<br/>json + sarif<br/><i>aquasec/trivy</i>"]
        gitleaks["gitleaks<br/><b>gitleaks detect --no-git</b><br/><i>zricethezav/gitleaks</i>"]
        semgrep["semgrep (optional)<br/><b>semgrep scan</b> p/default, p/secrets<br/>json + sarif<br/><i>semgrep/semgrep</i>"]
    end

    subgraph gatebox["Gate"]
        gate{"gate<br/><b>jq</b> over trivy, gitleaks, semgrep, dtrack-policy, epss<br/>→ summary.json<br/>fail if critical &gt; gate-critical, high &gt; gate-high,<br/>any gitleaks hit or a FAIL policy violation (gate-policy=block)<br/><i>alpine/k8s</i>"}
    end

    subgraph deploybox["Deploy — ServiceAccount security-deploy"]
        rc["release-candidate<br/><b>ConfigMap release-candidate-&lt;project&gt;</b><br/>when testflight (tag appleapp + appstore block)<br/>SA security-release<br/><i>alpine/k8s</i>"]
        deploy["deploy<br/><b>plan.deploy</b> e.g. npx sst deploy --stage &lt;stage&gt;<br/>IRSA deployer role (EKS) or mounted ~/.aws (local)<br/><i>node:22-bookworm</i>"]
    end

    subgraph finish["Reports"]
        archive["archive<br/>/work/out → artifact repository<br/><i>curlimages/curl</i>"]
        verdict{"verdict<br/>gate Succeeded? else exit 1<br/><i>alpine/k8s</i>"}
    end

    clone --> detect --> build
    clone --> sbom --> upload --> dpol
    clone --> trivy
    clone --> gitleaks
    clone -. "semgrep == true" .-> semgrep

    build --> gate
    dpol --> gate
    trivy --> gate
    gitleaks --> gate
    semgrep -. "Succeeded, Skipped or Failed" .-> gate

    gate -- "Succeeded and<br/>detect.deploy-enabled == true" --> deploy
    gate -- "Succeeded and<br/>testflight == true" --> rc
    rc --> archive
    gate -. "Failed" .-> archive
    deploy -- "Succeeded / Failed / Skipped / Omitted" --> archive
    archive --> verdict

    dtrack[(Dependency-Track<br/>project &lt;name&gt; / &lt;version&gt;)]
    s3[(S3 reports bucket<br/>RustFS in local mode)]
    secrets[/"Secrets: git-credentials, dtrack-api<br/>(ESO ← Secrets Manager, plain secrets locally)"/]

    upload --> dtrack
    dtrack -. "violations, EPSS" .-> dpol
    archive --> s3
    secrets -.-> clone
    secrets -.-> upload

    classDef scan fill:#fff3cd,stroke:#b8860b,color:#000
    classDef build fill:#dbeafe,stroke:#1d4ed8,color:#000
    classDef gate fill:#fde2e2,stroke:#b91c1c,color:#000
    classDef deploy fill:#dcfce7,stroke:#15803d,color:#000
    classDef ext fill:#f3f4f6,stroke:#6b7280,color:#000
    class sbom,trivy,gitleaks,semgrep,upload,dpol scan
    class clone,detect,build build
    class gate,verdict gate
    class deploy,rc deploy
    class archive,dtrack,s3,secrets,cron ext
```

### Tools and images per step

| Step | Tool / command | Image (`values.yaml` → `images.*`) | ServiceAccount |
|---|---|---|---|
| clone | `git clone --depth 1 --branch <ref>` | `git` (alpine/git) | security-scan |
| detect | `node /detect/detect.js` → `plan.json`, `deploy-enabled.txt` | `runner` (node:22-bookworm) | security-scan |
| build-test | `plan.install`, `plan.build`, `plan.test` (npm ci / pip / terraform validate …) | `runner` | security-scan |
| sbom | `syft scan dir:/work/src` → CycloneDX + SPDX | `syft` | security-scan |
| upload-bom | `curl POST $DTRACK_URL/api/v1/bom` (autoCreate) | `curl` | security-scan |
| dtrack-policy | poll `/api/v1/event/token`, read `/violation/project` + `/finding/project` → `dtrack-policy.json`, `epss.json` | `k8s` | security-scan |
| trivy | `trivy fs --scanners vuln,secret,misconfig` (json + sarif) | `trivy` | security-scan |
| gitleaks | `gitleaks detect --no-git --redact` | `gitleaks` | security-scan |
| semgrep | `semgrep scan --config p/default --config p/secrets` (json + sarif) | `semgrep` | security-scan |
| gate | `jq` over the scanner output → `summary.json`, exit 1 on threshold breach | `k8s` (alpine/k8s) | security-scan |
| release-candidate | `kubectl apply` ConfigMap `release-candidate-<project>` (commit, summary) | `k8s` | **security-release** |
| deploy | `plan.deploy`, e.g. `npx sst deploy --stage <stage>` | `runner` | **security-deploy** |
| archive | collects `/work/out` as the `reports` artifact | `curl` | security-scan |
| verdict | fails the workflow when the gate did not succeed | `k8s` | security-scan |

All steps share one `work` PVC (`defaults.workspaceSize`, 10Gi); scanner output lands in `/work/out`.

### Why `verdict` exists

`archive` depends on `gate.Failed` so reports are stored even when the gate blocks. Argo then treats
the failed gate as expected and would mark the workflow *Succeeded*. `verdict` reads `tasks.gate.status`
and exits non-zero when it is not `Succeeded`, so a blocked run shows up red.

## Upload to TestFlight (manual, `upload-to-testflight` WorkflowTemplate, local mode)

```mermaid
flowchart LR
    you([you: scripts/release.sh &lt;name&gt; or Argo UI Submit]) --> check
    check{"check<br/>tag appleapp + appstore block (from git)<br/>ConfigMap release-candidate-&lt;name&gt;<br/>exists, &lt; 7 days, 40-hex commit"} --> ssh
    ssh["build-upload<br/><b>ssh mac-release@192.168.127.254</b><br/>&quot;&lt;name&gt; &lt;commit&gt; &lt;dry-run&gt;&quot;<br/><i>alpine/git</i>"]
    subgraph mac["Mac (host)"]
        fc["local/mac-release.sh<br/>forced command: validate + queue"]
        worker["LaunchAgent worker (GUI session)<br/>projects.yaml → tag appleapp, repo, path, schemes<br/>clone @ commit (must be on ref)<br/>xcodegen → xcodebuild archive<br/>build = ASC max + 1<br/>exportArchive destination=upload"]
        key[/"~/.appstoreconnect<br/>(never leaves the Mac)"/]
    end
    ssh --> fc --> worker
    key -.-> worker
    worker --> asc[(App Store Connect<br/>TestFlight)]
```

The cluster SSH key is pinned in `authorized_keys` with `restrict,command="…/mac-release.sh",from="127.0.0.1,::1"`,
so it can start a release of a configured, enabled app and nothing else.

## Runtime sync (hourly, `runtime-sync` CronWorkflow)

Independent of the per-repo scans. Reads what Trivy Operator and Gatekeeper already produced in the
cluster and pushes it to the same sinks.

```mermaid
flowchart LR
    cron([CronWorkflow runtime-sync<br/>30 * * * *]) --> sync

    subgraph cluster["In-cluster sources (read via kubectl, ClusterRole runtime-reader)"]
        sbomr[sbomreports<br/>Trivy Operator]
        vulnr[vulnerabilityreports<br/>Trivy Operator]
        gk[constraints<br/>Gatekeeper audit]
    end

    sync["sync<br/><b>kubectl + jq + curl</b><br/><i>alpine/k8s</i>"]

    sbomr --> sync
    vulnr --> sync
    gk --> sync

    sync -- "POST /api/v1/bom per image<br/>project runtime/&lt;image&gt;" --> dtrack[(Dependency-Track)]
    sync -- "runtime-vulns.json<br/>runtime-policy.json<br/>summary.json" --> s3[(reports bucket)]
    sync -. "runtime.gate.critical set and<br/>an image exceeds it" .-> fail{{exit 1}}

    classDef ext fill:#f3f4f6,stroke:#6b7280,color:#000
    class dtrack,s3,cron ext
```

## How a run is created

```mermaid
flowchart LR
    py[projects.yaml] --> argocd[Argo CD<br/>security-scans Application]
    argocd -- "helm: one CronWorkflow per entry" --> cw[CronWorkflow scan-&lt;name&gt;]
    cw -- "workflowTemplateRef + parameters<br/>(repo, ref, gate, deploy, commands)" --> wt[WorkflowTemplate security-scan]
    wt --> wf[Workflow run]
    run[scripts/run-scans.sh] -. "argo submit --from" .-> wf
```

Parameter precedence inside `detect`: auto-detection < `.security-pipeline.json` in the repo <
`commands:` in `projects.yaml`.
