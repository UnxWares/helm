{{/*
Expand the name of the chart.
*/}}
{{- define "taiga.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "taiga.fullname" -}}
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
{{- define "taiga.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "taiga.labels" -}}
helm.sh/chart: {{ include "taiga.chart" . }}
{{ include "taiga.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "taiga.selectorLabels" -}}
app.kubernetes.io/name: {{ include "taiga.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "taiga.serviceAccountName" -}}
{{- if .Values.global.serviceAccount.create }}
{{- default (include "taiga.fullname" .) .Values.global.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.global.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Component-specific selector labels
*/}}
{{- define "taiga.componentSelectorLabels" -}}
{{ include "taiga.selectorLabels" . }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Component-specific labels
*/}}
{{- define "taiga.componentLabels" -}}
{{ include "taiga.labels" . }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Database host
*/}}
{{- define "taiga.databaseHost" -}}
{{- if .Values.externalDatabase.enabled }}
{{- if .Values.externalDatabase.existingSecret }}
{{- "" }}
{{- else }}
{{- .Values.externalDatabase.host }}
{{- end }}
{{- else }}
{{- printf "%s-db" (include "taiga.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Backend environment variables
*/}}
{{- define "taiga.backendEnv" -}}
{{- if .Values.global.existingSecret }}
- name: TAIGA_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.global.existingSecret }}
      key: SECRET_KEY
{{- else }}
- name: TAIGA_SECRET_KEY
  value: {{ .Values.global.secretKey | quote }}
{{- end }}

- name: TAIGA_SITES_SCHEME
  value: {{ .Values.global.scheme | quote }}
- name: TAIGA_SITES_DOMAIN
  value: {{ .Values.global.domain | quote }}
- name: TAIGA_SUBPATH
  value: {{ .Values.global.subPath | quote }}

{{- if .Values.externalDatabase.enabled }}
{{- if .Values.externalDatabase.existingSecret }}
- name: POSTGRES_HOST
  valueFrom:
    secretKeyRef:
      name: {{ .Values.externalDatabase.existingSecret }}
      key: {{ .Values.externalDatabase.secretKeys.host }}
- name: POSTGRES_PORT
  valueFrom:
    secretKeyRef:
      name: {{ .Values.externalDatabase.existingSecret }}
      key: {{ .Values.externalDatabase.secretKeys.port }}
- name: POSTGRES_DB
  valueFrom:
    secretKeyRef:
      name: {{ .Values.externalDatabase.existingSecret }}
      key: {{ .Values.externalDatabase.secretKeys.database }}
- name: POSTGRES_USER
  valueFrom:
    secretKeyRef:
      name: {{ .Values.externalDatabase.existingSecret }}
      key: {{ .Values.externalDatabase.secretKeys.username }}
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.externalDatabase.existingSecret }}
      key: {{ .Values.externalDatabase.secretKeys.password }}
{{- else }}
- name: POSTGRES_HOST
  value: {{ .Values.externalDatabase.host | quote }}
- name: POSTGRES_PORT
  value: {{ .Values.externalDatabase.port | quote }}
- name: POSTGRES_DB
  value: {{ .Values.externalDatabase.database | quote }}
- name: POSTGRES_USER
  value: {{ .Values.externalDatabase.username | quote }}
- name: POSTGRES_PASSWORD
  value: {{ .Values.externalDatabase.password | quote }}
{{- end }}
{{- else }}
- name: POSTGRES_HOST
  value: {{ include "taiga.databaseHost" . | quote }}
- name: POSTGRES_PORT
  value: "5432"
{{- if .Values.db.auth.existingSecret }}
- name: POSTGRES_USER
  valueFrom:
    secretKeyRef:
      name: {{ .Values.db.auth.existingSecret }}
      key: {{ .Values.db.auth.secretKeys.user }}
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.db.auth.existingSecret }}
      key: {{ .Values.db.auth.secretKeys.password }}
{{- else if .Values.global.existingSecret }}
- name: POSTGRES_USER
  valueFrom:
    secretKeyRef:
      name: {{ .Values.global.existingSecret }}
      key: POSTGRES_USER
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.global.existingSecret }}
      key: POSTGRES_PASSWORD
{{- else }}
- name: POSTGRES_USER
  value: {{ .Values.db.auth.user | quote }}
- name: POSTGRES_PASSWORD
  value: {{ .Values.db.auth.password | quote }}
{{- end }}
- name: POSTGRES_DB
  value: {{ .Values.db.auth.database | quote }}
{{- end }}

