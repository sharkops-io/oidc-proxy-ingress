{{/*
Common labels applied to all resources.

app.kubernetes.io/component is fixed (not configurable) on purpose: its
value is its stability. It is what NetworkPolicies protecting the upstreams
(Prometheus, Alertmanager, Longhorn's frontend) match against in their
podSelector, so it must never change under a consumer's feet. See the
README's "NetworkPolicy prerequisite" section.
*/}}
{{- define "oidc-proxy-ingress.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: oauth2-proxy
{{- end }}

{{/*
Per-entry proxy resource name. Takes the entry name, returns
"<name>-oauth2-proxy". Used by the Deployment, the Service, and the
Ingress backend so all three agree without repeating the string.

Truncated to 63 chars (the Kubernetes resource name limit) with any
trailing "-" trimmed, so an entry name close to that limit doesn't produce
an invalid name once "-oauth2-proxy" is appended.
*/}}
{{- define "oidc-proxy-ingress.proxyName" -}}
{{- printf "%s-oauth2-proxy" . | trunc 63 | trimSuffix "-" -}}
{{- end }}
