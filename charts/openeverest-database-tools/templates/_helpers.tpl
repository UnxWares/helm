{{/*
Expand the name of the chart.
*/}}
{{- define "openeverest-database-tools.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "openeverest-database-tools.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "openeverest-database-tools.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "openeverest-database-tools.labels" -}}
helm.sh/chart: {{ include "openeverest-database-tools.chart" . }}
{{ include "openeverest-database-tools.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "openeverest-database-tools.selectorLabels" -}}
app.kubernetes.io/name: {{ include "openeverest-database-tools.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "openeverest-database-tools.serviceAccountName" -}}
{{- if .Values.rbac.create }}
{{- default (include "openeverest-database-tools.fullname" .) .Values.rbac.serviceAccountName }}
{{- else }}
{{- default "default" .Values.rbac.serviceAccountName }}
{{- end }}
{{- end }}

{{- define "openeverest-database-tools.annotations" -}}

{{- /* Global custom annotations */}}
{{- with .Values.global.annotations }}
{{ toYaml . }}
{{- end }}

{{- /* ArgoCD integration */}}
{{- if .Values.argocd.enabled }}
argocd.argoproj.io/hook: {{ .Values.argocd.hook | default "Sync" | quote }}
argocd.argoproj.io/hook-delete-policy: {{ .Values.argocd.hookDeletePolicy | default "HookSucceeded" | quote }}
argocd.argoproj.io/sync-options: {{ .Values.argocd.syncOptions | default "Replace=true" | quote }}
{{- end }}

{{- end -}}
