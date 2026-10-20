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
Name of the chart-managed secret.
*/}}
{{- define "taiga.secretName" -}}
{{- include "taiga.fullname" . }}
{{- end }}

{{/*
Value of a generated secret key: explicit value, else the value already stored in the release secret, else random.
Usage: include "taiga.generatedSecret" (dict "ctx" $ "key" "secret-key" "value" .Values.global.secretKey "length" 64)
*/}}
{{- define "taiga.generatedSecret" -}}
{{- if .value -}}
{{- .value -}}
{{- else -}}
{{- $secret := lookup "v1" "Secret" .ctx.Release.Namespace (include "taiga.secretName" .ctx) -}}
{{- if and $secret (index $secret.data .key) -}}
{{- index $secret.data .key | b64dec -}}
{{- else -}}
{{- randAlphaNum (int .length) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Probe merged with the global defaults (values set on the probe win).
Usage: include "taiga.probe" (dict "probe" .Values.backend.livenessProbe "defaults" .Values.global.defaultProbes.liveness)
*/}}
{{- define "taiga.probe" -}}
{{- toYaml (merge (deepCopy .probe) (deepCopy (.defaults | default dict))) }}
{{- end }}

{{/*
Image of the backend/async containers (OIDC override, with an optional digest).
*/}}
{{- define "taiga.backImage" -}}
{{- $img := .image }}
{{- if and .ctx.Values.global.oidc.enabled .ctx.Values.global.oidc.backend.overrideImage.name }}
{{- with .ctx.Values.global.oidc.backend.overrideImage }}
{{- if .digest }}{{ printf "%s@%s" .name .digest }}{{ else }}{{ printf "%s:%s" .name .tag }}{{ end }}
{{- end }}
{{- else }}
{{- printf "%s:%s" $img.repository ($img.tag | toString) }}
{{- end }}
{{- end }}

{{/*
Claim name of the shared media volume.
*/}}
{{- define "taiga.mediaClaimName" -}}
{{- .Values.global.persistence.media.existingClaim | default (printf "%s-media" (include "taiga.fullname" .)) }}
{{- end }}

{{/*
Access mode of the media volume. An existing claim keeps the mode it was created with
(accessModes are immutable: releases created with the former ReadWriteMany default keep it).
*/}}
{{- define "taiga.mediaAccessMode" -}}
{{- $media := .Values.global.persistence.media }}
{{- $existing := lookup "v1" "PersistentVolumeClaim" .Release.Namespace (include "taiga.mediaClaimName" .) }}
{{- if and $existing $existing.spec.accessModes }}
{{- first $existing.spec.accessModes }}
{{- else }}
{{- $media.accessMode }}
{{- end }}
{{- end }}

{{/*
Pod affinity. Backend, async and gateway share the media volume: with a ReadWriteOnce volume they must run on the
backend's node, so the chart adds that rule when no affinity is configured for the component.
Usage: include "taiga.affinity" (dict "ctx" $ "affinity" (default .Values.global.pod.affinity .Values.backend.affinity) "media" true)
*/}}
{{- define "taiga.affinity" -}}
{{- $media := .ctx.Values.global.persistence.media }}
{{- if .affinity }}
{{- toYaml .affinity }}
{{- else if and .media $media.enabled (eq (include "taiga.mediaAccessMode" .ctx) "ReadWriteOnce") }}
podAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchLabels:
          {{- include "taiga.selectorLabels" .ctx | nindent 10 }}
          app.kubernetes.io/component: backend
      topologyKey: kubernetes.io/hostname
{{- end }}
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
Secret reference for a value that comes from: a component secret, else global.existingSecret, else the chart secret.
Usage: include "taiga.secretRef" (dict "ctx" $ "existing" .auth.existingSecret "existingKey" .auth.secretKeys.password "globalKey" "RABBITMQ_PASS" "chartKey" "async-rabbitmq-password")
*/}}
{{- define "taiga.secretRef" -}}
valueFrom:
  secretKeyRef:
    {{- if .existing }}
    name: {{ .existing }}
    key: {{ .existingKey }}
    {{- else if and .globalKey .ctx.Values.global.existingSecret }}
    name: {{ .ctx.Values.global.existingSecret }}
    key: {{ .globalKey }}
    {{- else }}
    name: {{ include "taiga.secretName" .ctx }}
    key: {{ .chartKey }}
    {{- end }}
{{- end }}

{{/*
TAIGA_SECRET_KEY / SECRET_KEY reference.
*/}}
{{- define "taiga.secretKeyRef" -}}
{{- include "taiga.secretRef" (dict "ctx" . "existing" .Values.global.existingSecret "existingKey" .Values.global.secretKeys.secretKey "chartKey" "secret-key") }}
{{- end }}

