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
Repository of the named image: an empty image.repository follows imageProvider.
*/}}
{{- define "bind9.namedRepository" -}}
{{- .Values.image.repository | default (ternary "ghcr.io/unxwares/bind9" "docker.io/internetsystemsconsortium/bind9" (eq .Values.imageProvider "unxwares")) -}}
{{- end }}

{{/*
"true" when named runs the ISC image (a repository ending in internetsystemsconsortium/bind9, a mirror included):
it is tagged with the BIND branch only and published for linux/amd64 only.
*/}}
{{- define "bind9.iscImage" -}}
{{- hasSuffix "internetsystemsconsortium/bind9" (include "bind9.namedRepository" .) -}}
{{- end }}

{{/*
named image (also used by the helm test pod). An empty tag follows the image: the UnxWares image is tagged with the
BIND release (the chart appVersion, 9.20.30), the ISC image with its branch (9.20), which ISC moves to each patch
release.
*/}}
{{- define "bind9.namedImage" -}}
{{- $version := .Chart.AppVersion | toString -}}
{{- $image := dict "repository" (include "bind9.namedRepository" .) "tag" .Values.image.tag "digest" .Values.image.digest -}}
{{- include "bind9.image" (dict "image" $image "default" (ternary (regexFind "^[0-9]+\\.[0-9]+" $version) $version (eq (include "bind9.iscImage" .) "true"))) -}}
{{- end }}

{{/*
Node selector of the pods: nodeSelector, plus kubernetes.io/arch: amd64 when named runs the ISC image, unless
nodeSelector sets that key. A key set to null is left out.
*/}}
{{- define "bind9.nodeSelector" -}}
{{- $selector := dict -}}
{{- if eq (include "bind9.iscImage" .) "true" -}}
{{- $_ := set $selector "kubernetes.io/arch" "amd64" -}}
{{- end -}}
{{- range $key, $value := .Values.nodeSelector -}}
{{- if kindIs "invalid" $value -}}
{{- $_ := unset $selector $key -}}
{{- else -}}
{{- $_ := set $selector $key $value -}}
{{- end -}}
{{- end -}}
{{- with $selector -}}
{{- toYaml . -}}
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