{{- if .Values.backend.email.existingSecret }}
- name: EMAIL_HOST_USER
  valueFrom:
    secretKeyRef:
      name: {{ .Values.backend.email.existingSecret }}
      key: {{ .Values.backend.email.secretKeys.user }}
- name: EMAIL_HOST_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.backend.email.existingSecret }}
      key: {{ .Values.backend.email.secretKeys.password }}
{{- else }}
- name: EMAIL_HOST_USER
  value: {{ .Values.backend.email.user | quote }}
- name: EMAIL_HOST_PASSWORD
  value: {{ .Values.backend.email.password | quote }}
{{- end }}
- name: EMAIL_BACKEND
  value: {{ printf "django.core.mail.backends.%s.EmailBackend" .Values.backend.email.backend | quote }}
- name: DEFAULT_FROM_EMAIL
  value: {{ .Values.backend.email.defaultFrom | quote }}
- name: EMAIL_USE_TLS
  value: {{ .Values.backend.email.useTLS | quote }}
- name: EMAIL_USE_SSL
  value: {{ .Values.backend.email.useSSL | quote }}
- name: EMAIL_HOST
  value: {{ .Values.backend.email.host | quote }}
- name: EMAIL_PORT
  value: {{ .Values.backend.email.port | quote }}

- name: TAIGA_ASYNC_RABBITMQ_HOST
  value: {{ include "taiga.fullname" . }}-async-rabbitmq
- name: TAIGA_EVENTS_RABBITMQ_HOST
  value: {{ include "taiga.fullname" . }}-events-rabbitmq
{{- if .Values.asyncRabbitmq.auth.existingSecret }}
- name: RABBITMQ_USER
  valueFrom:
    secretKeyRef:
      name: {{ .Values.asyncRabbitmq.auth.existingSecret }}
      key: {{ .Values.asyncRabbitmq.auth.secretKeys.user }}
- name: RABBITMQ_PASS
  valueFrom:
    secretKeyRef:
      name: {{ .Values.asyncRabbitmq.auth.existingSecret }}
      key: {{ .Values.asyncRabbitmq.auth.secretKeys.password }}
- name: RABBITMQ_VHOST
  valueFrom:
    secretKeyRef:
      name: {{ .Values.asyncRabbitmq.auth.existingSecret }}
      key: {{ .Values.asyncRabbitmq.auth.secretKeys.vhost }}
{{- else if .Values.global.existingSecret }}
- name: RABBITMQ_USER
  valueFrom:
    secretKeyRef:
      name: {{ .Values.global.existingSecret }}
      key: RABBITMQ_USER
- name: RABBITMQ_PASS
  valueFrom:
    secretKeyRef:
      name: {{ .Values.global.existingSecret }}
      key: RABBITMQ_PASS
- name: RABBITMQ_VHOST
  value: {{ .Values.asyncRabbitmq.auth.vhost | quote }}
{{- else }}
- name: RABBITMQ_USER
  value: {{ .Values.asyncRabbitmq.auth.user | quote }}
- name: RABBITMQ_PASS
  value: {{ .Values.asyncRabbitmq.auth.password | quote }}
- name: RABBITMQ_VHOST
  value: {{ .Values.asyncRabbitmq.auth.vhost | quote }}
{{- end }}

- name: ENABLE_TELEMETRY
  value: {{ .Values.global.telemetry.enabled | quote }}

{{- if .Values.global.oidc.enabled }}
- name: ENABLE_OIDC_AUTH
  value: "True"
- name: OIDC_ISSUER
  value: {{ .Values.global.oidc.issuer | quote }}
{{- if .Values.global.oidc.existingSecret }}
- name: OIDC_CLIENT_ID
  valueFrom:
    secretKeyRef:
      name: {{ .Values.global.oidc.existingSecret }}
      key: {{ .Values.global.oidc.secretKeys.clientId }}
- name: OIDC_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.global.oidc.existingSecret }}
      key: {{ .Values.global.oidc.secretKeys.clientSecret }}
{{- else }}
- name: OIDC_CLIENT_ID
  value: {{ .Values.global.oidc.clientId | quote }}
