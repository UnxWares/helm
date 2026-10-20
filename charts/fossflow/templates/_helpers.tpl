{{/*
Expand the name of the chart.
*/}}
{{- define "fossflow.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "fossflow.fullname" -}}
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
{{- define "fossflow.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "fossflow.labels" -}}
helm.sh/chart: {{ include "fossflow.chart" . }}
{{ include "fossflow.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "fossflow.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fossflow.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "fossflow.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "fossflow.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image reference (digest takes precedence over the tag).
*/}}
{{- define "fossflow.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion | toString) -}}
{{- end -}}
{{- end }}

{{/*
Validate values that would otherwise produce a broken deployment.
*/}}
{{- define "fossflow.validate" -}}
{{- if and .Values.storage.enabled .Values.persistence.enabled (has "ReadWriteOnce" .Values.persistence.accessModes) (or (gt (int .Values.replicaCount) 1) .Values.autoscaling.enabled) }}
{{- fail "server storage on a ReadWriteOnce volume supports a single replica: use a ReadWriteMany volume or disable storage to scale" }}
{{- end }}
{{- end }}
