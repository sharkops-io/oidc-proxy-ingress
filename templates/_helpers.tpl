{{/*
Common labels applied to all resources.
*/}}
{{- define "oidc-proxy-ingress.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Per-entry proxy resource name. Takes the entry name, returns
"<name>-oauth2-proxy". Used by the Deployment, the Service, and the
Ingress backend so all three agree without repeating the string.
*/}}
{{- define "oidc-proxy-ingress.proxyName" -}}
{{ . }}-oauth2-proxy
{{- end }}