{{/*
Broker credentials as environment variables, then the amqp URL built with Kubernetes $(VAR) expansion,
so passwords never appear in clear text in the manifests.
Usage: include "taiga.brokerEnv" (dict "ctx" $ "prefix" "ASYNC" "broker" .Values.asyncRabbitmq "host" "<svc>" "chartKey" "async-rabbitmq-password")
*/}}
{{- define "taiga.brokerEnv" -}}
{{- $auth := .broker.auth }}
- name: {{ .prefix }}_RABBITMQ_USER
  {{- if $auth.existingSecret }}
  {{- include "taiga.secretRef" (dict "ctx" .ctx "existing" $auth.existingSecret "existingKey" $auth.secretKeys.user) | nindent 2 }}
  {{- else if .ctx.Values.global.existingSecret }}
  {{- include "taiga.secretRef" (dict "ctx" .ctx "globalKey" "RABBITMQ_USER") | nindent 2 }}
  {{- else }}
  value: {{ $auth.user | quote }}
  {{- end }}
- name: {{ .prefix }}_RABBITMQ_PASS
  {{- include "taiga.secretRef" (dict "ctx" .ctx "existing" $auth.existingSecret "existingKey" $auth.secretKeys.password "globalKey" "RABBITMQ_PASS" "chartKey" .chartKey) | nindent 2 }}
- name: {{ .prefix }}_RABBITMQ_VHOST
  {{- if $auth.existingSecret }}
  {{- include "taiga.secretRef" (dict "ctx" .ctx "existing" $auth.existingSecret "existingKey" $auth.secretKeys.vhost) | nindent 2 }}
  {{- else }}
  value: {{ $auth.vhost | quote }}
  {{- end }}
{{- end }}

{{/*
Backend environment variables
*/}}
{{- define "taiga.backendEnv" -}}
- name: TAIGA_SECRET_KEY
  {{- include "taiga.secretKeyRef" . | nindent 2 }}

- name: TAIGA_SITES_SCHEME
  value: {{ .Values.global.scheme | quote }}
- name: TAIGA_SITES_DOMAIN
  value: {{ .Values.global.domain | quote }}
- name: TAIGA_SUBPATH
  value: {{ .Values.global.subPath | quote }}

{{- if .Values.externalDatabase.enabled }}
{{- with .Values.externalDatabase }}
{{- if .existingSecret }}
- name: POSTGRES_HOST
  valueFrom:
    secretKeyRef:
      name: {{ .existingSecret }}
      key: {{ .secretKeys.host }}
- name: POSTGRES_PORT
  valueFrom:
    secretKeyRef:
      name: {{ .existingSecret }}
      key: {{ .secretKeys.port }}
- name: POSTGRES_DB
  valueFrom:
    secretKeyRef:
      name: {{ .existingSecret }}
      key: {{ .secretKeys.database }}
- name: POSTGRES_USER
  valueFrom:
    secretKeyRef:
      name: {{ .existingSecret }}
      key: {{ .secretKeys.username }}
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .existingSecret }}
      key: {{ .secretKeys.password }}
{{- else }}
- name: POSTGRES_HOST
  value: {{ .host | quote }}
- name: POSTGRES_PORT
  value: {{ .port | quote }}
- name: POSTGRES_DB
  value: {{ .database | quote }}
- name: POSTGRES_USER
  value: {{ .username | quote }}
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "taiga.secretName" $ }}
      key: postgres-password
{{- end }}
{{- with .sslmode }}
- name: POSTGRES_SSLMODE
  value: {{ . | quote }}
{{- end }}
{{- end }}
{{- else }}
- name: POSTGRES_HOST
  value: {{ include "taiga.databaseHost" . | quote }}
- name: POSTGRES_PORT
  value: {{ .Values.db.service.port | quote }}
- name: POSTGRES_DB
  value: {{ .Values.db.auth.database | quote }}
{{- include "taiga.dbCredentialsEnv" . }}
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
{{- if .Values.backend.email.password }}
- name: EMAIL_HOST_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "taiga.secretName" . }}
      key: email-password
{{- end }}
{{- end }}
- name: EMAIL_BACKEND
  value: {{ printf "django.core.mail.backends.%s.EmailBackend" .Values.backend.email.backend | quote }}
- name: DEFAULT_FROM_EMAIL
  value: {{ .Values.backend.email.defaultFrom | quote }}
{{- if .Values.backend.email.useTLS }}
- name: EMAIL_USE_TLS
  value: "True"
{{- end }}
{{- if .Values.backend.email.useSSL }}
- name: EMAIL_USE_SSL
  value: "True"
{{- end }}
- name: EMAIL_HOST
  value: {{ .Values.backend.email.host | quote }}
- name: EMAIL_PORT
  value: {{ .Values.backend.email.port | quote }}

{{- $async := printf "%s-async-rabbitmq" (include "taiga.fullname" .) }}
{{- $events := printf "%s-events-rabbitmq" (include "taiga.fullname" .) }}
- name: TAIGA_ASYNC_RABBITMQ_HOST
  value: {{ $async }}
