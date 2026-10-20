{{/*
MySQL client environment.
*/}}
{{- define "openeverest-database-tools.mysql.env" -}}
{{- $db := .db }}
{{- include "openeverest-database-tools.connectionEnv" (dict "db" $db "engine" .engine "hostVar" "MYSQL_HOST" "portVar" "MYSQL_PORT" "userVar" "MYSQL_USER" "passwordVar" "MYSQL_PASSWORD") }}
- name: MYSQL_SSL_MODE
  value: {{ $db.sslMode | default .engine.sslMode | quote }}
{{- with $db.initScriptsDatabase }}
- name: INIT_SCRIPTS_DATABASE
  value: {{ . | quote }}
{{- end }}
{{- end }}

{{/*
MySQL client command. The admin credentials go to an option file (escaped for the option file parser) instead of
the command line. Usernames and passwords reach SQL hex-encoded, so no character can break out of the statement.
*/}}
{{- define "openeverest-database-tools.mysql.command" -}}
command:
  - /bin/bash
  - -c
  - |
    set -euo pipefail
    echo "=== MySQL initialization (DatabaseCluster $CLUSTER_NAME) ==="
    umask 077
    cnf() { local v=${2//\\/\\\\}; v=${v//\"/\\\"}; v=${v//$'\n'/\\n}; printf '%s="%s"\n' "$1" "$v"; }
    {
      printf '[client]\nprotocol=TCP\n'
      cnf host "$MYSQL_HOST"
      cnf port "$MYSQL_PORT"
      cnf user "$MYSQL_USER"
      cnf password "$MYSQL_PASSWORD"
      cnf ssl-mode "$MYSQL_SSL_MODE"
    } > /tmp/client.cnf
    run_mysql() { mysql --defaults-extra-file=/tmp/client.cnf --batch "$@"; }
    hex() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }
    deadline=$(( $(date +%s) + CONNECT_TIMEOUT ))
    until run_mysql --skip-column-names -e 'SELECT 1' >/dev/null; do
      if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "Timed out connecting to MySQL at $MYSQL_HOST:$MYSQL_PORT"
        exit 1
      fi
      echo "Waiting for MySQL at $MYSQL_HOST:$MYSQL_PORT..."
      sleep 5
    done
    if [ -s /scripts/databases.sql ]; then
      echo "Ensuring databases"
      run_mysql < /scripts/databases.sql
    fi
    {{- range $i, $user := .db.users }}
    echo "Ensuring user $APP_USERNAME_{{ $i }} and its grants"
    {
      printf "SET @u = CONVERT(UNHEX('%s') USING utf8mb4), @p = CONVERT(UNHEX('%s') USING utf8mb4);\n" \
        "$(hex "$APP_USERNAME_{{ $i }}")" "$(hex "$APP_PASSWORD_{{ $i }}")"
      cat /scripts/user-{{ $i }}.sql
    } | run_mysql
    {{- end }}
    {{- range $i, $script := .db.initScripts }}
    echo "Running init script {{ add1 $i }}/{{ len $.db.initScripts }}"
    run_mysql ${INIT_SCRIPTS_DATABASE:+--database="$INIT_SCRIPTS_DATABASE"} < /scripts/script-{{ $i }}.sql
    {{- end }}
    rm -f /tmp/client.cnf
    echo "=== MySQL initialization complete ==="
{{- end }}

{{/*
Generated statements for one user (@u and @p are set by the command from hex-encoded values).
QUOTE() escapes them for the prepared statement; database names and privileges are validated.
*/}}
{{- define "openeverest-database-tools.mysql.userSql" -}}
{{- $privileges := list }}
{{- range (.user.privileges | default (list "ALL PRIVILEGES")) }}
{{- $privileges = append $privileges (upper (toString .)) }}
{{- end -}}
SET SESSION sql_mode = REPLACE(@@SESSION.sql_mode, 'NO_BACKSLASH_ESCAPES', '');
SET @account = CONCAT(QUOTE(@u), '@''%''');
SET @s = CONCAT('CREATE USER IF NOT EXISTS ', @account, ' IDENTIFIED BY ', QUOTE(@p));
PREPARE stmt FROM @s;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
{{- if .update }}
SET @s = CONCAT('ALTER USER ', @account, ' IDENTIFIED BY ', QUOTE(@p));
PREPARE stmt FROM @s;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
{{- end }}
{{- range $name := .user.databases }}
SET @s = CONCAT('GRANT {{ join ", " $privileges }} ON `{{ $name }}`.* TO ', @account);
PREPARE stmt FROM @s;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
{{- end }}
SET @u = NULL, @p = NULL, @s = NULL, @account = NULL;
{{- end }}

{{/*
ConfigMap data of a MySQL Job.
*/}}
{{- define "openeverest-database-tools.mysql.data" -}}
{{- $databases := "" }}
{{- range .db.databases }}
{{- $databases = printf "%sCREATE DATABASE IF NOT EXISTS `%s`;\n" $databases (toString .) }}
{{- end }}
{{- $data := dict "databases.sql" $databases }}
{{- range $i, $user := .db.users }}
{{- $_ := set $data (printf "user-%d.sql" $i) (printf "%s\n" (include "openeverest-database-tools.mysql.userSql" (dict "user" $user "update" $.update))) }}
{{- end }}
{{- range $i, $script := .db.initScripts }}
{{- $_ := set $data (printf "script-%d.sql" $i) (printf "%s\n" (toString $script)) }}
{{- end }}
{{- toYaml $data }}
{{- end }}
