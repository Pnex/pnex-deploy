{{- define "pnex-runner.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}
{{- end -}}
{{- end -}}

{{- define "pnex-runner.joinSecret" -}}
{{- .Values.joinToken.existingSecret | default (printf "%s-join" .Release.Name) -}}
{{- end -}}
