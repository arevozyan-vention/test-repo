{{- define "bookinfo.labels" -}}
app.kubernetes.io/part-of: bookinfo
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}
