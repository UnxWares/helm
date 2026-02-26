{{/*
Expand the name of the chart.
*/}}
{{- define "laravel-generic.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "laravel-generic.fullname" -}}
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
{{- define "laravel-generic.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "laravel-generic.labels" -}}
helm.sh/chart: {{ include "laravel-generic.chart" . }}
{{ include "laravel-generic.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "laravel-generic.selectorLabels" -}}
app.kubernetes.io/name: {{ include "laravel-generic.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "laravel-generic.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "laravel-generic.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Defining all environment variables
*/}}
{{- define "laravel-generic.env" -}}

- name: APP_NAME
  value: {{ .Values.laravel.name | quote }}
- name: APP_ENV
  value: {{ .Values.laravel.env | quote }}
- name: APP_KEY
  {{- if .Values.laravel.key.existingSecret }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.laravel.key.existingSecret }}
      key: {{ .Values.laravel.key.existingSecretKey }}
  {{- else }}
  value: {{ .Values.laravel.key.value | quote }}
  {{- end }}
- name: APP_DEBUG
  value: {{ .Values.laravel.debug | quote }}
- name: APP_URL
  value: {{ .Values.laravel.url | quote }}

- name: APP_LOCALE
  value: {{ .Values.laravel.locale.default | quote }}
- name: APP_FALLBACK_LOCALE
  value: {{ .Values.laravel.locale.fallback | quote }}
- name: APP_FAKER_LOCALE
  value: {{ .Values.laravel.locale.faker | quote }}

- name: APP_MAINTENANCE_DRIVER
  value: {{ .Values.laravel.maintenance.driver | quote }}
{{- if .Values.laravel.maintenance.store }}
- name: APP_MAINTENANCE_STORE
  value: {{ .Values.laravel.maintenance.store | quote }}
{{- end }}

- name: PHP_CLI_SERVER_WORKERS
  value: {{ .Values.laravel.cli_server_workers | quote }}

- name: BCRYPT_ROUNDS
  value: {{ .Values.laravel.bcrypt_rounds | quote }}

- name: LOG_CHANNEL
  value: {{ .Values.laravel.log.channel | quote }}
- name: LOG_STACK
  value: {{ .Values.laravel.log.stack | quote }}
- name: LOG_DEPRECATIONS_CHANNEL
  value: {{ .Values.laravel.log.deprecations_channel | quote }}
- name: LOG_LEVEL
  value: {{ .Values.laravel.log.level | quote }}

{{- if .Values.laravel.database.enabled }}

- name: DB_CONNECTION
  value: {{ .Values.laravel.database.connection | quote }}
- name: DB_HOST
  {{- if .Values.laravel.database.existingSecret }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.laravel.database.existingSecret }}
      key: {{ .Values.laravel.database.secretKeys.host }}
  {{- else }}
  value: {{ .Values.laravel.database.host | quote }}
  {{- end }}
- name: DB_PORT
  {{- if .Values.laravel.database.existingSecret }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.laravel.database.existingSecret }}
      key: {{ .Values.laravel.database.secretKeys.port }}
  {{- else }}
  value: {{ .Values.laravel.database.port | quote }}
  {{- end }}
- name: DB_DATABASE
  {{- if .Values.laravel.database.existingSecret }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.laravel.database.existingSecret }}
      key: {{ .Values.laravel.database.secretKeys.database }}
  {{- else }}
  value: {{ .Values.laravel.database.database | quote }}
  {{- end }}
- name: DB_USERNAME
  {{- if .Values.laravel.database.existingSecret }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.laravel.database.existingSecret }}
      key: {{ .Values.laravel.database.secretKeys.username }}
  {{- else }}
  value: {{ .Values.laravel.database.username | quote }}
  {{- end }}
- name: DB_PASSWORD
  {{- if .Values.laravel.database.existingSecret }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.laravel.database.existingSecret }}
      key: {{ .Values.laravel.database.secretKeys.password }}
  {{- else }}
  value: {{ .Values.laravel.database.password | quote }}
  {{- end }}

{{- end }}

- name: SESSION_DRIVER
  value: {{ .Values.laravel.session.driver | quote }}
- name: SESSION_LIFETIME
  value: {{ .Values.laravel.session.lifetime | quote }}
- name: SESSION_ENCRYPT
  value: {{ .Values.laravel.session.encrypt | quote }}
- name: SESSION_PATH
  value: {{ .Values.laravel.session.path | quote }}
- name: SESSION_DOMAIN
  value: {{ .Values.laravel.session.domain | quote }}

- name: BROADCAST_CONNECTION
  value: {{ .Values.laravel.broadcast_connection | quote }}
- name: FILESYSTEM_DISK
  value: {{ .Values.laravel.filesystem_disk | quote }}
- name: QUEUE_CONNECTION
  value: {{ .Values.laravel.queue_connection | quote }}

