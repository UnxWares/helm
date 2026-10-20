{{/*
Expand the name of the chart.
*/}}
{{- define "kener.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "kener.fullname" -}}
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
Name of the bundled Valkey resources.
*/}}
{{- define "kener.valkey.fullname" -}}
{{- printf "%s-valkey" (include "kener.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "kener.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "kener.labels" -}}
helm.sh/chart: {{ include "kener.chart" . }}
{{ include "kener.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels of Kener. Unchanged since the first chart release: a Deployment selector is immutable.
Other pods of the release (Valkey, tests) must never carry this exact pair of labels.
*/}}
{{- define "kener.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kener.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Selector labels of the bundled Valkey.
*/}}
{{- define "kener.valkey.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kener.name" . }}-valkey
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: redis
{{- end }}

{{/*
Labels of the bundled Valkey.
*/}}
{{- define "kener.valkey.labels" -}}
helm.sh/chart: {{ include "kener.chart" . }}
{{ include "kener.valkey.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.redis.image.tag | toString | trunc 63 | trimSuffix "-" | quote }}
app.kubernetes.io/part-of: {{ include "kener.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "kener.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "kener.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Render an image reference from {repository, tag, digest}. Usage:
{{ include "kener.image" (dict "image" .Values.image "default" "1.0.0") }}
*/}}
{{- define "kener.image" -}}
{{- if .image.digest -}}
{{- printf "%s@%s" .image.repository .image.digest -}}
{{- else -}}
{{- printf "%s:%s" .image.repository (.image.tag | default .default | toString) -}}
{{- end -}}
{{- end }}

{{/*
Default Kener image tag: <appVersion>[-status][-alpine], the naming of the published images.
*/}}
{{- define "kener.imageTag" -}}
{{- $tag := .Chart.AppVersion -}}
{{- if eq .Values.kener.basePath "/status" -}}
{{- $tag = printf "%s-status" $tag -}}
{{- end -}}
{{- if eq .Values.image.variant "alpine" -}}
{{- $tag = printf "%s-alpine" $tag -}}
{{- end -}}
{{- $tag -}}
{{- end }}

{{/*
Kener image reference.
*/}}
{{- define "kener.kenerImage" -}}
{{- include "kener.image" (dict "image" .Values.image "default" (include "kener.imageTag" .)) -}}
{{- end }}

{{/*
Name of the secret managed by the chart.
*/}}
{{- define "kener.secretName" -}}
{{- include "kener.fullname" . }}
{{- end }}

{{/*
Value already stored in the release secret under .key, else a new random one. Usage:
{{ include "kener.generated" (dict "ctx" $ "key" "secret-key" "length" 64) }}
*/}}
{{- define "kener.generated" -}}
{{- $secret := lookup "v1" "Secret" .ctx.Release.Namespace (include "kener.secretName" .ctx) -}}
{{- if and $secret (index $secret.data .key) -}}
{{- index $secret.data .key | b64dec -}}
{{- else -}}
{{- randAlphaNum (int .length) -}}
{{- end -}}
{{- end }}

{{/*
KENER_SECRET_KEY sources. kener.key and kener.keyFrom.{secretRef,secretKey} are the deprecated names.
*/}}
{{- define "kener.secretKey.value" -}}
{{- .Values.kener.secretKey | default (dig "key" "" .Values.kener) -}}
{{- end }}

{{- define "kener.secretKey.existingSecret" -}}
{{- .Values.kener.existingSecret | default (dig "keyFrom" "secretRef" "" .Values.kener) -}}
{{- end }}

{{- define "kener.secretKey.existingSecretKey" -}}
{{- if .Values.kener.existingSecret -}}
{{- .Values.kener.existingSecretKey -}}
{{- else -}}
{{- dig "keyFrom" "secretKey" "" .Values.kener | default .Values.kener.existingSecretKey -}}
{{- end -}}
{{- end }}

{{/*
"true" when the database is SQLite: no external URL, an explicit sqlite:// URL, or the deprecated database.enabled=false.
*/}}
{{- define "kener.sqlite" -}}
{{- $legacyEnabled := dig "enabled" true .Values.database -}}
{{- if or (not $legacyEnabled) (and (not .Values.database.existingSecret) (or (not .Values.database.url) (hasPrefix "sqlite://" .Values.database.url))) -}}
true
{{- end -}}
{{- end }}

{{/*
Key of the database URL in database.existingSecret (database.secretKeys.url is the deprecated name).
*/}}
{{- define "kener.database.existingSecretKey" -}}
{{- dig "secretKeys" "url" "" .Values.database | default .Values.database.existingSecretKey -}}
{{- end }}

{{/*
Base path without trailing slash ("" at the root).
*/}}
{{- define "kener.basePath" -}}
{{- .Values.kener.basePath | default "" | trimSuffix "/" -}}
{{- end }}

{{/*
User volumes and mounts, including the deprecated volumes / volumeMounts values.
*/}}
{{- define "kener.extraVolumes" -}}
{{- $all := concat (.Values.extraVolumes | default list) (index .Values "volumes" | default list) -}}
{{- if $all }}
{{- toYaml $all }}
{{- end }}
{{- end }}

{{- define "kener.extraVolumeMounts" -}}
{{- $all := concat (.Values.extraVolumeMounts | default list) (index .Values "volumeMounts" | default list) -}}
{{- if $all }}
{{- toYaml $all }}
{{- end }}
{{- end }}

{{/*
Probe of the Kener container: the user settings, plus an httpGet handler on .path when none is given.
*/}}
{{- define "kener.probe" -}}
{{- $probe := omit .probe "enabled" -}}
{{- if not (or (hasKey $probe "httpGet") (hasKey $probe "exec") (hasKey $probe "tcpSocket") (hasKey $probe "grpc")) -}}
{{- $_ := set $probe "httpGet" (dict "path" .path "port" "http") -}}
{{- end -}}
{{- toYaml $probe -}}
{{- end }}

{{/*
Pod security context of Kener, plus the ping sysctl when pingMonitors.enabled.
*/}}
{{- define "kener.podSecurityContext" -}}
{{- $psc := deepCopy (.Values.podSecurityContext | default dict) -}}
{{- if .Values.pingMonitors.enabled -}}
{{- $sysctls := get $psc "sysctls" | default list -}}
{{- $present := false -}}
{{- range $sysctls -}}
{{- if eq (get . "name") "net.ipv4.ping_group_range" -}}
{{- $present = true -}}
{{- end -}}
{{- end -}}
{{- if not $present -}}
{{- $sysctls = append $sysctls (dict "name" "net.ipv4.ping_group_range" "value" "0 2147483647") -}}
{{- end -}}
{{- $_ := set $psc "sysctls" $sysctls -}}
{{- end -}}
{{- if $psc -}}
{{- toYaml $psc -}}
{{- end -}}
{{- end }}

{{/*
Container security context of Kener, plus NET_RAW in the bounding set when pingMonitors.enabled.
*/}}
{{- define "kener.securityContext" -}}
{{- $sc := deepCopy (.Values.securityContext | default dict) -}}
{{- if .Values.pingMonitors.enabled -}}
{{- $caps := get $sc "capabilities" | default dict -}}
{{- $add := get $caps "add" | default list -}}
{{- if not (has "NET_RAW" $add) -}}
{{- $add = append $add "NET_RAW" -}}
{{- end -}}
{{- $_ := set $caps "add" $add -}}
{{- $_ := set $sc "capabilities" $caps -}}
{{- end -}}
{{- if $sc -}}
{{- toYaml $sc -}}
{{- end -}}
{{- end }}

{{/*
Environment of the Kener container. Every secret comes from a secretKeyRef.
*/}}
{{- define "kener.env" -}}
- name: ORIGIN
  value: {{ .Values.kener.origin | quote }}
- name: KENER_BASE_PATH
  value: {{ include "kener.basePath" . | quote }}
- name: NODE_ENV
  value: {{ .Values.kener.nodeEnv | quote }}
- name: BODY_SIZE_LIMIT
  value: {{ .Values.kener.bodySizeLimit | quote }}
{{- if .Values.kener.forceLocalLogin }}
- name: KENER_FORCE_LOCAL_LOGIN
  value: "true"
{{- end }}
- name: KENER_SECRET_KEY
  valueFrom:
    secretKeyRef:
      {{- if include "kener.secretKey.existingSecret" . }}
      name: {{ include "kener.secretKey.existingSecret" . }}
      key: {{ include "kener.secretKey.existingSecretKey" . }}
      {{- else }}
      name: {{ include "kener.secretName" . }}
      key: secret-key
      {{- end }}
{{- if include "kener.sqlite" . }}
- name: DATABASE_URL
  value: {{ ternary .Values.database.url "sqlite://./database/kener.sqlite.db" (hasPrefix "sqlite://" .Values.database.url) | quote }}
{{- else }}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      {{- if .Values.database.existingSecret }}
      name: {{ .Values.database.existingSecret }}
      key: {{ include "kener.database.existingSecretKey" . }}
      {{- else }}
      name: {{ include "kener.secretName" . }}
      key: database-url
      {{- end }}
{{- with .Values.database.pool }}
{{- if not (kindIs "invalid" .min) }}
- name: DATABASE_POOL_MIN
  value: {{ .min | toString | quote }}
{{- end }}
{{- if not (kindIs "invalid" .max) }}
- name: DATABASE_POOL_MAX
  value: {{ .max | toString | quote }}
{{- end }}
{{- if not (kindIs "invalid" .workerMax) }}
- name: DATABASE_WORKER_POOL_MAX
  value: {{ .workerMax | toString | quote }}
{{- end }}
{{- if not (kindIs "invalid" .acquireTimeoutMs) }}
- name: DATABASE_ACQUIRE_TIMEOUT_MS
  value: {{ .acquireTimeoutMs | toString | quote }}
{{- end }}
{{- if not (kindIs "invalid" .createTimeoutMs) }}
- name: DATABASE_CREATE_TIMEOUT_MS
  value: {{ .createTimeoutMs | toString | quote }}
{{- end }}
{{- if not (kindIs "invalid" .idleTimeoutMs) }}
- name: DATABASE_IDLE_TIMEOUT_MS
  value: {{ .idleTimeoutMs | toString | quote }}
{{- end }}
{{- end }}
{{- if not (kindIs "invalid" .Values.database.keepAlive) }}
- name: DATABASE_KEEPALIVE
  value: {{ .Values.database.keepAlive | toString | quote }}
{{- end }}
{{- end }}
{{- if .Values.redis.enabled }}
# Kubernetes expands $(REDIS_PASSWORD) from the secret-backed variable above: the password never appears in the spec.
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      {{- if .Values.redis.auth.existingSecret }}
      name: {{ .Values.redis.auth.existingSecret }}
      key: {{ .Values.redis.auth.existingSecretPasswordKey }}
      {{- else }}
      name: {{ include "kener.secretName" . }}
      key: redis-password
      {{- end }}
- name: REDIS_URL
  value: {{ printf "redis://:$(REDIS_PASSWORD)@%s:%d" (include "kener.valkey.fullname" .) (int .Values.redis.service.port) | quote }}
{{- else }}
- name: REDIS_URL
  valueFrom:
    secretKeyRef:
      {{- if .Values.redis.external.existingSecret }}
      name: {{ .Values.redis.external.existingSecret }}
      key: {{ .Values.redis.external.existingSecretKey }}
      {{- else }}
      name: {{ include "kener.secretName" . }}
      key: redis-url
      {{- end }}
{{- end }}
{{- with .Values.email.smtp }}
{{- if .host }}
- name: SMTP_HOST
  value: {{ .host | quote }}
- name: SMTP_PORT
  value: {{ .port | toString | quote }}
- name: SMTP_USER
  value: {{ .user | quote }}
- name: SMTP_FROM_EMAIL
  value: {{ .fromEmail | quote }}
- name: SMTP_SECURE
  value: {{ ternary "1" "0" (.secure | default false) | quote }}
- name: SMTP_PASS
  valueFrom:
    secretKeyRef:
      {{- if .existingSecret }}
      name: {{ .existingSecret }}
      key: {{ .existingSecretPasswordKey }}
      {{- else }}
      name: {{ include "kener.secretName" $ }}
      key: smtp-password
      {{- end }}
{{- end }}
{{- end }}
{{- with .Values.email.resend }}
{{- if or .apiKey .existingSecret }}
- name: RESEND_API_KEY
  valueFrom:
    secretKeyRef:
      {{- if .existingSecret }}
      name: {{ .existingSecret }}
      key: {{ .existingSecretKey }}
      {{- else }}
      name: {{ include "kener.secretName" $ }}
      key: resend-api-key
      {{- end }}
- name: RESEND_SENDER_EMAIL
  value: {{ .senderEmail | quote }}
{{- end }}
{{- end }}
{{- if .Values.proxy.httpProxy }}
- name: HTTP_PROXY
  valueFrom:
    secretKeyRef:
      name: {{ include "kener.secretName" . }}
      key: http-proxy
{{- end }}
{{- if .Values.proxy.httpsProxy }}
- name: HTTPS_PROXY
  valueFrom:
    secretKeyRef:
      name: {{ include "kener.secretName" . }}
      key: https-proxy
{{- end }}
{{- if .Values.proxy.noProxy }}
- name: NO_PROXY
  value: {{ .Values.proxy.noProxy | quote }}
{{- end }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Validate values that would otherwise produce a broken or insecure deployment.
*/}}
{{- define "kener.validate" -}}
{{- $origin := .Values.kener.origin | default "" }}
{{- if not $origin }}
{{- fail "kener.origin is required: the public URL of Kener, e.g. https://status.example.com (http://localhost:3000 for a port-forward test)" }}
{{- end }}
{{- if not (regexMatch "^https?://[^/?#]+$" $origin) }}
{{- fail (printf "kener.origin must be scheme + host + optional port, without path or trailing slash (got %q). With kener.basePath, keep the base path out of the origin." $origin) }}
{{- end }}
{{- $base := .Values.kener.basePath | default "" }}
{{- if and $base (not (regexMatch "^(/[A-Za-z0-9._~-]+)+$" $base)) }}
{{- fail (printf "kener.basePath must start with / and have no trailing slash, e.g. /status (got %q)" $base) }}
{{- end }}
{{- if and $base (ne $base "/status") (not .Values.image.tag) (not .Values.image.digest) }}
{{- fail (printf "kener.basePath %q is compiled into the image: published images only exist for \"\" and /status. Build Kener with KENER_BASE_PATH=%s and set image.tag (or image.digest)." $base $base) }}
{{- end }}
{{- if not (has .Values.image.variant (list "alpine" "debian")) }}
{{- fail (printf "image.variant must be alpine or debian (got %q)" .Values.image.variant) }}
{{- end }}
{{- $secretKey := include "kener.secretKey.value" . }}
{{- if and (not (include "kener.secretKey.existingSecret" .)) (has $secretKey (list "thesuperprivatekeytonotshare" "DUMMY_SECRET")) }}
{{- fail "the secret key \"thesuperprivatekeytonotshare\" (previous chart default) or \"DUMMY_SECRET\" is public: anyone could forge Kener sessions. Leave kener.secretKey empty to generate one, or set a random value of 32+ characters (see Upgrading in the chart README)." }}
{{- end }}
{{- $sqlite := include "kener.sqlite" . }}
{{- if and .Values.database.url (not .Values.database.existingSecret) }}
{{- if hasPrefix "postgres://" .Values.database.url }}
{{- fail "database.url must start with postgresql:// (Kener exits on postgres://)" }}
{{- end }}
{{- if not (regexMatch "^(postgresql|mysql|sqlite)://" .Values.database.url) }}
{{- fail "database.url must start with postgresql://, mysql:// or sqlite:// (leave it empty for SQLite on the persistent volume)" }}
{{- end }}
{{- if and (hasPrefix "sqlite://" .Values.database.url) (not (regexMatch "^sqlite://(\\./database/|/app/database/)[^/]+$" .Values.database.url)) }}
{{- fail "a sqlite:// database.url must point into /app/database (the persistent volume), e.g. sqlite://./database/kener.sqlite.db" }}
{{- end }}
{{- end }}
{{- if $sqlite }}
{{- if or (gt (int .Values.replicaCount) 1) .Values.autoscaling.enabled }}
{{- fail "SQLite supports a single Kener replica: use PostgreSQL or MySQL (database.url / database.existingSecret) to scale out" }}
{{- end }}
{{- range (include "kener.extraVolumeMounts" . | fromYamlArray) }}
{{- if eq (trimSuffix "/" (toString .mountPath)) "/app/database" }}
{{- fail "/app/database is mounted by the chart with SQLite: set persistence.existingClaim to your PVC instead of mounting it through volumes/volumeMounts or extraVolumes/extraVolumeMounts" }}
{{- end }}
{{- end }}
{{- end }}
{{- if .Values.redis.enabled }}
{{- if or .Values.redis.external.url .Values.redis.external.existingSecret }}
{{- fail "redis.external is only used with redis.enabled=false: pick the bundled Valkey or your own Redis" }}
{{- end }}
{{- if and .Values.redis.auth.password (not .Values.redis.auth.existingSecret) (not (regexMatch "^[A-Za-z0-9._~-]+$" .Values.redis.auth.password)) }}
{{- fail "redis.auth.password is embedded in REDIS_URL: use only A-Z a-z 0-9 . _ ~ - (or leave it empty to generate one)" }}
{{- end }}
{{- else }}
{{- if not (or .Values.redis.external.url .Values.redis.external.existingSecret) }}
{{- fail "Kener 4 requires Redis: keep redis.enabled=true (bundled Valkey) or set redis.external.url / redis.external.existingSecret" }}
{{- end }}
{{- if and .Values.redis.external.url (not .Values.redis.external.existingSecret) (not (regexMatch "^rediss?://" .Values.redis.external.url)) }}
{{- fail "redis.external.url must start with redis:// or rediss://" }}
{{- end }}
{{- end }}
{{- with .Values.email.smtp }}
{{- if and .host (not (and .user .fromEmail .port (or .password .existingSecret))) }}
{{- fail "email.smtp needs host, port, user, fromEmail and a password (password or existingSecret): Kener ignores an incomplete SMTP environment" }}
{{- end }}
{{- end }}
{{- with .Values.email.resend }}
{{- if and (or .apiKey .existingSecret) (not .senderEmail) }}
{{- fail "email.resend.senderEmail is required with a Resend API key" }}
{{- end }}
{{- end }}
{{- range .Values.extraEnv }}
{{- if and (eq (toString .name) "NODE_OPTIONS") (hasKey . "value") (not (contains "--experimental-strip-types" (toString .value))) }}
{{- fail "NODE_OPTIONS in extraEnv must keep --experimental-strip-types: Kener loads its TypeScript migrations at runtime" }}
{{- end }}
{{- end }}
{{- end }}
