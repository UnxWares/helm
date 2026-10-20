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
Common labels. The version label is the application image tag (the chart appVersion
is only the targeted Laravel major version).
*/}}
{{- define "laravel-generic.labels" -}}
helm.sh/chart: {{ include "laravel-generic.chart" . }}
{{ include "laravel-generic.selectorLabels" . }}
{{- with (.Values.image.tag | default .Chart.AppVersion | toString | trunc 63 | trimSuffix "-" | trimSuffix ".") }}
app.kubernetes.io/version: {{ . | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "laravel-generic.selectorLabels" -}}
app.kubernetes.io/name: {{ include "laravel-generic.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Selector labels of one component. Usage:
{{ include "laravel-generic.componentSelectorLabels" (dict "ctx" $ "component" "web") }}
*/}}
{{- define "laravel-generic.componentSelectorLabels" -}}
{{ include "laravel-generic.selectorLabels" .ctx }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Labels of a pod template: component selector labels, commonLabels and podLabels.
*/}}
{{- define "laravel-generic.podLabels" -}}
{{ include "laravel-generic.componentSelectorLabels" . }}
{{- with .ctx.Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- with .ctx.Values.podLabels }}
{{ toYaml . }}
{{- end }}
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
Render an image reference from {repository, tag, digest}; the digest takes precedence.
*/}}
{{- define "laravel-generic.image" -}}
{{- if .digest -}}
{{- printf "%s@%s" .repository .digest -}}
{{- else -}}
{{- printf "%s:%s" .repository (toString .tag) -}}
{{- end -}}
{{- end }}

{{/*
Absolute path inside the application image. Usage:
{{ include "laravel-generic.path" (dict "ctx" $ "path" "storage/logs") }}
*/}}
{{- define "laravel-generic.path" -}}
{{- $path := toString .path -}}
{{- if hasPrefix "/" $path -}}
{{- clean $path -}}
{{- else -}}
{{- clean (printf "%s/%s" .ctx.Values.appPath $path) -}}
{{- end -}}
{{- end }}

{{/*
Name of a sub-directory of a volume derived from an absolute path (/app/storage/app -> app-storage-app).
*/}}
{{- define "laravel-generic.subPath" -}}
{{- regexReplaceAll "[^a-zA-Z0-9_.]+" (trimAll "/" .) "-" -}}
{{- end }}

{{/*
Public directory of the application.
*/}}
{{- define "laravel-generic.publicPath" -}}
{{- include "laravel-generic.path" (dict "ctx" . "path" (.Values.publicPath | default "public")) -}}
{{- end }}

{{/*
"true" when the application uses SQLite.
*/}}
{{- define "laravel-generic.sqlite" -}}
{{- if and .Values.laravel.database.enabled (eq (toString .Values.laravel.database.connection) "sqlite") -}}
true
{{- end -}}
{{- end }}

{{/*
Path of the SQLite database file.
*/}}
{{- define "laravel-generic.sqlitePath" -}}
{{- include "laravel-generic.path" (dict "ctx" . "path" (.Values.laravel.database.database | default "storage/database/database.sqlite")) -}}
{{- end }}

{{/*
"true" when the web runtime is PHP-FPM behind the nginx sidecar.
*/}}
{{- define "laravel-generic.fpm" -}}
{{- if eq (toString .Values.workload.runtime.type) "fpm" -}}
true
{{- end -}}
{{- end }}

{{/*
"true" when the persistent volume cannot be attached to pods on different nodes.
*/}}
{{- define "laravel-generic.singleNodeVolume" -}}
{{- if and .Values.persistence.enabled (not (has "ReadWriteMany" .Values.persistence.accessModes)) -}}
true
{{- end -}}
{{- end }}

