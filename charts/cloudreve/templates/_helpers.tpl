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


{{/*
Render an image reference from {repository, tag, digest}.
*/}}
{{- define "cloudreve.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion | toString) -}}
{{- end -}}
{{- end }}

{{/*
Secret holding a complete conf.ini provided by the user (`confini.fromSecret`/`secretName` are the pre-v4 names).
*/}}
{{- define "cloudreve.confiniSecret" -}}
{{- .Values.confini.existingSecret | default (and .Values.confini.fromSecret .Values.confini.secretName) | default "" -}}
{{- end }}

{{/*
Name of the chart-managed secret.
*/}}
{{- define "cloudreve.secretName" -}}
{{- include "cloudreve.fullname" . }}
{{- end }}

{{/*
Session secret: explicit value, else the one already stored in the release secret, else a new random one.
*/}}
{{- define "cloudreve.sessionSecret" -}}
{{- if .Values.cloudreve.sessionSecret -}}
{{- .Values.cloudreve.sessionSecret -}}
{{- else -}}
{{- $secret := lookup "v1" "Secret" (include "cloudreve.namespace" .) (include "cloudreve.secretName" .) -}}
{{- if and $secret (index $secret.data "session-secret") -}}
{{- index $secret.data "session-secret" | b64dec -}}
{{- else -}}
{{- randAlphaNum 64 -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Environment variables feeding the conf.ini template (all secret-backed).
*/}}
{{- define "cloudreve.configEnv" -}}
- name: CR_SESSION_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.cloudreve.existingSecret | default (include "cloudreve.secretName" .) }}
      key: {{ ternary .Values.cloudreve.existingSecretKey "session-secret" (not (empty .Values.cloudreve.existingSecret)) }}
{{- if ne .Values.database.type "sqlite" }}
{{- if .Values.database.existingSecret }}
- name: CR_DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.existingSecret }}
      key: {{ .Values.database.existingSecretKeys.password }}
{{- if .Values.database.existingSecretKeys.url }}
- name: CR_DB_URL
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.existingSecret }}
      key: {{ .Values.database.existingSecretKeys.url }}
{{- end }}
{{- else }}
- name: CR_DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "cloudreve.secretName" . }}
      key: db-password
{{- if .Values.database.url }}
- name: CR_DB_URL
  valueFrom:
    secretKeyRef:
      name: {{ include "cloudreve.secretName" . }}
      key: db-url
{{- end }}
{{- end }}
{{- end }}
{{- if and .Values.redis.enabled (or .Values.redis.password .Values.redis.existingSecret) }}
- name: CR_REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.redis.existingSecret | default (include "cloudreve.secretName" .) }}
      key: {{ ternary .Values.redis.existingSecretKey "redis-password" (not (empty .Values.redis.existingSecret)) }}
{{- end }}
{{- end }}

{{/*
Validate values that would otherwise produce a broken deployment.
*/}}
{{- define "cloudreve.validate" -}}
{{- if not (include "cloudreve.confiniSecret" .) }}
{{- if ne .Values.database.type "sqlite" }}
{{- if and (not .Values.database.url) (not .Values.database.existingSecretKeys.url) (not .Values.database.host) }}
{{- fail "database.host (or database.url) is required when database.type is not sqlite" }}
{{- end }}
{{- if and (not .Values.database.existingSecret) (not .Values.database.password) (not .Values.database.url) }}
{{- fail "database.password or database.existingSecret is required when database.type is not sqlite" }}
{{- end }}
{{- end }}
{{- if and .Values.redis.enabled (not .Values.redis.server) }}
{{- fail "redis.server is required when redis.enabled is true" }}
{{- end }}
{{- end }}
{{- end }}
