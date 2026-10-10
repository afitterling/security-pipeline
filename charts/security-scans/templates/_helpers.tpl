{{/* Merge per-project overrides onto defaults */}}
{{- define "scans.project" -}}
{{- $d := .defaults -}}
{{- $p := .project -}}
{{- $gate := merge (deepCopy ($p.gate | default dict)) $d.gate -}}
{{- $deploy := merge (deepCopy ($p.deploy | default dict)) $d.deploy -}}
{{- $out := dict
  "name" (required "project.name is required" $p.name)
  "repo" (required (printf "project %s: repo is required" $p.name) $p.repo)
  "ref" ($p.ref | default $d.ref)
  "version" ($p.version | default ($p.ref | default $d.ref))
  "schedule" ($p.schedule | default $d.schedule)
  "enabled" (ternary $p.enabled $d.enabled (hasKey $p "enabled"))
  "semgrep" (ternary $p.semgrep $d.semgrep (hasKey $p "semgrep"))
  "gate" $gate
  "deploy" $deploy
  "commands" ($p.commands | default dict)
-}}
{{- $out | toJson -}}
{{- end -}}