{{/*
Directories stored on the persistent volume, as a YAML map {mountPath: subPath}.
The directory of the SQLite database is added unless it is already inside a stored path.
*/}}
{{- define "laravel-generic.persistentMounts" -}}
{{- $mounts := dict -}}
{{- if .Values.persistence.enabled -}}
{{- range .Values.persistence.paths -}}
{{- $path := include "laravel-generic.path" (dict "ctx" $ "path" .) -}}
{{- $_ := set $mounts $path (include "laravel-generic.subPath" $path) -}}
{{- end -}}
{{- if include "laravel-generic.sqlite" . -}}
{{- $dir := dir (include "laravel-generic.sqlitePath" .) -}}
{{- $covered := false -}}
{{- range $p, $_ := $mounts -}}
{{- if or (eq $p $dir) (hasPrefix (printf "%s/" $p) $dir) -}}
{{- $covered = true -}}
{{- end -}}
{{- end -}}
{{- if not $covered -}}
{{- $_ := set $mounts $dir (include "laravel-generic.subPath" $dir) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- toYaml $mounts -}}
{{- end }}

{{/*
Writable directories backed by the "writable" emptyDir, as a YAML map {mountPath: subPath}.
In a pod that mounts the persistent volume, paths stored on it (or inside a stored path) are left out.
dict: ctx, persistence (bool: the pod mounts the persistent volume)
*/}}
{{- define "laravel-generic.writableMounts" -}}
{{- $ := .ctx -}}
{{- $persistent := dict -}}
{{- if .persistence -}}
{{- $persistent = include "laravel-generic.persistentMounts" $ | fromYaml -}}
{{- end -}}
{{- $mounts := dict -}}
{{- range $.Values.writablePaths -}}
{{- $path := include "laravel-generic.path" (dict "ctx" $ "path" .) -}}
{{- $stored := false -}}
{{- range $p, $_ := $persistent -}}
{{- if or (eq $p $path) (hasPrefix (printf "%s/" $p) $path) -}}
{{- $stored = true -}}
{{- end -}}
{{- end -}}
{{- if not $stored -}}
{{- $_ := set $mounts $path (include "laravel-generic.subPath" $path) -}}
{{- end -}}
{{- end -}}
{{- toYaml $mounts -}}
{{- end }}

{{/*
Name of the chart-managed secret.
*/}}
{{- define "laravel-generic.secretName" -}}
{{- include "laravel-generic.fullname" . }}
{{- end }}

