{{/*
PostgreSQL client environment (libpq variables).
*/}}
{{- define "openeverest-database-tools.postgresql.env" -}}
{{- $db := .db }}
{{- include "openeverest-database-tools.connectionEnv" (dict "db" $db "engine" .engine "hostVar" "PGHOST" "portVar" "PGPORT" "userVar" "PGUSER" "passwordVar" "PGPASSWORD") }}
- name: PGDATABASE
  value: {{ $db.adminDatabase | default "postgres" | quote }}
- name: PGSSLMODE
  value: {{ $db.sslMode | default .engine.sslMode | quote }}
- name: PGCONNECT_TIMEOUT
  value: "10"
- name: PGAPPNAME
  value: openeverest-database-tools
{{- with $db.initScriptsDatabase }}
- name: INIT_SCRIPTS_DATABASE
  value: {{ . | quote }}
{{- end }}
{{- end }}

{{/*
PostgreSQL client command: wait until the admin user can log in, then run the generated script and the init scripts.
*/}}
{{- define "openeverest-database-tools.postgresql.command" -}}
command:
  - /bin/sh
  - -ec
  - |
    echo "=== PostgreSQL initialization (DatabaseCluster $CLUSTER_NAME) ==="
    deadline=$(( $(date +%s) + CONNECT_TIMEOUT ))
    until psql -X -A -t -q -c 'SELECT 1' >/dev/null; do
      if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "Timed out connecting to PostgreSQL at $PGHOST:$PGPORT"
        exit 1
      fi
      echo "Waiting for PostgreSQL at $PGHOST:$PGPORT..."
      sleep 5
    done
    psql -X -v ON_ERROR_STOP=1 -f /scripts/init.sql
    {{- range $i, $script := .db.initScripts }}
    echo "Running init script {{ add1 $i }}/{{ len $.db.initScripts }}"
    psql -X -v ON_ERROR_STOP=1 ${INIT_SCRIPTS_DATABASE:+-d "$INIT_SCRIPTS_DATABASE"} -f /scripts/script-{{ $i }}.sql
    {{- end }}
    echo "=== PostgreSQL initialization complete ==="
{{- end }}

{{/*
Generated psql script. Database names are validated (letters, digits, '_' and '-') and quoted with %I.
Usernames and passwords never appear in the script: \getenv reads them from the environment and
:'var' / %L quote them, so any character is safe.
*/}}
{{- define "openeverest-database-tools.postgresql.initSql" -}}
{{- $db := .db -}}
\set ON_ERROR_STOP on
{{- range $name := $db.databases }}
\echo Ensuring database {{ $name }}
SELECT format('CREATE DATABASE %I', '{{ $name }}') WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '{{ $name }}')\gexec
{{- end }}
{{- range $i, $user := $db.users }}
\getenv username APP_USERNAME_{{ $i }}
\getenv password APP_PASSWORD_{{ $i }}
\echo Ensuring role :username
{{- if $.update }}
SELECT CASE WHEN EXISTS (SELECT FROM pg_roles WHERE rolname = :'username') THEN format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'username', :'password') ELSE format('CREATE ROLE %I LOGIN PASSWORD %L', :'username', :'password') END\gexec
{{- else }}
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'username', :'password') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'username')\gexec
{{- end }}
\unset password
{{- range $name := $user.databases }}
\echo Granting database {{ $name }} to :username
SELECT format('ALTER DATABASE %I OWNER TO %I', '{{ $name }}', :'username')\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', '{{ $name }}', :'username')\gexec
\connect "{{ $name }}"
SELECT format('ALTER SCHEMA public OWNER TO %I', :'username')\gexec
REVOKE ALL ON SCHEMA public FROM PUBLIC;
SELECT format('GRANT ALL ON SCHEMA public TO %I', :'username')\gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO %I', :'username')\gexec
\connect "{{ $db.adminDatabase | default "postgres" }}"
{{- end }}
\unset username
{{- end }}
{{- end }}

{{/*
ConfigMap data of a PostgreSQL Job.
*/}}
{{- define "openeverest-database-tools.postgresql.data" -}}
{{- $data := dict "init.sql" (printf "%s\n" (include "openeverest-database-tools.postgresql.initSql" .)) }}
{{- range $i, $script := .db.initScripts }}
{{- $_ := set $data (printf "script-%d.sql" $i) (printf "%s\n" (toString $script)) }}
{{- end }}
{{- toYaml $data }}
{{- end }}
