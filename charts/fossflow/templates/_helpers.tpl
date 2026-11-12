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
Whether the pod runs the UnxWares image (imageProvider).
*/}}
{{- define "fossflow.unxwaresImage" -}}
{{- if eq .Values.imageProvider "unxwares" }}true{{ end }}
{{- end }}

{{/*
Image reference: image.repository, or the image of imageProvider when it is empty (digest takes precedence over the
tag). Upstream only publishes `master-<commit>` tags: master-b06baad is release v1.0.6.
*/}}
{{- define "fossflow.image" -}}
{{- $unxwares := include "fossflow.unxwaresImage" . }}
{{- $repository := .Values.image.repository | default (ternary "ghcr.io/unxwares/fossflow" "docker.io/abrar74774/fossflow" (eq $unxwares "true")) }}
{{- if .Values.image.digest }}
{{- printf "%s@%s" $repository .Values.image.digest }}
{{- else }}
{{- printf "%s:%s" $repository (.Values.image.tag | default (ternary .Chart.AppVersion "master-b06baad" (eq $unxwares "true")) | toString) }}
{{- end }}
{{- end }}

{{/*
Port of the container: the UnxWares image runs nginx unprivileged on 8080, the upstream one on 80.
*/}}
{{- define "fossflow.containerPort" -}}
{{- if include "fossflow.unxwaresImage" . }}8080{{ else }}80{{ end }}
{{- end }}

{{/*
Security contexts: the value when set, else the defaults of the image provider. The UnxWares image runs as
storage.uid with a read-only root filesystem and no capability; the upstream entrypoint starts as root, rewrites the
nginx configuration, binds port 80 and starts the backend through su-exec, which needs five capabilities.
*/}}
{{- define "fossflow.podSecurityContext" -}}
{{- $sc := .Values.podSecurityContext }}
{{- if not $sc }}
{{- $sc = dict "fsGroup" (int .Values.storage.gid) "fsGroupChangePolicy" "OnRootMismatch" "seccompProfile" (dict "type" "RuntimeDefault") }}
{{- if include "fossflow.unxwaresImage" . }}
{{- $_ := set $sc "runAsNonRoot" true }}
{{- $_ := set $sc "runAsUser" (int .Values.storage.uid) }}
{{- $_ := set $sc "runAsGroup" (int .Values.storage.gid) }}
{{- end }}
{{- end }}
{{- toYaml $sc }}
{{- end }}

{{- define "fossflow.securityContext" -}}
{{- $sc := .Values.securityContext }}
{{- if not $sc }}
{{- if include "fossflow.unxwaresImage" . }}
{{- $sc = dict "allowPrivilegeEscalation" false "readOnlyRootFilesystem" true "capabilities" (dict "drop" (list "ALL")) }}
{{- else }}
{{- $add := list "CHOWN" "DAC_OVERRIDE" "SETUID" "SETGID" "NET_BIND_SERVICE" }}
{{- $sc = dict "allowPrivilegeEscalation" false "capabilities" (dict "drop" (list "ALL") "add" $add) }}
{{- end }}
{{- end }}
{{- toYaml $sc }}
{{- end }}

{{/*
Whether the diagrams are on a volume that one node (ReadWriteOnce) or one pod (ReadWriteOncePod) mounts at a time:
one replica, replaced with the Recreate strategy.
*/}}
{{- define "fossflow.singleNodeStorage" -}}
{{- $modes := .Values.persistence.accessModes }}
{{- if and .Values.storage.enabled .Values.persistence.enabled (or (has "ReadWriteOnce" $modes) (has "ReadWriteOncePod" $modes)) }}true{{ end }}
{{- end }}

{{/*
Validate values that would otherwise produce a broken deployment.
*/}}
{{- define "fossflow.validate" -}}
{{- if and (include "fossflow.singleNodeStorage" .) (or (gt (int .Values.replicaCount) 1) .Values.autoscaling.enabled) }}
{{- fail "server storage on a ReadWriteOnce volume supports a single replica: use a ReadWriteMany volume or disable storage to scale" }}
{{- end }}
{{- end }}