{{/*
Name of the copy of the secret used by the migrations hook (pre-install: the release secret does not exist yet).
*/}}
{{- define "laravel-generic.migrationsSecretName" -}}
{{- printf "%s-migrations" (include "laravel-generic.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
APP_KEY: explicit value, else the key already stored in the release secret, else a new
"base64:" + 32 random bytes key. The generated key is cached for the whole render so the
release secret and the migrations secret always carry the same key.
*/}}
{{- define "laravel-generic.appKey" -}}
{{- if .Values.laravel.key.value -}}
{{- .Values.laravel.key.value -}}
{{- else if hasKey .Values "__laravelGenericAppKey" -}}
{{- index .Values "__laravelGenericAppKey" -}}
{{- else -}}
{{- $key := "" -}}
{{- $secret := lookup "v1" "Secret" .Release.Namespace (include "laravel-generic.secretName" .) -}}
{{- if and $secret $secret.data (index $secret.data "app-key") -}}
{{- $key = index $secret.data "app-key" | b64dec -}}
{{- else -}}
{{- $key = printf "base64:%s" (randBytes 32) -}}
{{- end -}}
{{- $_ := set .Values "__laravelGenericAppKey" $key -}}
{{- $key -}}
{{- end -}}
{{- end }}

{{/*
"true" when a value is neither null nor an empty string (false and 0 are values).
*/}}
{{- define "laravel-generic.isSet" -}}
{{- if not (or (kindIs "invalid" .) (eq (toString .) "")) -}}
true
{{- end -}}
{{- end }}

{{/*
Secret environment variables (APP_KEY excepted), as a YAML list of
{name, chartKey, value, existingSecret, existingKey}. An entry is stored in the chart secret
unless it comes from an existing secret.
*/}}
{{- define "laravel-generic.secretEntries" -}}
{{- $l := .Values.laravel -}}
{{- $entries := list -}}
{{- if and $l.database.enabled (not (include "laravel-generic.sqlite" .)) -}}
{{- $entries = append $entries (dict "name" "DB_PASSWORD" "chartKey" "db-password" "value" $l.database.password "existingSecret" $l.database.existingSecret "existingKey" $l.database.secretKeys.password) -}}
{{- end -}}
{{- if $l.redis.enabled -}}
{{- $entries = append $entries (dict "name" "REDIS_PASSWORD" "chartKey" "redis-password" "value" $l.redis.password "existingSecret" $l.redis.existingSecret "existingKey" $l.redis.secretKeys.password) -}}
{{- end -}}
{{- if $l.mail.enabled -}}
{{- $entries = append $entries (dict "name" "MAIL_PASSWORD" "chartKey" "mail-password" "value" $l.mail.password "existingSecret" $l.mail.existingSecret "existingKey" $l.mail.secretKeys.password) -}}
{{- end -}}
{{- if $l.aws.enabled -}}
{{- $entries = append $entries (dict "name" "AWS_ACCESS_KEY_ID" "chartKey" "aws-access-key-id" "value" $l.aws.access_key_id "existingSecret" $l.aws.existingSecret "existingKey" $l.aws.secretKeys.access_key_id) -}}
{{- $entries = append $entries (dict "name" "AWS_SECRET_ACCESS_KEY" "chartKey" "aws-secret-access-key" "value" $l.aws.secret_access_key "existingSecret" $l.aws.existingSecret "existingKey" $l.aws.secretKeys.secret_access_key) -}}
{{- end -}}
{{- range $name, $value := $l.secretEnv -}}
{{- $entries = append $entries (dict "name" $name "chartKey" $name "value" $value "existingSecret" "" "existingKey" "") -}}
{{- end -}}
{{- toYaml $entries -}}
{{- end }}

{{/*
Data of the chart-managed secret (base64 encoded), shared by the release secret and the
migrations hook secret.
*/}}
{{- define "laravel-generic.secretData" -}}
{{- if not .Values.laravel.key.existingSecret }}
app-key: {{ include "laravel-generic.appKey" . | b64enc | quote }}
{{- end }}
{{- range (include "laravel-generic.secretEntries" . | fromYamlArray) }}
{{- if and (not (and .existingSecret .existingKey)) (include "laravel-generic.isSet" .value) }}
{{ .chartKey }}: {{ .value | toString | b64enc | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Checksum of the values that end up in the chart secret (the generated APP_KEY is stable).
*/}}
{{- define "laravel-generic.secretChecksum" -}}
{{- $l := .Values.laravel -}}
{{- list $l.key $l.database.password $l.redis.password $l.mail.password $l.aws.access_key_id $l.aws.secret_access_key $l.secretEnv | toJson | sha256sum -}}
{{- end }}

{{/*
A plain environment variable, or a reference to an existing secret. Rendered only when set.
dict: name, value, existingSecret, secretKey
*/}}
{{- define "laravel-generic.envVar" -}}
{{- if and .existingSecret .secretKey }}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ .existingSecret }}
      key: {{ .secretKey }}
{{- else if include "laravel-generic.isSet" .value }}
- name: {{ .name }}
  value: {{ .value | toString | quote }}
{{- end }}
{{- end }}

{{/*
Application URL: laravel.url, else derived from the first Ingress host.
*/}}
{{- define "laravel-generic.appUrl" -}}
{{- if .Values.laravel.url -}}
{{- .Values.laravel.url -}}
{{- else if and .Values.ingress.enabled .Values.ingress.hosts -}}
{{- $host := (first .Values.ingress.hosts).host -}}
{{- $tls := false -}}
{{- range .Values.ingress.tls -}}
{{- if has $host .hosts -}}
{{- $tls = true -}}
{{- end -}}
{{- end -}}
{{- printf "%s://%s" (ternary "https" "http" $tls) $host -}}
{{- end -}}
{{- end }}

{{/*
Environment of every Laravel container. Secrets only come from secretKeyRef.
dict: ctx, secretName (chart secret to reference), web (bool: add the web runtime variables)
*/}}
{{- define "laravel-generic.env" -}}
{{- $ := .ctx -}}
{{- $secretName := .secretName -}}
{{- $l := $.Values.laravel -}}
- name: APP_NAME
  value: {{ $l.name | quote }}
- name: APP_ENV
  value: {{ $l.env | quote }}
- name: APP_KEY
  valueFrom:
    secretKeyRef:
      {{- if $l.key.existingSecret }}
      name: {{ $l.key.existingSecret }}
      key: {{ $l.key.existingSecretKey }}
      {{- else }}
      name: {{ $secretName }}
      key: app-key
      {{- end }}
