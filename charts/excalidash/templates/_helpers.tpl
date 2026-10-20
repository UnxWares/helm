{{/*
Expand the name of the chart.
*/}}
{{- define "excalidash.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "excalidash.fullname" -}}
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
{{- define "excalidash.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "excalidash.labels" -}}
helm.sh/chart: {{ include "excalidash.chart" . }}
{{ include "excalidash.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "excalidash.selectorLabels" -}}
app.kubernetes.io/name: {{ include "excalidash.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "excalidash.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "excalidash.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Full name of the backend resources
*/}}
{{- define "excalidash.backend.fullname" -}}
{{ include "excalidash.fullname" . }}-backend
{{- end }}

{{/*
Selector labels for the backend
*/}}
{{- define "excalidash.backend.selectorLabels" -}}
app.kubernetes.io/name: {{ include "excalidash.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: backend
{{- end }}

{{/*
Full name of the frontend resources
*/}}
{{- define "excalidash.frontend.fullname" -}}
{{ include "excalidash.fullname" . }}-frontend
{{- end }}

{{/*
Selector labels for the frontend
*/}}
{{- define "excalidash.frontend.selectorLabels" -}}
app.kubernetes.io/name: {{ include "excalidash.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: frontend
{{- end }}

{{/*
Render an image reference from {repository, tag, digest}.
*/}}
{{- define "excalidash.image" -}}
{{- if .image.digest -}}
{{- printf "%s@%s" .image.repository .image.digest -}}
{{- else -}}
{{- printf "%s:%s" .image.repository (.image.tag | default .default | toString) -}}
{{- end -}}
{{- end }}

{{/*
Name of the chart-managed secret.
*/}}
{{- define "excalidash.secretName" -}}
{{- include "excalidash.fullname" . }}
{{- end }}

{{/*
Value of a generated secret key: explicit value, else the value already stored in the release secret, else random.
Usage: include "excalidash.generatedSecret" (dict "ctx" $ "key" "jwt-secret" "value" .Values.backend.secrets.jwtSecret "length" 64)
*/}}
{{- define "excalidash.generatedSecret" -}}
{{- if .value -}}
{{- .value -}}
{{- else -}}
{{- $secret := lookup "v1" "Secret" .ctx.Release.Namespace (include "excalidash.secretName" .ctx) -}}
{{- if and $secret (index $secret.data .key) -}}
{{- index $secret.data .key | b64dec -}}
{{- else -}}
{{- randAlphaNum (int .length) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Validate values that would otherwise produce a broken deployment.
*/}}
{{- define "excalidash.validate" -}}
{{- if or (gt (int .Values.backend.replicaCount) 1) .Values.backend.autoscaling.enabled }}
{{- fail "the ExcaliDash backend keeps Socket.IO state in memory: backend.replicaCount must be 1 and backend.autoscaling.enabled false" }}
{{- end }}
{{- if and (eq .Values.backend.database.provider "postgresql") (not .Values.backend.database.existingSecret) (not (hasPrefix "postgres" .Values.backend.database.url)) }}
{{- fail "backend.database.provider=postgresql needs a postgresql:// backend.database.url or backend.database.existingSecret" }}
{{- end }}
{{- if and (has .Values.backend.auth.mode (list "hybrid" "oidc_enforced")) (not .Values.backend.auth.oidc.issuerUrl) }}
{{- fail "backend.auth.oidc.issuerUrl and clientId are required with backend.auth.mode hybrid or oidc_enforced" }}
{{- end }}
{{- end }}
