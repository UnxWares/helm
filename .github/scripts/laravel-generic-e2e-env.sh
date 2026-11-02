#!/usr/bin/env bash
# Environment of the laravel-generic end-to-end test, in the current kubectl context: the namespace of the releases,
# which enforces the restricted Pod Security Standard, and a PostgreSQL server in its own namespace with a `laravel`
# user and database. The password Secret (key `password`) is created in the namespace of the releases, for
# laravel.database.existingSecret; the password carries characters that must reach Laravel unchanged (#, ;, $).
#
# usage: laravel-generic-e2e-env.sh <namespace of the releases> <namespace of the database>
set -euo pipefail

NS=$1
DB_NS=$2

password() { head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24; }

for ns in "$NS" "$DB_NS"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done
kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=restricted --overwrite

# Secrets are created once: the server keeps the password it was started with, so a second run of this script must
# not replace it.
secret() { # namespace, name, kubectl create secret arguments
  kubectl -n "$1" get secret "$2" >/dev/null 2>&1 && return 0
  kubectl -n "$1" create secret "${@:3}" "$2"
}
secret "$DB_NS" laravel-generic-db generic --from-literal="password=$(password)#;\$x"
db_password=$(kubectl -n "$DB_NS" get secret laravel-generic-db -o jsonpath='{.data.password}' | base64 -d)
secret "$NS" laravel-generic-db generic --from-literal="password=$db_password"

kubectl -n "$DB_NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: laravel-generic-pg
spec:
  selector:
    matchLabels: { app: laravel-generic-pg }
  template:
    metadata:
      labels: { app: laravel-generic-pg }
    spec:
      securityContext: { runAsUser: 70, runAsGroup: 70, fsGroup: 70 }
      containers:
        - name: postgres
          image: docker.io/library/postgres:18.6-alpine3.24@sha256:10a5c69a83035ab5239f5620d708520e8b28f5aa1f2b20143e6024532edadfb5
          env:
            - { name: POSTGRES_USER, value: laravel }
            - { name: POSTGRES_DB, value: laravel }
            - { name: POSTGRES_PASSWORD, valueFrom: { secretKeyRef: { name: laravel-generic-db, key: password } } }
            - { name: PGDATA, value: /var/lib/postgresql/data/pgdata }
          readinessProbe:
            exec: { command: ["pg_isready", "-U", "laravel", "-h", "127.0.0.1"] }
            periodSeconds: 3
          resources:
            limits: { memory: 256Mi }
          volumeMounts:
            - { name: data, mountPath: /var/lib/postgresql/data }
      volumes:
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: laravel-generic-pg
spec:
  selector: { app: laravel-generic-pg }
  ports: [{ port: 5432 }]
EOF

kubectl -n "$DB_NS" rollout status deploy/laravel-generic-pg --timeout=300s