- name: APP_DEBUG
  value: {{ $l.debug | toString | quote }}
{{- include "laravel-generic.envVar" (dict "name" "APP_URL" "value" (include "laravel-generic.appUrl" $)) }}
{{- include "laravel-generic.envVar" (dict "name" "APP_LOCALE" "value" $l.locale.default) }}
{{- include "laravel-generic.envVar" (dict "name" "APP_FALLBACK_LOCALE" "value" $l.locale.fallback) }}
{{- include "laravel-generic.envVar" (dict "name" "APP_FAKER_LOCALE" "value" $l.locale.faker) }}
{{- include "laravel-generic.envVar" (dict "name" "APP_MAINTENANCE_DRIVER" "value" $l.maintenance.driver) }}
{{- include "laravel-generic.envVar" (dict "name" "APP_MAINTENANCE_STORE" "value" $l.maintenance.store) }}
{{- include "laravel-generic.envVar" (dict "name" "PHP_CLI_SERVER_WORKERS" "value" $l.cli_server_workers) }}
{{- include "laravel-generic.envVar" (dict "name" "BCRYPT_ROUNDS" "value" $l.bcrypt_rounds) }}
{{- include "laravel-generic.envVar" (dict "name" "LOG_CHANNEL" "value" $l.log.channel) }}
{{- include "laravel-generic.envVar" (dict "name" "LOG_STACK" "value" $l.log.stack) }}
{{- include "laravel-generic.envVar" (dict "name" "LOG_DEPRECATIONS_CHANNEL" "value" $l.log.deprecations_channel) }}
{{- include "laravel-generic.envVar" (dict "name" "LOG_LEVEL" "value" $l.log.level) }}
{{- if $l.database.enabled }}
- name: DB_CONNECTION
  value: {{ $l.database.connection | quote }}
{{- if include "laravel-generic.sqlite" $ }}
- name: DB_DATABASE
  value: {{ include "laravel-generic.sqlitePath" $ | quote }}
{{- else }}
{{- $db := $l.database }}
{{- include "laravel-generic.envVar" (dict "name" "DB_HOST" "value" $db.host "existingSecret" $db.existingSecret "secretKey" $db.secretKeys.host) }}
{{- include "laravel-generic.envVar" (dict "name" "DB_PORT" "value" $db.port "existingSecret" $db.existingSecret "secretKey" $db.secretKeys.port) }}
{{- include "laravel-generic.envVar" (dict "name" "DB_DATABASE" "value" $db.database "existingSecret" $db.existingSecret "secretKey" $db.secretKeys.database) }}
{{- include "laravel-generic.envVar" (dict "name" "DB_USERNAME" "value" $db.username "existingSecret" $db.existingSecret "secretKey" $db.secretKeys.username) }}
{{- end }}
{{- end }}
{{- include "laravel-generic.envVar" (dict "name" "SESSION_DRIVER" "value" $l.session.driver) }}
{{- include "laravel-generic.envVar" (dict "name" "SESSION_LIFETIME" "value" $l.session.lifetime) }}
{{- include "laravel-generic.envVar" (dict "name" "SESSION_ENCRYPT" "value" $l.session.encrypt) }}
{{- include "laravel-generic.envVar" (dict "name" "SESSION_PATH" "value" $l.session.path) }}
{{- include "laravel-generic.envVar" (dict "name" "SESSION_DOMAIN" "value" $l.session.domain) }}
{{- include "laravel-generic.envVar" (dict "name" "BROADCAST_CONNECTION" "value" $l.broadcast_connection) }}
{{- include "laravel-generic.envVar" (dict "name" "FILESYSTEM_DISK" "value" $l.filesystem_disk) }}
{{- include "laravel-generic.envVar" (dict "name" "QUEUE_CONNECTION" "value" $l.queue_connection) }}
{{- include "laravel-generic.envVar" (dict "name" "CACHE_STORE" "value" $l.cache.store) }}
{{- include "laravel-generic.envVar" (dict "name" "CACHE_PREFIX" "value" $l.cache.prefix) }}
{{- include "laravel-generic.envVar" (dict "name" "MEMCACHED_HOST" "value" $l.memcached.host) }}
{{- if $l.redis.enabled }}
{{- $r := $l.redis }}
{{- include "laravel-generic.envVar" (dict "name" "REDIS_CLIENT" "value" $r.client) }}
{{- include "laravel-generic.envVar" (dict "name" "REDIS_HOST" "value" $r.host "existingSecret" $r.existingSecret "secretKey" $r.secretKeys.host) }}
{{- include "laravel-generic.envVar" (dict "name" "REDIS_PORT" "value" $r.port "existingSecret" $r.existingSecret "secretKey" $r.secretKeys.port) }}
{{- end }}
{{- if $l.mail.enabled }}
{{- $m := $l.mail }}
{{- include "laravel-generic.envVar" (dict "name" "MAIL_MAILER" "value" $m.mailer) }}
{{- include "laravel-generic.envVar" (dict "name" "MAIL_SCHEME" "value" $m.scheme) }}
{{- include "laravel-generic.envVar" (dict "name" "MAIL_HOST" "value" $m.host "existingSecret" $m.existingSecret "secretKey" $m.secretKeys.host) }}
{{- include "laravel-generic.envVar" (dict "name" "MAIL_PORT" "value" $m.port "existingSecret" $m.existingSecret "secretKey" $m.secretKeys.port) }}
{{- include "laravel-generic.envVar" (dict "name" "MAIL_USERNAME" "value" $m.username "existingSecret" $m.existingSecret "secretKey" $m.secretKeys.username) }}
{{- include "laravel-generic.envVar" (dict "name" "MAIL_FROM_ADDRESS" "value" $m.from.address) }}
{{- include "laravel-generic.envVar" (dict "name" "MAIL_FROM_NAME" "value" $m.from.name) }}
{{- end }}
{{- if $l.aws.enabled }}
{{- $a := $l.aws }}
{{- include "laravel-generic.envVar" (dict "name" "AWS_DEFAULT_REGION" "value" $a.region "existingSecret" $a.existingSecret "secretKey" $a.secretKeys.region) }}
{{- include "laravel-generic.envVar" (dict "name" "AWS_BUCKET" "value" $a.bucket "existingSecret" $a.existingSecret "secretKey" $a.secretKeys.bucket) }}
{{- include "laravel-generic.envVar" (dict "name" "AWS_ENDPOINT" "value" $a.endpoint) }}
{{- include "laravel-generic.envVar" (dict "name" "AWS_URL" "value" $a.url) }}
{{- include "laravel-generic.envVar" (dict "name" "AWS_USE_PATH_STYLE_ENDPOINT" "value" $a.use_path_style_endpoint "existingSecret" $a.existingSecret "secretKey" $a.secretKeys.use_path_style_endpoint) }}
{{- end }}
{{- if $l.vite.enabled }}
{{- include "laravel-generic.envVar" (dict "name" "VITE_APP_NAME" "value" $l.vite.app_name) }}
{{- end }}
{{- range (include "laravel-generic.secretEntries" $ | fromYamlArray) }}
{{- if and .existingSecret .existingKey }}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ .existingSecret }}
      key: {{ .existingKey }}
{{- else if include "laravel-generic.isSet" .value }}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: {{ .chartKey }}
{{- end }}
{{- end }}
{{- if and .web (not (include "laravel-generic.fpm" $)) }}
# Address the stock FrankenPHP Caddyfile listens on (plain HTTP on the runtime port).
- name: SERVER_NAME
  value: {{ $.Values.workload.runtime.frankenphp.serverName | default (printf ":%v" $.Values.workload.runtime.frankenphp.port) | quote }}
{{- end }}
{{- with $l.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
envFrom of every Laravel container.
*/}}
{{- define "laravel-generic.envFrom" -}}
{{- with .Values.laravel.extraEnvFrom -}}
envFrom:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Security context of the Laravel containers. With FrankenPHP, NET_BIND_SERVICE stays in the
bounding set of the web container: the official binary carries it as a file capability and cannot
be executed without it.
dict: ctx, web (bool)
*/}}
{{- define "laravel-generic.securityContext" -}}
{{- $ := .ctx -}}
{{- $sc := deepCopy ($.Values.securityContext | default dict) -}}
{{- if and .web (not (include "laravel-generic.fpm" $)) $.Values.workload.runtime.frankenphp.keepNetBindService -}}
{{- $caps := $sc.capabilities | default dict -}}
{{- $add := $caps.add | default list -}}
{{- if not (has "NET_BIND_SERVICE" $add) -}}
{{- $_ := set $caps "add" (append $add "NET_BIND_SERVICE") -}}
{{- end -}}
{{- $_ := set $sc "capabilities" $caps -}}
{{- end -}}
{{- with $sc }}
{{- toYaml . }}
{{- end }}
{{- end }}

