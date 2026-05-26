{{- define "app.name" -}}
{{ .Chart.Name }}
{{- end }}

{{- define "app.fullname" -}}
{{ .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
