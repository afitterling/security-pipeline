{{/* Merge per-project overrides onto defaults */}}
{{- define "scans.project" -}}
{{- $d := .defaults -}}
{{- $p := .project -}}
{{- $gate := merge (deepCopy ($p.gate | default dict)) $d.gate -}}
{{- $deploy := merge (deepCopy ($p.deploy | default dict)) $d.deploy -}}
{{- $appstore := merge (deepCopy ($p.appstore | default dict)) $d.appstore -}}
{{- $tags := list -}}
{{- with $p.visibility }}{{ $tags = append $tags (. | lower) }}{{ end -}}
{{- range ($p.tags | default list) }}{{ $tags = append $tags (. | toString | lower) }}{{ end -}}
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
  "appstore" $appstore
  "tags" ($tags | uniq)
  "commands" ($p.commands | default dict)
-}}
{{- $out | toJson -}}
{{- end -}}