- name: CACHE_STORE
  value: {{ .Values.laravel.cache.store | quote }}
{{- if .Values.laravel.cache.prefix }}
- name: CACHE_PREFIX
  value: {{ .Values.laravel.cache.prefix | quote }}
{{- end }}

- name: MEMCACHED_HOST
  value: {{ .Values.laravel.memcached.host | quote }}

{{- if .Values.laravel.redis.enabled }}

- name: REDIS_CLIENT
  value: {{ .Values.laravel.redis.client | quote }}
- name: REDIS_HOST
  {{- if .Values.laravel.redis.existingSecret }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.laravel.redis.existingSecret }}
      key: {{ .Values.laravel.redis.secretKeys.host }}
  {{- else }}
  value: {{ .Values.laravel.redis.host | quote }}
  {{- end }}
- name: REDIS_PASSWORD
  {{- if .Values.laravel.redis.existingSecret }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.laravel.redis.existingSecret }}
      key: {{ .Values.laravel.redis.secretKeys.password }}
  {{- else }}
  value: {{ .Values.laravel.redis.password | quote }}
  {{- end }}
- name: REDIS_PORT
  {{- if .Values.laravel.redis.existingSecret }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.laravel.redis.existingSecret }}
      key: {{ .Values.laravel.redis.secretKeys.port }}
  {{- else }}
  value: {{ .Values.laravel.redis.port | quote }}
  {{- end }}

{{- end }}


{{- if .Values.laravel.mail.enabled }}

- name: MAIL_MAILER
  value: {{ .Values.laravel.mail.mailer | quote }}
- name: MAIL_SCHEME
  value: {{ .Values.laravel.mail.scheme | quote }}
- name: MAIL_HOST
  {{- if .Values.laravel.mail.existingSecret }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.laravel.mail.existingSecret }}
      key: {{ .Values.laravel.mail.secretKeys.host }}
  {{- else }}
  value: {{ .Values.laravel.mail.host | quote }}
  {{- end }}
- name: MAIL_PORT
  {{- if .Values.laravel.mail.existingSecret }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.laravel.mail.existingSecret }}
      key: {{ .Values.laravel.mail.secretKeys.port }}
  {{- else }}
  value: {{ .Values.laravel.mail.port | quote }}
  {{- end }}
- name: MAIL_USERNAME
  {{- if .Values.laravel.mail.existingSecret }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.laravel.mail.existingSecret }}
      key: {{ .Values.laravel.mail.secretKeys.username }}
  {{- else }}
  value: {{ .Values.laravel.mail.username | quote }}
  {{- end }}
- name: MAIL_PASSWORD
  {{- if .Values.laravel.mail.existingSecret }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.laravel.mail.existingSecret }}
      key: {{ .Values.laravel.mail.secretKeys.password }}
  {{- else }}
  value: {{ .Values.laravel.mail.password | quote }}
  {{- end }}
- name: MAIL_FROM_ADDRESS
  value: {{ .Values.laravel.mail.from.address | quote }}
- name: MAIL_FROM_NAME
  value: {{ .Values.laravel.mail.from.name | quote }}

{{- end }}

{{- if .Values.laravel.aws.enabled }}

- name: AWS_ACCESS_KEY_ID
  {{- if .Values.laravel.aws.existingSecret }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.laravel.aws.existingSecret }}
      key: {{ .Values.laravel.aws.secretKeys.access_key_id }}
  {{- else }}
  value: {{ .Values.laravel.aws.access_key_id | quote }}
  {{- end }}
- name: AWS_SECRET_ACCESS_KEY
  {{- if .Values.laravel.aws.existingSecret }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.laravel.aws.existingSecret }}
      key: {{ .Values.laravel.aws.secretKeys.secret_access_key }}
  {{- else }}
  value: {{ .Values.laravel.aws.secret_access_key | quote }}
  {{- end }}
- name: AWS_REGION
  {{- if .Values.laravel.aws.existingSecret }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.laravel.aws.existingSecret }}
      key: {{ .Values.laravel.aws.secretKeys.region }}
  {{- else }}
  value: {{ .Values.laravel.aws.region | quote }}
  {{- end }}
- name: AWS_BUCKET
  {{- if .Values.laravel.aws.existingSecret }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.laravel.aws.existingSecret }}
      key: {{ .Values.laravel.aws.secretKeys.bucket }}
  {{- else }}
  value: {{ .Values.laravel.aws.bucket | quote }}
  {{- end }}
- name: AWS_USE_PATH_STYLE_ENDPOINT
  value: {{ .Values.laravel.aws.use_path_style_endpoint | quote }}

{{- end }}

{{- if .Values.laravel.vite.enabled }}

- name: VITE_APP_NAME
  value: {{ .Values.laravel.vite.app_name | quote }}

{{- end }}

{{ if .Values.laravel.extraEnv }}
  {{- toYaml .Values.laravel.extraEnv }}
{{ end }}

{{- end }}