- name: OIDC_CLIENT_SECRET
  value: {{ .Values.global.oidc.clientSecret | quote }}
{{- end }}
- name: OIDC_SCOPES
  value: {{ .Values.global.oidc.scopes | quote }}
{{- if .Values.global.oidc.endpoints.authorization }}
- name: OIDC_AUTHORIZATION_ENDPOINT
  value: {{ .Values.global.oidc.endpoints.authorization | quote }}
{{- end }}
{{- if .Values.global.oidc.endpoints.token }}
- name: OIDC_TOKEN_ENDPOINT
  value: {{ .Values.global.oidc.endpoints.token | quote }}
{{- end }}
{{- if .Values.global.oidc.endpoints.userinfo }}
- name: OIDC_USERINFO_ENDPOINT
  value: {{ .Values.global.oidc.endpoints.userinfo | quote }}
{{- end }}
{{- if .Values.global.oidc.endpoints.jwks }}
- name: OIDC_JWKS_ENDPOINT
  value: {{ .Values.global.oidc.endpoints.jwks | quote }}
{{- end }}
{{- if .Values.global.oidc.backend.useXForwardedHost }}
- name: USE_X_FORWARDED_HOST
  value: "True"
{{- end }}
{{- end }}

{{- with .Values.global.extraEnv }}
{{- toYaml . }}
{{- end }}
{{- end }}

{{/*
Frontend environment variables
*/}}
{{- define "taiga.frontendEnv" -}}
- name: TAIGA_URL
  value: {{ printf "%s://%s" .Values.global.scheme .Values.global.domain | quote }}
- name: TAIGA_WEBSOCKETS_URL
  value: {{ printf "%s://%s" .Values.global.websocketsScheme .Values.global.domain | quote }}
- name: TAIGA_SUBPATH
  value: {{ .Values.global.subPath | quote }}

{{- if .Values.global.oidc.enabled }}
- name: ENABLE_OIDC_AUTH
  value: "true"
- name: OIDC_BUTTON_TEXT
  value: {{ .Values.global.oidc.frontend.buttonText | quote }}
- name: DEFAULT_LOGIN_ENABLED
  value: {{ .Values.global.oidc.frontend.enableDefaultLogin | quote }}
{{- end }}

{{- with .Values.global.extraEnv }}
{{- toYaml . }}
{{- end }}
{{- end }}

{{/*
Events environment variables
*/}}
{{- define "taiga.eventsEnv" -}}
{{- if .Values.global.existingSecret }}
- name: TAIGA_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.global.existingSecret }}
      key: SECRET_KEY
{{- else }}
- name: TAIGA_SECRET_KEY
  value: {{ .Values.global.secretKey | quote }}
{{- end }}

- name: TAIGA_EVENTS_RABBITMQ_HOST
  value: {{ include "taiga.fullname" . }}-events-rabbitmq
{{- if .Values.eventsRabbitmq.auth.existingSecret }}
- name: RABBITMQ_USER
  valueFrom:
    secretKeyRef:
      name: {{ .Values.eventsRabbitmq.auth.existingSecret }}
      key: {{ .Values.eventsRabbitmq.auth.secretKeys.user }}
- name: RABBITMQ_PASS
  valueFrom:
    secretKeyRef:
      name: {{ .Values.eventsRabbitmq.auth.existingSecret }}
      key: {{ .Values.eventsRabbitmq.auth.secretKeys.password }}
- name: RABBITMQ_VHOST
  valueFrom:
    secretKeyRef:
      name: {{ .Values.eventsRabbitmq.auth.existingSecret }}
      key: {{ .Values.eventsRabbitmq.auth.secretKeys.vhost }}
{{- else if .Values.global.existingSecret }}
- name: RABBITMQ_USER
  valueFrom:
    secretKeyRef:
      name: {{ .Values.global.existingSecret }}
      key: RABBITMQ_USER
- name: RABBITMQ_PASS
  valueFrom:
    secretKeyRef:
      name: {{ .Values.global.existingSecret }}
      key: RABBITMQ_PASS
- name: RABBITMQ_VHOST
  value: {{ .Values.eventsRabbitmq.auth.vhost | quote }}
{{- else }}
- name: RABBITMQ_USER
  value: {{ .Values.eventsRabbitmq.auth.user | quote }}
- name: RABBITMQ_PASS
  value: {{ .Values.eventsRabbitmq.auth.password | quote }}
- name: RABBITMQ_VHOST
  value: {{ .Values.eventsRabbitmq.auth.vhost | quote }}
{{- end }}

{{- with .Values.global.extraEnv }}
{{- toYaml . }}
{{- end }}
{{- end }}

{{/*
Protected environment variables
*/}}
{{- define "taiga.protectedEnv" -}}
- name: MAX_AGE
  value: {{ .Values.protected.maxAge | quote }}
{{- if .Values.global.existingSecret }}
- name: SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.global.existingSecret }}
      key: SECRET_KEY
{{- else }}
- name: SECRET_KEY
  value: {{ .Values.global.secretKey | quote }}
{{- end }}

{{- with .Values.global.extraEnv }}
{{- toYaml . }}
{{- end }}
{{- end }}
