{{/*
Common labels applied to all resources.
*/}}
{{- define "sim-stack.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: llm-d-sim-stack
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/*
Selector labels for simulator pods — used by InferencePool and Service.
*/}}
{{- define "sim-stack.simulatorLabels" -}}
app: {{ .Release.Name }}
{{- end -}}

{{/*
Selector labels for EPP pods — used by EPP Service.
*/}}
{{- define "sim-stack.eppLabels" -}}
app: {{ .Release.Name }}-epp
{{- end -}}

{{/*
InferencePool name — used by pool CR and EPP --pool-name arg.
*/}}
{{- define "sim-stack.poolName" -}}
{{ .Release.Name }}-pool
{{- end -}}