- name: TAIGA_EVENTS_RABBITMQ_HOST
  value: {{ $events }}
{{- include "taiga.brokerEnv" (dict "ctx" . "prefix" "ASYNC" "broker" .Values.asyncRabbitmq "chartKey" "async-rabbitmq-password") | nindent 0 }}
{{- include "taiga.brokerEnv" (dict "ctx" . "prefix" "EVENTS" "broker" .Values.eventsRabbitmq "chartKey" "events-rabbitmq-password") | nindent 0 }}
# Each broker gets its own credentials (taiga-back would otherwise use RABBITMQ_USER/PASS for both).
- name: CELERY_BROKER_URL
  value: "amqp://$(ASYNC_RABBITMQ_USER):$(ASYNC_RABBITMQ_PASS)@{{ $async }}:{{ .Values.asyncRabbitmq.service.port }}/$(ASYNC_RABBITMQ_VHOST)"
- name: EVENTS_PUSH_BACKEND_URL
  value: "amqp://$(EVENTS_RABBITMQ_USER):$(EVENTS_RABBITMQ_PASS)@{{ $events }}:{{ .Values.eventsRabbitmq.service.port }}/$(EVENTS_RABBITMQ_VHOST)"

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
  valueFrom:
    secretKeyRef:
      name: {{ include "taiga.secretName" . }}
      key: oidc-client-secret
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
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Credentials of the bundled database (user + password).
*/}}
{{- define "taiga.dbCredentialsEnv" -}}
{{- if .Values.db.auth.existingSecret }}
- name: POSTGRES_USER
  valueFrom:
    secretKeyRef:
      name: {{ .Values.db.auth.existingSecret }}
      key: {{ .Values.db.auth.secretKeys.user }}
{{- else if .Values.global.existingSecret }}
- name: POSTGRES_USER
  valueFrom:
    secretKeyRef:
      name: {{ .Values.global.existingSecret }}
      key: POSTGRES_USER
{{- else }}
- name: POSTGRES_USER
  value: {{ .Values.db.auth.user | quote }}
{{- end }}
- name: POSTGRES_PASSWORD
  {{- include "taiga.secretRef" (dict "ctx" . "existing" .Values.db.auth.existingSecret "existingKey" .Values.db.auth.secretKeys.password "globalKey" "POSTGRES_PASSWORD" "chartKey" "db-password") | nindent 2 }}
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
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Events environment variables (taiga-events builds amqp://RABBITMQ_USER:RABBITMQ_PASS@host:5672/taiga itself)
*/}}
{{- define "taiga.eventsEnv" -}}
- name: TAIGA_SECRET_KEY
  {{- include "taiga.secretKeyRef" . | nindent 2 }}

- name: TAIGA_EVENTS_RABBITMQ_HOST
  value: {{ include "taiga.fullname" . }}-events-rabbitmq
{{- $auth := .Values.eventsRabbitmq.auth }}
- name: RABBITMQ_USER
  {{- if $auth.existingSecret }}
  {{- include "taiga.secretRef" (dict "ctx" . "existing" $auth.existingSecret "existingKey" $auth.secretKeys.user) | nindent 2 }}
  {{- else if .Values.global.existingSecret }}
  {{- include "taiga.secretRef" (dict "ctx" . "globalKey" "RABBITMQ_USER") | nindent 2 }}
  {{- else }}
  value: {{ $auth.user | quote }}
  {{- end }}
- name: RABBITMQ_PASS
  {{- include "taiga.secretRef" (dict "ctx" . "existing" $auth.existingSecret "existingKey" $auth.secretKeys.password "globalKey" "RABBITMQ_PASS" "chartKey" "events-rabbitmq-password") | nindent 2 }}

{{- with .Values.global.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Protected environment variables
*/}}
{{- define "taiga.protectedEnv" -}}
- name: MAX_AGE
  value: {{ .Values.protected.maxAge | quote }}
- name: TAIGA_SUBPATH
  value: {{ .Values.global.subPath | quote }}
- name: SECRET_KEY
  {{- include "taiga.secretKeyRef" . | nindent 2 }}

{{- with .Values.global.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Validate values that would otherwise produce a broken deployment.
*/}}
{{- define "taiga.validate" -}}
{{- if and .Values.externalDatabase.enabled .Values.db.enabled }}
{{- fail "enable either externalDatabase or db (bundled PostgreSQL), not both" }}
{{- end }}
{{- if and (not .Values.externalDatabase.enabled) (not .Values.db.enabled) }}
{{- fail "a database is required: enable externalDatabase or db" }}
{{- end }}
{{- if and .Values.externalDatabase.enabled (not .Values.externalDatabase.existingSecret) (not .Values.externalDatabase.password) }}
{{- fail "externalDatabase.password or externalDatabase.existingSecret is required" }}
{{- end }}
{{- if and .Values.global.oidc.enabled (not .Values.global.oidc.existingSecret) (not .Values.global.oidc.clientSecret) }}
{{- fail "global.oidc.clientSecret or global.oidc.existingSecret is required when OIDC is enabled" }}
{{- end }}
{{- if and .Values.global.persistence.media.enabled (eq (include "taiga.mediaAccessMode" .) "ReadWriteOncePod") }}
{{- fail "global.persistence.media.accessMode cannot be ReadWriteOncePod: backend, async and gateway mount the same volume" }}
{{- end }}
{{- end }}
