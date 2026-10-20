{{/*
Expand the name of the chart.
*/}}
{{- define "openeverest-database-tools.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "openeverest-database-tools.fullname" -}}
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
{{- define "openeverest-database-tools.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "openeverest-database-tools.labels" -}}
helm.sh/chart: {{ include "openeverest-database-tools.chart" . }}
{{ include "openeverest-database-tools.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "openeverest-database-tools.selectorLabels" -}}
app.kubernetes.io/name: {{ include "openeverest-database-tools.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Namespace of the DatabaseClusters, where every resource of the chart is created.
*/}}
{{- define "openeverest-database-tools.namespace" -}}
{{- .Values.global.namespace | default .Release.Namespace }}
{{- end }}

{{/*
"true" when the chart creates the ServiceAccount of the Jobs. `default` was the former default value of
rbac.serviceAccountName: it is ignored so that the Jobs no longer run as the namespace default account.
*/}}
{{- define "openeverest-database-tools.createServiceAccount" -}}
{{- $name := .Values.rbac.serviceAccountName | default "" }}
{{- if and .Values.rbac.create (or (eq $name "") (eq $name "default")) }}true{{ end }}
{{- end }}

{{/*
Name of the ServiceAccount the Jobs run as.
*/}}
{{- define "openeverest-database-tools.serviceAccountName" -}}
{{- if include "openeverest-database-tools.createServiceAccount" . }}
{{- include "openeverest-database-tools.fullname" . }}
{{- else }}
{{- .Values.rbac.serviceAccountName | default "default" }}
{{- end }}
{{- end }}

{{/*
Per-engine defaults. Component names are kept from previous releases (MySQL jobs keep `mariadb-init`)
so that NetworkPolicies or dashboards selecting them keep working.
*/}}
{{- define "openeverest-database-tools.engine" -}}
{{- if eq . "postgresql" }}
component: postgresql-init
container: init-postgresql
hostKey: pgbouncer-host
port: 5432
sslMode: require
{{- else if eq . "mysql" }}
component: mariadb-init
container: init-mariadb
hostKey: host
port: 3306
sslMode: PREFERRED
{{- else }}
component: mongodb-init
container: init-mongodb
hostKey: host
port: 27017
sslMode: ""
{{- end }}
{{- end }}

{{/*
Image reference. Accepts a {repository, tag, digest} object or a full reference string.
Usage: include "openeverest-database-tools.image" (dict "image" $image "default" $defaultImage)
*/}}
{{- define "openeverest-database-tools.image" -}}
{{- $image := .image | default .default }}
{{- if and (kindIs "map" $image) (kindIs "map" .default) }}
{{- $image = merge (dict) $image .default }}
{{- end }}
{{- $ref := "" }}
{{- if kindIs "string" $image }}
{{- $ref = $image }}
{{- else if not (and (kindIs "map" $image) $image.repository (or $image.tag $image.digest)) }}
{{- fail (printf "invalid image %s: expected a reference string or {repository, tag, digest}" (toJson $image)) }}
{{- else if $image.digest }}
{{- $ref = printf "%s@%s" $image.repository $image.digest }}
{{- else }}
{{- $ref = printf "%s:%s" $image.repository (toString $image.tag) }}
{{- end }}
{{- if regexMatch "^((docker\\.io|index\\.docker\\.io)/)?(library/)?alpine([:@].*)?$" $ref }}
{{- fail (printf "image %q: the Jobs no longer install database clients at runtime (apk add). Remove the override or use an image that ships the client (see image.* in values.yaml)." $ref) }}
{{- end }}
{{- $ref }}
{{- end }}

{{/*
Name of a Job and of its ConfigMap: the entry name followed by a hash of everything that shapes the Job.
A changed Job gets a new name, so `helm upgrade` never patches an immutable Job spec, and it runs again.
Usage: include "openeverest-database-tools.jobName" (dict "root" $ "db" $db "engine" "postgresql")
*/}}
{{- define "openeverest-database-tools.jobName" -}}
{{- $images := pick .root.Values.image .engine "kubectl" "pullPolicy" }}
{{- $inputs := dict "engine" .engine "db" .db "values" (omit .root.Values "databases" "image") "images" $images "chart" .root.Chart.Version }}
{{- printf "%s-%s" (.db.name | toString | trunc 54 | trimSuffix "-") (toJson $inputs | sha256sum | trunc 8) }}
{{- end }}

{{/*
Value of an entry setting, falling back to the global one (0 and null are honoured), as a one-element JSON array
(read it back with `fromJsonArray | first`).
Usage: include "openeverest-database-tools.setting" (dict "root" $ "db" $db "key" "backoffLimit")
*/}}
{{- define "openeverest-database-tools.setting" -}}
{{- if hasKey .db .key }}
{{- toJson (list (index .db .key)) }}
{{- else }}
{{- toJson (list (index .root.Values.global .key)) }}
{{- end }}
{{- end }}

{{/*
Environment variable read from the admin credentials Secret, or set from a literal entry value.
Usage: include "openeverest-database-tools.adminEnv" (dict "name" "PGUSER" "value" $db.adminUser "secret" $secret "key" "user")
*/}}
{{- define "openeverest-database-tools.adminEnv" -}}
- name: {{ .name }}
{{- if .value }}
  value: {{ .value | toString | quote }}
{{- else }}
  valueFrom:
    secretKeyRef:
      name: {{ .secret | quote }}
      key: {{ .key | quote }}
{{- end }}
{{- end }}

{{/*
Admin connection settings (host, port, user, password) shared by every engine.
Usage: include "openeverest-database-tools.connectionEnv" (dict "db" $db "engine" $engine "hostVar" "PGHOST" "portVar" "PGPORT" "userVar" "PGUSER" "passwordVar" "PGPASSWORD")
*/}}
{{- define "openeverest-database-tools.connectionEnv" -}}
{{- $db := .db }}
{{- $secret := $db.adminCredentialsSecret | default $db.credentialsSecret }}
{{- include "openeverest-database-tools.adminEnv" (dict "name" .hostVar "value" $db.host "secret" $secret "key" ($db.hostKey | default .engine.hostKey)) }}
- name: {{ .portVar }}
  value: {{ $db.port | default .engine.port | toString | quote }}
{{ include "openeverest-database-tools.adminEnv" (dict "name" .userVar "value" $db.adminUser "secret" $secret "key" ($db.userKey | default "user")) }}
- name: {{ .passwordVar }}
  valueFrom:
    secretKeyRef:
      name: {{ $secret | quote }}
      key: {{ $db.passwordKey | default "password" | quote }}
{{- range $i, $user := $db.users }}
- name: APP_USERNAME_{{ $i }}
  valueFrom:
    secretKeyRef:
      name: {{ $user.credentialsSecret | quote }}
      key: {{ $user.usernameKey | default "username" | quote }}
- name: APP_PASSWORD_{{ $i }}
  valueFrom:
    secretKeyRef:
      name: {{ $user.credentialsSecret | quote }}
      key: {{ $user.passwordKey | default "password" | quote }}
{{- end }}
{{- end }}

{{/*
Validate values that would otherwise produce a broken or unsafe Job.
Names end up in SQL, JavaScript and kubectl arguments: they are restricted to safe characters.
*/}}
{{- define "openeverest-database-tools.validate" -}}
{{- $k8sName := "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" }}
{{- $k8sSubdomain := "^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$" }}
{{- $dbName := "^[A-Za-z0-9_][A-Za-z0-9_-]{0,62}$" }}
{{- $policies := list "OnFailure" "Never" }}
{{- if not (has .Values.global.restartPolicy $policies) }}
{{- fail (printf "global.restartPolicy must be OnFailure or Never (got %q)" (toString .Values.global.restartPolicy)) }}
{{- end }}
{{- with .Values.global.namespace }}
{{- if not (regexMatch $k8sName .) }}
{{- fail (printf "global.namespace %q is not a valid namespace name" .) }}
{{- end }}
{{- end }}
{{- $seen := dict }}
{{- range $engine := list "postgresql" "mysql" "mongodb" }}
{{- $entries := index ($.Values.databases | default dict) $engine | default list }}
{{- if not (kindIs "slice" $entries) }}
{{- fail (printf "databases.%s must be a list" $engine) }}
{{- end }}
{{- range $i, $db := $entries }}
{{- $where := printf "databases.%s[%d]" $engine $i }}
{{- if not (kindIs "map" $db) }}
{{- fail (printf "%s must be an object" $where) }}
{{- end }}
{{- $name := $db.name | default "" | toString }}
{{- if or (not (regexMatch $k8sName $name)) (gt (len $name) 63) }}
{{- fail (printf "%s.name %q is required and must be a DNS label (lowercase letters, digits and '-', 63 characters max)" $where $name) }}
{{- end }}
{{- if hasKey $seen $name }}
{{- fail (printf "%s.name %q is used by several entries" $where $name) }}
{{- end }}
{{- $_ := set $seen $name true }}
{{- if not (regexMatch $k8sSubdomain ($db.clusterName | default "" | toString)) }}
{{- fail (printf "%s.clusterName is required and must be the name of a DatabaseCluster" $where) }}
{{- end }}
{{- if not ($db.adminCredentialsSecret | default $db.credentialsSecret) }}
{{- fail (printf "%s.adminCredentialsSecret is required (Secret holding the admin user and password)" $where) }}
{{- end }}
{{- with $db.port }}
{{- if not (regexMatch "^[0-9]{1,5}$" (toString .)) }}
{{- fail (printf "%s.port must be a port number" $where) }}
{{- end }}
{{- end }}
{{- with $db.restartPolicy }}
{{- if not (has . $policies) }}
{{- fail (printf "%s.restartPolicy must be OnFailure or Never" $where) }}
{{- end }}
{{- end }}
{{- range $key := list "databases" "users" "initScripts" "collections" "env" "extraEnv" }}
{{- if and (index $db $key) (not (kindIs "slice" (index $db $key))) }}
{{- fail (printf "%s.%s must be a list" $where $key) }}
{{- end }}
{{- end }}
{{- range $db.databases }}
{{- if not (regexMatch $dbName (toString .)) }}
{{- fail (printf "%s.databases: %q is not a valid database name (letters, digits, '_' and '-', 63 characters max)" $where (toString .)) }}
{{- end }}
{{- end }}
{{- with $db.initScriptsDatabase }}
{{- if not (regexMatch $dbName (toString .)) }}
{{- fail (printf "%s.initScriptsDatabase %q is not a valid database name" $where (toString .)) }}
{{- end }}
{{- end }}
{{- with $db.adminDatabase }}
{{- if not (regexMatch $dbName (toString .)) }}
{{- fail (printf "%s.adminDatabase %q is not a valid database name" $where (toString .)) }}
{{- end }}
{{- end }}
{{- with $db.sslMode }}
{{- if and (eq $engine "postgresql") (not (has . (list "disable" "allow" "prefer" "require" "verify-ca" "verify-full"))) }}
{{- fail (printf "%s.sslMode must be disable, allow, prefer, require, verify-ca or verify-full" $where) }}
{{- end }}
{{- if and (eq $engine "mysql") (not (has . (list "DISABLED" "PREFERRED" "REQUIRED" "VERIFY_CA" "VERIFY_IDENTITY"))) }}
{{- fail (printf "%s.sslMode must be DISABLED, PREFERRED, REQUIRED, VERIFY_CA or VERIFY_IDENTITY" $where) }}
{{- end }}
{{- end }}
{{- range $j, $user := $db.users }}
{{- if not (and (kindIs "map" $user) $user.credentialsSecret) }}
{{- fail (printf "%s.users[%d].credentialsSecret is required" $where $j) }}
{{- end }}
{{- range $user.databases }}
{{- if not (regexMatch $dbName (toString .)) }}
{{- fail (printf "%s.users[%d].databases: %q is not a valid database name" $where $j (toString .)) }}
{{- end }}
{{- end }}
{{- range $user.privileges }}
{{- if not (regexMatch "^[A-Za-z]+( [A-Za-z]+)*$" (toString .)) }}
{{- fail (printf "%s.users[%d].privileges: %q is not a privilege name" $where $j (toString .)) }}
{{- end }}
{{- end }}
{{- range $user.roles }}
{{- if not (regexMatch "^[A-Za-z][A-Za-z0-9_]*$" (toString .)) }}
{{- fail (printf "%s.users[%d].roles: %q is not a role name" $where $j (toString .)) }}
{{- end }}
{{- end }}
{{- end }}
{{- range $j, $c := $db.collections }}
{{- if not (and (kindIs "map" $c) (regexMatch "^[A-Za-z0-9_][A-Za-z0-9_.-]{0,119}$" ($c.name | default "" | toString)) (not (hasPrefix "system." ($c.name | toString)))) }}
{{- fail (printf "%s.collections[%d].name is required (letters, digits, '_', '.', '-'; not system.*)" $where $j) }}
{{- end }}
{{- if not (regexMatch $dbName ($c.database | default "" | toString)) }}
{{- fail (printf "%s.collections[%d].database is required and must be a valid database name" $where $j) }}
{{- end }}
{{- end }}
{{- with $db.authDatabase }}
{{- if not (regexMatch $dbName (toString .)) }}
{{- fail (printf "%s.authDatabase %q is not a valid database name" $where (toString .)) }}
{{- end }}
{{- end }}
{{- with $db.uriOptions }}
{{- if not (regexMatch "^[A-Za-z0-9_]+=[^&\\s]*(&[A-Za-z0-9_]+=[^&\\s]*)*$" (toString .)) }}
{{- fail (printf "%s.uriOptions must look like key=value&key=value" $where) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
ConfigMap + Job of one database entry.
Usage: include "openeverest-database-tools.job" (dict "root" $ "db" $db "engine" "postgresql")
*/}}
{{- define "openeverest-database-tools.job" -}}
{{- $root := .root }}
{{- $db := .db }}
{{- $engine := fromYaml (include "openeverest-database-tools.engine" .engine) }}
{{- $name := include "openeverest-database-tools.jobName" . }}
{{- $ns := include "openeverest-database-tools.namespace" $root }}
{{- $ctx := dict "root" $root "db" $db "engine" $engine "name" $name }}
{{- $_ := set $ctx "update" (include "openeverest-database-tools.setting" (dict "root" $root "db" $db "key" "updateUserPasswords") | fromJsonArray | first | default false) }}
{{- $_ := set $ctx "connectTimeout" (include "openeverest-database-tools.setting" (dict "root" $root "db" $db "key" "connectTimeoutSeconds") | fromJsonArray | first | int) }}
{{- $wait := include "openeverest-database-tools.setting" (dict "root" $root "db" $db "key" "waitForCluster") | fromJsonArray | first }}
{{- $waitTimeout := include "openeverest-database-tools.setting" (dict "root" $root "db" $db "key" "waitTimeoutSeconds") | fromJsonArray | first | int }}
{{- $ttl := include "openeverest-database-tools.setting" (dict "root" $root "db" $db "key" "ttlSecondsAfterFinished") | fromJsonArray | first }}
{{- $deadline := include "openeverest-database-tools.setting" (dict "root" $root "db" $db "key" "activeDeadlineSeconds") | fromJsonArray | first }}
{{- $backoff := include "openeverest-database-tools.setting" (dict "root" $root "db" $db "key" "backoffLimit") | fromJsonArray | first | int }}
{{- $restartPolicy := $db.restartPolicy | default $root.Values.global.restartPolicy }}
{{- $labels := merge (dict) (fromYaml (include "openeverest-database-tools.labels" $root)) (dict "app.kubernetes.io/component" $engine.component) ($db.labels | default dict) ($root.Values.labels | default dict) }}
{{- $podLabels := merge (dict) (fromYaml (include "openeverest-database-tools.selectorLabels" $root)) (dict "app.kubernetes.io/component" $engine.component) ($db.labels | default dict) ($root.Values.labels | default dict) }}
{{- $argocd := dict }}
{{- if $root.Values.global.argocd.enabled }}
{{- $argocd = dict "argocd.argoproj.io/hook" ($root.Values.global.argocd.hook | default "Sync") "argocd.argoproj.io/hook-delete-policy" ($root.Values.global.argocd.hookDeletePolicy | default "HookSucceeded") "argocd.argoproj.io/sync-options" ($root.Values.global.argocd.syncOptions | default "Replace=true") }}
{{- end }}
{{- $annotations := merge (dict) ($db.annotations | default dict) ($root.Values.annotations | default dict) $argocd ($root.Values.global.annotations | default dict) }}
{{- $podAnnotations := merge (dict "kubectl.kubernetes.io/default-container" $engine.container) ($db.podAnnotations | default dict) ($root.Values.podAnnotations | default dict) }}
{{- $podSecurityContext := mergeOverwrite (deepCopy ($root.Values.podSecurityContext | default dict)) (deepCopy ($root.Values.securityContext | default dict)) }}
{{- $resources := $db.resources | default $root.Values.resources }}
{{- $image := include "openeverest-database-tools.image" (dict "image" $db.image "default" (index $root.Values.image .engine)) }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ $name }}
  namespace: {{ $ns }}
  labels:
    {{- toYaml $labels | nindent 4 }}
immutable: true
data:
  {{- include (printf "openeverest-database-tools.%s.data" .engine) $ctx | nindent 2 }}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ $name }}
  namespace: {{ $ns }}
  labels:
    {{- toYaml $labels | nindent 4 }}
  {{- with $annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  backoffLimit: {{ $backoff }}
  {{- if not (kindIs "invalid" $ttl) }}
  ttlSecondsAfterFinished: {{ int $ttl }}
  {{- end }}
  {{- if not (kindIs "invalid" $deadline) }}
  activeDeadlineSeconds: {{ int $deadline }}
  {{- end }}
  template:
    metadata:
      labels:
        {{- toYaml $podLabels | nindent 8 }}
      annotations:
        {{- toYaml $podAnnotations | nindent 8 }}
    spec:
      restartPolicy: {{ $restartPolicy }}
      serviceAccountName: {{ include "openeverest-database-tools.serviceAccountName" $root }}
      # The API token is only projected into the kubectl wait containers (see the kube-api-access volume).
      automountServiceAccountToken: false
      enableServiceLinks: false
      {{- with $root.Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $root.Values.priorityClassName }}
      priorityClassName: {{ . }}
      {{- end }}
      {{- with $podSecurityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- if $wait }}
      initContainers:
        {{- range $step := list "created" "ready" }}
        - name: wait-cluster-{{ $step }}
          image: {{ include "openeverest-database-tools.image" (dict "image" $root.Values.image.kubectl "default" $root.Values.image.kubectl) | quote }}
          imagePullPolicy: {{ $root.Values.image.pullPolicy }}
          args:
            - wait
            {{- if eq $step "created" }}
            - --for=create
            {{- else }}
            - "--for=jsonpath={.status.status}=ready"
            {{- end }}
            - databaseclusters.everest.percona.com/{{ $db.clusterName }}
            - --namespace={{ $ns }}
            - --timeout={{ $waitTimeout }}s
          env:
            - name: HOME
              value: /tmp
          {{- with $root.Values.containerSecurityContext }}
          securityContext:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: kube-api-access
              mountPath: /var/run/secrets/kubernetes.io/serviceaccount
              readOnly: true
        {{- end }}
      {{- end }}
      containers:
        - name: {{ $engine.container }}
          image: {{ $image | quote }}
          imagePullPolicy: {{ $root.Values.image.pullPolicy }}
          {{- include (printf "openeverest-database-tools.%s.command" .engine) $ctx | nindent 10 }}
          env:
            - name: CLUSTER_NAME
              value: {{ $db.clusterName | quote }}
            - name: CONNECT_TIMEOUT
              value: {{ $ctx.connectTimeout | quote }}
            - name: HOME
              value: /tmp
            {{- include (printf "openeverest-database-tools.%s.env" .engine) $ctx | nindent 12 }}
            {{- with $root.Values.extraEnv }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
            {{- with $db.env }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
            {{- with $db.extraEnv }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
          {{- with $root.Values.containerSecurityContext }}
          securityContext:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          volumeMounts:
            - name: scripts
              mountPath: /scripts
              readOnly: true
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: scripts
          configMap:
            name: {{ $name }}
        # Memory backed: it may hold a client option file with the admin password.
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        {{- if $wait }}
        - name: kube-api-access
          projected:
            defaultMode: 420
            sources:
              - serviceAccountToken:
                  path: token
                  expirationSeconds: 3607
              - configMap:
                  name: kube-root-ca.crt
                  items:
                    - key: ca.crt
                      path: ca.crt
              - downwardAPI:
                  items:
                    - path: namespace
                      fieldRef:
                        apiVersion: v1
                        fieldPath: metadata.namespace
        {{- end }}
      {{- with $root.Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $root.Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $root.Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end }}
