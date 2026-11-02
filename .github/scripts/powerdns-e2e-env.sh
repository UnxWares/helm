#!/usr/bin/env bash
# shellcheck disable=SC2016 # the script given to kubectl exec expands in the container's shell
# Database servers of the powerdns end-to-end test, in the current kubectl context: PostgreSQL with TLS (the gpgsql
# release checks the certificate with sslmode=verify-full, through the CA mounted with extraVolumes) and MySQL, in
# their own namespace. Both have a `pdns` user and database, whose password carries the characters that must survive
# the quoting (', ", \n, #, ;, $). The password Secret and the CA are created in the namespace of the releases.
#
# usage: powerdns-e2e-env.sh <namespace of the releases> <namespace of the databases>
set -euo pipefail

NS=$1
DB_NS=$2
# Throwaway test certificate and key, in a fresh temporary directory: nothing is deleted.
TMP=$(mktemp -d)

password() { head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24; }

for ns in "$NS" "$DB_NS"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# Secrets are created once: the servers keep the passwords they were started with, so a second run of this script
# must not replace them.
secret() { # namespace, name, kubectl create secret arguments
  kubectl -n "$1" get secret "$2" >/dev/null 2>&1 && return 0
  kubectl -n "$1" create secret "${@:3}" "$2"
}
secret "$DB_NS" powerdns-db generic --from-literal="password=$(password)'\"\\n#;\$x" \
  --from-literal="root-password=$(password)"
db_password=$(kubectl -n "$DB_NS" get secret powerdns-db -o jsonpath='{.data.password}' | base64 -d)
secret "$NS" powerdns-db generic --from-literal="password=$db_password"

if ! kubectl -n "$DB_NS" get secret powerdns-pg-tls >/dev/null 2>&1; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=powerdns-pg.$DB_NS.svc" \
    -addext "subjectAltName=DNS:powerdns-pg.$DB_NS.svc" -keyout "$TMP/tls.key" -out "$TMP/tls.crt" 2>/dev/null
  kubectl -n "$DB_NS" create secret tls powerdns-pg-tls --cert="$TMP/tls.crt" --key="$TMP/tls.key"
fi
kubectl -n "$DB_NS" get secret powerdns-pg-tls -o jsonpath='{.data.tls\.crt}' | base64 -d >"$TMP/ca.crt"
secret "$NS" powerdns-pg-ca generic --from-file=ca.crt="$TMP/ca.crt"

kubectl -n "$DB_NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: powerdns-pg
spec:
  selector:
    matchLabels: { app: powerdns-pg }
  template:
    metadata:
      labels: { app: powerdns-pg }
    spec:
      securityContext: { runAsUser: 70, runAsGroup: 70, fsGroup: 70 }
      containers:
        - name: postgres
          image: docker.io/library/postgres:18-alpine
          args: ["-c", "ssl=on", "-c", "ssl_cert_file=/tls/tls.crt", "-c", "ssl_key_file=/tls/tls.key"]
          env:
            - { name: POSTGRES_USER, value: pdns }
            - { name: POSTGRES_DB, value: pdns }
            - { name: POSTGRES_PASSWORD, valueFrom: { secretKeyRef: { name: powerdns-db, key: password } } }
            - { name: PGDATA, value: /var/lib/postgresql/data/pgdata }
          readinessProbe:
            exec: { command: ["pg_isready", "-U", "pdns", "-h", "127.0.0.1"] }
            periodSeconds: 3
          resources:
            limits: { memory: 256Mi }
          volumeMounts:
            - { name: tls, mountPath: /tls }
            - { name: data, mountPath: /var/lib/postgresql/data }
      volumes:
        - name: tls
          secret: { secretName: powerdns-pg-tls, defaultMode: 0640 }
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: powerdns-pg
spec:
  selector: { app: powerdns-pg }
  ports: [{ port: 5432 }]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: powerdns-mysql
spec:
  selector:
    matchLabels: { app: powerdns-mysql }
  template:
    metadata:
      labels: { app: powerdns-mysql }
    spec:
      containers:
        - name: mysql
          image: docker.io/library/mysql:8.4
          env:
            # The pdns user is created below: the image entrypoint does not escape a ' in MYSQL_PASSWORD.
            - { name: MYSQL_DATABASE, value: pdns }
            - { name: MYSQL_ROOT_PASSWORD, valueFrom: { secretKeyRef: { name: powerdns-db, key: root-password } } }
          readinessProbe:
            exec: { command: ["mysqladmin", "ping", "-h", "127.0.0.1", "--silent"] }
            periodSeconds: 3
          resources:
            limits: { memory: 768Mi }
          volumeMounts:
            - { name: data, mountPath: /var/lib/mysql }
      volumes:
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: powerdns-mysql
spec:
  selector: { app: powerdns-mysql }
  ports: [{ port: 3306 }]
EOF

kubectl -n "$DB_NS" rollout status deploy/powerdns-pg --timeout=300s
kubectl -n "$DB_NS" rollout status deploy/powerdns-mysql --timeout=600s

# The password reaches MySQL hex-encoded and is quoted by QUOTE(), whatever characters it holds.
hex=$(printf '%s' "$db_password" | od -An -tx1 | tr -d ' \n')
kubectl -n "$DB_NS" exec -i deploy/powerdns-mysql -- sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot' <<EOF
SET @create = CONCAT('CREATE USER IF NOT EXISTS ''pdns''@''%'' IDENTIFIED BY ', QUOTE(CONVERT(UNHEX('$hex') USING utf8mb4)));
PREPARE create_user FROM @create;
EXECUTE create_user;
GRANT ALL PRIVILEGES ON pdns.* TO 'pdns'@'%';
EOF
