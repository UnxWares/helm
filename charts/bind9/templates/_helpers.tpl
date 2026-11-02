{{/*
Expand the name of the chart.
*/}}
{{- define "bind9.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "bind9.fullname" -}}
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
{{- define "bind9.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "bind9.labels" -}}
helm.sh/chart: {{ include "bind9.chart" . }}
{{ include "bind9.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "bind9.selectorLabels" -}}
app.kubernetes.io/name: {{ include "bind9.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "bind9.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "bind9.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Render an image reference from {repository, tag, digest}.
*/}}
{{- define "bind9.image" -}}
{{- if .image.digest -}}
{{- printf "%s@%s" .image.repository .image.digest -}}
{{- else -}}
{{- printf "%s:%s" .image.repository (.image.tag | default .default | toString) -}}
{{- end -}}
{{- end }}

{{/*
Exporter image: an empty repository follows imageProvider, and so does an empty tag (the two images have
different tags).
*/}}
{{- define "bind9.exporterImage" -}}
{{- $unxwares := eq .Values.imageProvider "unxwares" -}}
{{- $image := dict
  "repository" (.Values.metrics.image.repository | default (ternary "ghcr.io/unxwares/bind-exporter" "docker.io/prometheuscommunity/bind-exporter" $unxwares))
  "tag" .Values.metrics.image.tag
  "digest" .Values.metrics.image.digest -}}
{{- include "bind9.image" (dict "image" $image "default" (ternary "0.8.0-62-gbafd56f" "master@sha256:a1f46e6abf8d284a158a1ba0e3275bc2e17f9119ec227f18bdb20019d24b3bcf" $unxwares)) -}}
{{- end }}

{{/*
Name of the Service carrying the rndc and metrics ports.
*/}}
{{- define "bind9.adminServiceName" -}}
{{- printf "%s-admin" (include "bind9.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
