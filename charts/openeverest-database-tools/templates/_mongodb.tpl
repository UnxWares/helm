{{/*
MongoDB client environment.
*/}}
{{- define "openeverest-database-tools.mongodb.env" -}}
{{- include "openeverest-database-tools.connectionEnv" (dict "db" .db "engine" .engine "hostVar" "MONGO_HOST" "portVar" "MONGO_PORT" "userVar" "MONGO_USER" "passwordVar" "MONGO_PASSWORD") }}
{{- end }}

{{/*
MongoDB client command: mongosh runs files/mongodb-init.js, which reads the credentials from the environment.
*/}}
{{- define "openeverest-database-tools.mongodb.command" -}}
command:
  - mongosh
  - --nodb
  - --quiet
  - --norc
  - --file
  - /scripts/init.js
{{- end }}

{{/*
ConfigMap data of a MongoDB Job: the static init.js, its config.json and the init scripts.
*/}}
{{- define "openeverest-database-tools.mongodb.data" -}}
{{- $db := .db }}
{{- $databases := $db.databases | default list }}
{{- $users := list }}
{{- range $i, $user := $db.users }}
{{- $roles := list }}
{{- range ($user.roles | default (list "readWrite")) }}
{{- $roles = append $roles (toString .) }}
{{- end }}
{{- $users = append $users (dict "index" $i "databases" ($user.databases | default list) "roles" $roles) }}
{{- end }}
{{- $collections := list }}
{{- range $db.collections }}
{{- $collections = append $collections (dict "name" (toString .name) "database" (toString .database)) }}
{{- end }}
{{- $scriptsDatabase := $db.initScriptsDatabase | default (ternary (first $databases) "admin" (gt (len $databases) 0)) }}
{{- $config := dict
  "authDatabase" ($db.authDatabase | default "admin")
  "uriOptions" ($db.uriOptions | default "")
  "connectTimeoutSeconds" .connectTimeout
  "updateUserPasswords" .update
  "databases" $databases
  "users" $users
  "collections" $collections
  "initScripts" (len ($db.initScripts | default list))
  "initScriptsDatabase" $scriptsDatabase
}}
{{- $data := dict "config.json" (printf "%s\n" (toPrettyJson $config)) "init.js" (.root.Files.Get "files/mongodb-init.js") }}
{{- range $i, $script := $db.initScripts }}
{{- $_ := set $data (printf "script-%d.js" $i) (printf "%s\n" (toString $script)) }}
{{- end }}
{{- toYaml $data }}
{{- end }}