{{/*
Volume mounts of the Laravel containers.
dict: ctx, persistence (bool), caddy (bool)
*/}}
{{- define "laravel-generic.appVolumeMounts" -}}
{{- $ := .ctx -}}
- name: tmp
  mountPath: /tmp
{{- range $path, $sub := (include "laravel-generic.writableMounts" (dict "ctx" $ "persistence" .persistence) | fromYaml) }}
- name: writable
  mountPath: {{ $path }}
  subPath: {{ $sub }}
{{- end }}
{{- if .persistence }}
{{- range $path, $sub := (include "laravel-generic.persistentMounts" $ | fromYaml) }}
- name: data
  mountPath: {{ $path }}
  subPath: {{ $sub }}
{{- end }}
{{- end }}
{{- if .caddy }}
# Caddy state and autosaved configuration (XDG_DATA_HOME / XDG_CONFIG_HOME of the FrankenPHP images).
- name: caddy
  mountPath: /data
  subPath: data
- name: caddy
  mountPath: /config
  subPath: config
{{- end }}
{{- with $.Values.extraVolumeMounts }}
{{ toYaml . }}
{{- end }}
{{- with $.Values.volumeMounts }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Volumes of a pod running Laravel.
dict: ctx, persistence (bool), caddy (bool), nginx (bool)
*/}}
{{- define "laravel-generic.appVolumes" -}}
{{- $ := .ctx -}}
{{- $sizeLimit := $.Values.emptyDirSizeLimit -}}
- name: tmp
  emptyDir:
    {{- with $sizeLimit }}
    sizeLimit: {{ . }}
    {{- else }} {}
    {{- end }}
