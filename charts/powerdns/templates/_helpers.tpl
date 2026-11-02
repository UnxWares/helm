{{/*
Expand the name of the chart.
*/}}
{{- define "powerdns.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "powerdns.fullname" -}}
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
Name of the recursor resources.
*/}}
{{- define "powerdns.recursor.fullname" -}}
{{- printf "%s-recursor" (include "powerdns.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "powerdns.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "powerdns.labels" -}}
helm.sh/chart: {{ include "powerdns.chart" . }}
{{ include "powerdns.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "powerdns.selectorLabels" -}}
app.kubernetes.io/name: {{ include "powerdns.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Selector labels of the authoritative server.
*/}}
{{- define "powerdns.auth.selectorLabels" -}}
{{ include "powerdns.selectorLabels" . }}
app.kubernetes.io/component: authoritative
{{- end }}

{{/*
Selector labels of the recursor.
*/}}
{{- define "powerdns.recursor.selectorLabels" -}}
{{ include "powerdns.selectorLabels" . }}
app.kubernetes.io/component: recursor
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "powerdns.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "powerdns.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Render an image reference from {repository, tag, digest}; an empty repository follows imageProvider. Usage:
{{ include "powerdns.image" (dict "ctx" . "name" "pdns-auth" "image" .Values.image "default" .Chart.AppVersion) }}
*/}}
{{- define "powerdns.image" -}}
{{- $repository := .image.repository -}}
{{- if not $repository -}}
{{- $upstream := dict "pdns-auth" "docker.io/powerdns/pdns-auth-51" "pdns-recursor" "docker.io/powerdns/pdns-recursor-54" -}}
{{- $repository = ternary (printf "ghcr.io/unxwares/%s" .name) (get $upstream .name) (eq .ctx.Values.imageProvider "unxwares") -}}
{{- end -}}
{{- if .image.digest -}}
{{- printf "%s@%s" $repository .image.digest -}}
{{- else -}}
{{- printf "%s:%s" $repository (.image.tag | default .default | toString) -}}
{{- end -}}
{{- end }}

{{/*
PostgreSQL client image of the gpgsql schema init container.
*/}}
{{- define "powerdns.postgresImage" -}}
{{- .Values.backend.schemaInit.postgresImage | default (ternary "ghcr.io/unxwares/postgresql-client:18" "docker.io/library/postgres:18.6-alpine" (eq .Values.imageProvider "unxwares")) -}}
{{- end }}

{{/*
MySQL client image of the gmysql schema init container.
*/}}
{{- define "powerdns.mysqlImage" -}}
{{- .Values.backend.schemaInit.mysqlImage | default (ternary "ghcr.io/unxwares/mysql-client:8.4" "docker.io/library/mysql:8.4.13" (eq .Values.imageProvider "unxwares")) -}}
{{- end }}

{{/*
Name of the secret holding the API key and the database password.
*/}}
{{- define "powerdns.secretName" -}}
{{- include "powerdns.fullname" . }}
{{- end }}

{{/*
API key: explicit value, else the one already stored in the release secret, else a new random one.
*/}}
{{- define "powerdns.apiKey" -}}
{{- if .Values.api.key -}}
{{- .Values.api.key -}}
{{- else -}}
{{- $secret := lookup "v1" "Secret" .Release.Namespace (include "powerdns.secretName" .) -}}
{{- if and $secret (index $secret.data "api-key") -}}
{{- index $secret.data "api-key" | b64dec -}}
{{- else -}}
{{- randAlphaNum 40 -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Settings of the selected SQL backend (gpgsql or gmysql), or an empty dict.
*/}}
{{- define "powerdns.sqlBackend" -}}
{{- if eq .Values.backend.type "gpgsql" }}
{{- toYaml .Values.backend.gpgsql }}
{{- else if eq .Values.backend.type "gmysql" }}
{{- toYaml .Values.backend.gmysql }}
{{- end }}
{{- end }}

{{/*
Environment variables carrying secrets into the config templates rendered by the image startup script.
*/}}
{{- define "powerdns.secretEnv" -}}
{{- include "powerdns.apiKeyEnv" . }}
{{- include "powerdns.dbPasswordEnv" . }}
{{- end }}

{{/*
Environment variable carrying the API key, for the server and the `helm test` pod.
*/}}
{{- define "powerdns.apiKeyEnv" -}}
{{- if .Values.api.enabled }}
- name: PDNS_API_KEY
  valueFrom:
    secretKeyRef:
      {{- if .Values.api.existingSecret }}
      name: {{ .Values.api.existingSecret }}
      key: {{ .Values.api.existingSecretKey }}
      {{- else }}
      name: {{ include "powerdns.secretName" . }}
      key: api-key
      {{- end }}
{{- end }}
{{- end }}

{{/*
Environment variable carrying the database password (gpgsql, gmysql), for the server and the schema init container.
*/}}
{{- define "powerdns.dbPasswordEnv" -}}
{{- $db := include "powerdns.sqlBackend" . | fromYaml }}
{{- if $db }}
- name: PDNS_DB_PASSWORD
  valueFrom:
    secretKeyRef:
      {{- if $db.existingSecret }}
      name: {{ $db.existingSecret }}
      key: {{ $db.existingSecretPasswordKey }}
      {{- else }}
      name: {{ include "powerdns.secretName" . }}
      key: db-password
      {{- end }}
{{- end }}
{{- end }}

{{/*
Default topology spread: replicas on different nodes, then zones, without ever blocking scheduling.
Usage: include "powerdns.defaultSpread" (include "powerdns.auth.selectorLabels" .)
*/}}
{{- define "powerdns.defaultSpread" -}}
{{- range list "kubernetes.io/hostname" "topology.kubernetes.io/zone" }}
- maxSkew: 1
  topologyKey: {{ . }}
  whenUnsatisfiable: ScheduleAnyway
  labelSelector:
    matchLabels:
      {{- $ | nindent 6 }}
{{- end }}
{{- end }}

{{/*
preStop hook that keeps a DNS server answering while its pod leaves the Service endpoints (rolling update, drain),
so that the queries still routed to it are not refused; fails when the grace period is not longer than the sleep.
Usage: include "powerdns.preStop" (dict "ctx" $ "values" .Values.recursor "prefix" "recursor.")
*/}}
{{- define "powerdns.preStop" -}}
{{- $sleep := int .values.preStopSleepSeconds }}
{{- $grace := int .values.terminationGracePeriodSeconds }}
{{- if gt $sleep 0 }}
{{- if le $grace $sleep }}
{{- fail (printf "%sterminationGracePeriodSeconds (%d) must be greater than %spreStopSleepSeconds (%d)" .prefix $grace .prefix $sleep) }}
{{- end }}
lifecycle:
  preStop:
    {{- if semverCompare ">=1.30-0" .ctx.Capabilities.KubeVersion.Version }}
    sleep:
      seconds: {{ $sleep }}
    {{- else }}
    # The sleep action needs Kubernetes 1.30: run sleep from the image instead.
    exec:
      command: ["sleep", "{{ $sleep }}"]
    {{- end }}
{{- end }}
{{- end }}

{{/*
Zone cache refresh interval: every server only learns about a zone created through another server's API when
its zone cache is refreshed, so several servers sharing the database refresh it more often.
*/}}
{{- define "powerdns.zoneCacheRefreshInterval" -}}
{{- if not (kindIs "invalid" .Values.zoneCacheRefreshInterval) }}
{{- .Values.zoneCacheRefreshInterval }}
{{- else if or .Values.autoscaling.enabled (gt (int .Values.replicaCount) 1) }}
{{- 30 }}
{{- end }}
{{- end }}

{{/*
Validate values that would otherwise produce a broken deployment.
*/}}
{{- define "powerdns.validate" -}}
{{- if not (has .Values.backend.type (list "gsqlite3" "gpgsql" "gmysql")) }}
{{- fail (printf "backend.type must be gsqlite3, gpgsql or gmysql (got %q)" .Values.backend.type) }}
{{- end }}
{{- if eq .Values.backend.type "gsqlite3" }}
{{- if or (gt (int .Values.replicaCount) 1) .Values.autoscaling.enabled }}
{{- fail "the gsqlite3 backend supports a single replica: use gpgsql or gmysql to scale out" }}
{{- end }}
{{- else }}
{{- $db := include "powerdns.sqlBackend" . | fromYaml }}
{{- if not $db.host }}
{{- fail (printf "backend.%s.host is required" .Values.backend.type) }}
{{- end }}
{{- if and (not $db.existingSecret) (not $db.password) }}
{{- fail (printf "backend.%s.password or backend.%s.existingSecret is required" .Values.backend.type .Values.backend.type) }}
{{- end }}
{{- end }}
{{- if and .Values.api.enabled (not .Values.webserver.enabled) }}
{{- fail "api.enabled requires webserver.enabled" }}
{{- end }}
{{- end }}
