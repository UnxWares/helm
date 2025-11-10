{{/*
Expand the name of the chart.
*/}}
{{- define "cloudreve.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "cloudreve.fullname" -}}
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
{{- define "cloudreve.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "cloudreve.labels" -}}
helm.sh/chart: {{ include "cloudreve.chart" . }}
{{ include "cloudreve.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "cloudreve.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cloudreve.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "cloudreve.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "cloudreve.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}


{{/*
Allow the release namespace to be overridden for multi-namespace deployments in combined charts
*/}}
{{- define "cloudreve.namespace" -}}
{{- if .Values.namespaceOverride }}
{{- .Values.namespaceOverride }}
{{- else }}
{{- .Release.Namespace }}
{{- end }}
{{- end }}

{{/* Return the database secret name */}}
{{- define "cloudreve.database.secretName" -}}
{{- if .Values.database.existingSecret -}}
  {{- printf "%s" (tpl .Values.database.existingSecret $) -}}
{{- else -}}
  {{- printf "%s-db" (include "cloudreve.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/* Return the key for the username */}}
{{- define "cloudreve.database.usernameKey" -}}
{{- if .Values.database.existingSecretKeys.user -}}
  {{- printf "%s" (tpl .Values.database.existingSecretKeys.user $) -}}
{{- else -}}
  {{- "user" -}}
{{- end -}}
{{- end -}}

{{/* Return the key for the password */}}
{{- define "cloudreve.database.passwordKey" -}}
{{- if .Values.database.existingSecretKeys.password -}}
  {{- printf "%s" (tpl .Values.database.existingSecretKeys.password $) -}}
{{- else -}}
  {{- "password" -}}
{{- end -}}
{{- end -}}

{{/* Return the username value, reading from secret if exists */}}
{{- define "cloudreve.database.username" -}}
{{- $secret := lookup "v1" "Secret" .Release.Namespace (include "cloudreve.database.secretName" .) -}}
{{- if $secret -}}
  {{- $value := index $secret.data (include "cloudreve.database.usernameKey" .) | b64dec -}}
  {{- $value -}}
{{- else -}}
  {{- .Values.database.user -}}
{{- end -}}
{{- end -}}

{{/* Return the password value, reading from secret if exists */}}
{{- define "cloudreve.database.password" -}}
{{- $secret := lookup "v1" "Secret" .Release.Namespace (include "cloudreve.database.secretName" .) -}}
{{- if $secret -}}
  {{- $value := index $secret.data (include "cloudreve.database.passwordKey" .) | b64dec -}}
  {{- $value -}}
{{- else -}}
  {{- .Values.database.password -}}
{{- end -}}
{{- end -}}