- name: writable
  emptyDir:
    {{- with $sizeLimit }}
    sizeLimit: {{ . }}
    {{- else }} {}
    {{- end }}
{{- if .persistence }}
- name: data
  persistentVolumeClaim:
    claimName: {{ $.Values.persistence.existingClaim | default (include "laravel-generic.fullname" $) }}
{{- end }}
{{- if .caddy }}
- name: caddy
  emptyDir:
    {{- with $sizeLimit }}
    sizeLimit: {{ . }}
    {{- else }} {}
    {{- end }}
{{- end }}
{{- if .nginx }}
- name: public
  emptyDir:
    {{- with $sizeLimit }}
    sizeLimit: {{ . }}
    {{- else }} {}
    {{- end }}
- name: nginx-tmp
  emptyDir:
    sizeLimit: 256Mi
- name: nginx-config
  configMap:
    name: {{ include "laravel-generic.fullname" $ }}-nginx
{{- end }}
{{- with $.Values.extraVolumes }}
{{ toYaml . }}
{{- end }}
{{- with $.Values.volumes }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Init container preparing the volumes before Laravel starts. Runs the application image:
- seeds each writable emptyDir path with what the image ships there,
- creates the storage directories Laravel expects, wherever they live (emptyDir or persistent volume),
- copies the public directory for the nginx sidecar.
dict: ctx, public (bool), persistence (bool: the pod mounts the persistent volume)
*/}}
{{- define "laravel-generic.prepareContainer" -}}
{{- $ := .ctx -}}
{{- $writable := include "laravel-generic.writableMounts" (dict "ctx" $ "persistence" .persistence) | fromYaml -}}
{{- $persistent := dict -}}
{{- if .persistence -}}
{{- $persistent = include "laravel-generic.persistentMounts" $ | fromYaml -}}
{{- end -}}
{{- /* Directories Laravel expects, mapped to their location in the prepare container. */ -}}
{{- $dirs := list -}}
{{- range list "storage/framework/cache/data" "storage/framework/sessions" "storage/framework/views" "storage/logs" "storage/app/public" -}}
{{- $abs := include "laravel-generic.path" (dict "ctx" $ "path" .) -}}
{{- $best := "" -}}
{{- $target := "" -}}
{{- range $root, $sets := dict "/chart/writable" $writable "/chart/data" $persistent -}}
{{- range $p, $sub := $sets -}}
{{- if and (or (eq $p $abs) (hasPrefix (printf "%s/" $p) $abs)) (gt (len $p) (len $best)) -}}
{{- $best = $p -}}
{{- $target = printf "%s/%s%s" $root $sub (trimPrefix $p $abs) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $target -}}
{{- $dirs = append $dirs $target -}}
{{- end -}}
{{- end -}}
{{- if or $writable $persistent .public -}}
- name: prepare
  image: {{ include "laravel-generic.image" $.Values.image | quote }}
  imagePullPolicy: {{ $.Values.image.pullPolicy }}
  {{- with (include "laravel-generic.securityContext" (dict "ctx" $)) }}
  securityContext:
    {{- . | nindent 4 }}
  {{- end }}
  command:
    - /bin/sh
    - -ec
    - |
      # copy <directory of the image> <directory of the volume>
      copy() {
        mkdir -p "$2"
        if [ -d "$1" ]; then
          cp -R "$1/." "$2/" || echo "warning: some files of $1 could not be copied"
        fi
      }
      {{- range $path, $sub := $writable }}
      {{- if $.Values.seedWritablePaths }}
      copy {{ $path | quote }} {{ printf "/chart/writable/%s" $sub | quote }}
      {{- else }}
      mkdir -p {{ printf "/chart/writable/%s" $sub | quote }}
      {{- end }}
      {{- end }}
      {{- range $persistent }}
      mkdir -p {{ printf "/chart/data/%s" . | quote }}
      {{- end }}
      {{- with $dirs }}
      mkdir -p{{ range . }} {{ . | quote }}{{ end }}
      {{- end }}
      {{- if .public }}
      copy {{ include "laravel-generic.publicPath" $ | quote }} /chart/public
      {{- end }}
  {{- with $.Values.prepareResources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  volumeMounts:
    - name: tmp
      mountPath: /tmp
    {{- if $writable }}
    - name: writable
      mountPath: /chart/writable
    {{- end }}
    {{- if $persistent }}
    - name: data
      mountPath: /chart/data
    {{- end }}
    {{- if .public }}
    - name: public
      mountPath: /chart/public
    {{- end }}
{{- end }}
{{- end }}

{{/*
Container running an artisan command (scheduler, migrations).
dict: ctx, name, command, resources, secretName, persistence (bool)
*/}}
{{- define "laravel-generic.cliContainer" -}}
{{- $ := .ctx -}}
- name: {{ .name }}
  image: {{ include "laravel-generic.image" $.Values.image | quote }}
  imagePullPolicy: {{ $.Values.image.pullPolicy }}
  {{- with (include "laravel-generic.securityContext" (dict "ctx" $)) }}
  securityContext:
    {{- . | nindent 4 }}
  {{- end }}
  command:
    {{- toYaml .command | nindent 4 }}
  env:
    {{- include "laravel-generic.env" (dict "ctx" $ "secretName" .secretName) | nindent 4 }}
  {{- with (include "laravel-generic.envFrom" $) }}
  {{- . | nindent 2 }}
  {{- end }}
  {{- with .resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  volumeMounts:
    {{- include "laravel-generic.appVolumeMounts" (dict "ctx" $ "persistence" .persistence) | nindent 4 }}
{{- end }}

{{/*
Scheduling and security fields shared by every pod.
dict: ctx, nodeSelector, tolerations, affinity (component overrides, empty: top-level values),
serviceAccount (bool: use the release service account), colocate (bool: required pod affinity
with the web pods, for a ReadWriteOnce volume)
*/}}
{{- define "laravel-generic.podCommon" -}}
{{- $ := .ctx -}}
{{- with $.Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- if .serviceAccount }}
serviceAccountName: {{ include "laravel-generic.serviceAccountName" $ }}
{{- end }}
automountServiceAccountToken: {{ $.Values.serviceAccount.automount }}
{{- with $.Values.priorityClassName }}
priorityClassName: {{ . }}
{{- end }}
{{- with $.Values.podSecurityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with (.nodeSelector | default $.Values.nodeSelector) }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with (.tolerations | default $.Values.tolerations) }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- $affinity := deepCopy (.affinity | default $.Values.affinity | default dict) }}
{{- if .colocate }}
{{- $web := include "laravel-generic.componentSelectorLabels" (dict "ctx" $ "component" "web") | fromYaml }}
{{- $term := dict "labelSelector" (dict "matchLabels" $web) "topologyKey" "kubernetes.io/hostname" }}
{{- $affinity = merge $affinity (dict "podAffinity" (dict "requiredDuringSchedulingIgnoredDuringExecution" (list $term))) }}
{{- end }}
{{- with $affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Validate values that would otherwise produce a broken deployment.
*/}}
{{- define "laravel-generic.validate" -}}
{{- if not .Values.image.repository }}
{{- fail "image.repository is required: set it to your Laravel application image (e.g. registry.example.com/acme/shop)" }}
{{- end }}
{{- if and (not .Values.image.tag) (not .Values.image.digest) }}
{{- fail (printf "image.tag (or image.digest) is required: the chart appVersion (%s) is the targeted Laravel version, not a tag of your application image" .Chart.AppVersion) }}
{{- end }}
{{- if not (has (toString .Values.workload.runtime.type) (list "frankenphp" "fpm")) }}
{{- fail (printf "workload.runtime.type must be frankenphp or fpm (got %q)" (toString .Values.workload.runtime.type)) }}
{{- end }}
{{- if not (has (toString .Values.workload.scheduler.mode) (list "cronjob" "deployment")) }}
{{- fail (printf "workload.scheduler.mode must be cronjob or deployment (got %q)" (toString .Values.workload.scheduler.mode)) }}
{{- end }}
{{- $scaled := or (gt (int .Values.replicaCount) 1) .Values.autoscaling.enabled }}
{{- if include "laravel-generic.sqlite" . }}
{{- if not .Values.persistence.enabled }}
{{- fail "laravel.database.connection=sqlite keeps the database on the persistent volume: set persistence.enabled=true (or persistence.existingClaim), or use an external database (pgsql, mysql...)" }}
{{- end }}
{{- if $scaled }}
{{- fail "SQLite supports a single web replica: set replicaCount=1 and autoscaling.enabled=false, or use an external database (pgsql, mysql...) to scale out" }}
{{- end }}
{{- $dbDir := dir (include "laravel-generic.sqlitePath" .) }}
{{- $appPath := include "laravel-generic.path" (dict "ctx" . "path" ".") }}
{{- if has $dbDir (list $appPath (printf "%s/database" $appPath) (include "laravel-generic.publicPath" .) "/") }}
{{- fail (printf "laravel.database.database: the SQLite file needs a dedicated directory (it is mounted from the persistent volume and would hide %s): use e.g. %s/storage/database/database.sqlite" $dbDir $appPath) }}
{{- end }}
{{- else if .Values.laravel.database.enabled }}
{{- $db := .Values.laravel.database }}
{{- if and (not $db.host) (not (and $db.existingSecret $db.secretKeys.host)) }}
{{- fail (printf "laravel.database.host is required with the %s connection (or laravel.database.existingSecret + secretKeys.host)" (toString $db.connection)) }}
{{- end }}
{{- if and (not $db.password) (not (and $db.existingSecret $db.secretKeys.password)) }}
{{- fail "laravel.database.password or laravel.database.existingSecret (+ secretKeys.password) is required" }}
{{- end }}
{{- end }}
{{- if and (include "laravel-generic.singleNodeVolume" .) $scaled }}
{{- fail "persistence uses a ReadWriteOnce volume, which pods on several nodes cannot share: keep replicaCount=1 without autoscaling, use a ReadWriteMany storage class (persistence.accessModes=[ReadWriteMany]), or disable persistence and store files on S3" }}
{{- end }}
{{- if and .Values.persistence.enabled (not .Values.persistence.paths) (not (include "laravel-generic.sqlite" .)) }}
{{- fail "persistence.paths is empty: list the directories to store on the persistent volume (e.g. storage/app)" }}
{{- end }}
{{- end }}
