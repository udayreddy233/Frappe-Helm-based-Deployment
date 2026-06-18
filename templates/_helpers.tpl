{{/*
Full image reference using digest
*/}}
{{- define "frappe.image" -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- end }}

{{/*
App name — used across all resources
*/}}
{{- define "frappe.appName" -}}
{{ .Values.app.name }}
{{- end }}

{{/*
Deployment name
*/}}
{{- define "frappe.deploymentName" -}}
{{ .Values.app.name }}-all-in-one
{{- end }}

{{/*
Service name
*/}}
{{- define "frappe.serviceName" -}}
{{ .Values.app.name }}-service
{{- end }}

{{/*
HTTPRoute name
*/}}
{{- define "frappe.routeName" -}}
{{ .Values.app.name }}-route
{{- end }}
