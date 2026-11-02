#!/usr/bin/env bash
# shellcheck disable=SC2016 # the scripts given to kubectl exec expand in the container's shell
# Test environment of the openeverest-database-tools end-to-end test, in the current kubectl context:
# - a stand-in for the OpenEverest operator: a minimal DatabaseCluster CRD and three clusters, reported ready
#   once their server is;
# - real PostgreSQL (TLS, as OpenEverest's PgBouncer), MySQL and MongoDB (replica set rs0) servers;
# - the credential Secrets, with the keys OpenEverest uses, and the application users' Secrets.
#
# usage: openeverest-test-env.sh
set -euo pipefail

NS=everest-databases
TMP=$(mktemp -d)
trap 'rm -f -- "$TMP"/tls.crt "$TMP"/tls.key "$TMP"/mongo.key; rmdir -- "$TMP"' EXIT

password() { head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24; }

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: databaseclusters.everest.percona.com
spec:
  group: everest.percona.com
  scope: Namespaced
  names:
    kind: DatabaseCluster
    plural: databaseclusters
    singular: databasecluster
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources:
        status: {}
      schema:
        openAPIV3Schema:
          type: object
          x-kubernetes-preserve-unknown-fields: true
EOF
kubectl wait --for=condition=Established crd/databaseclusters.everest.percona.com --timeout=60s

# Secrets are created once: the servers keep the passwords they were started with, so a second run of this
# script must not replace them.
secret() {
  kubectl -n "$NS" get secret "$1" >/dev/null 2>&1 && return 0
  kubectl -n "$NS" create secret generic "$1" "${@:2}"
}

# Admin credentials, as OpenEverest stores them in everest-secrets-<cluster>.
secret everest-secrets-app-pg --from-literal=user=postgres --from-literal="password=$(password)" \
  --from-literal=pgbouncer-host=app-pg-pgbouncer
secret everest-secrets-app-mysql --from-literal="root=$(password)"
secret everest-secrets-app-mongo \
  --from-literal=MONGODB_USER_ADMIN_USER=userAdmin --from-literal="MONGODB_USER_ADMIN_PASSWORD=$(password)" \
  --from-literal=MONGODB_DATABASE_ADMIN_USER=databaseAdmin --from-literal="MONGODB_DATABASE_ADMIN_PASSWORD=$(password)" \
  --from-literal=MONGODB_ROOT_USER=root --from-literal="MONGODB_ROOT_PASSWORD=$(password)"
# Application users created by the Jobs. The names carry characters that must survive the quoting.
secret laravel-app-db --from-literal=username=laravel-app --from-literal="password=$(password)'\"\\;"
secret wordpress-db --from-literal=username=wordpress --from-literal="password=$(password)'\"\\;"
secret appdb-user --from-literal=username=appdb --from-literal="password=$(password)'\"\\;"

openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=app-pg-pgbouncer \
  -keyout "$TMP/tls.key" -out "$TMP/tls.crt" 2>/dev/null
kubectl -n "$NS" get secret app-pg-tls >/dev/null 2>&1 ||
  kubectl -n "$NS" create secret tls app-pg-tls --cert="$TMP/tls.crt" --key="$TMP/tls.key"
openssl rand -base64 756 > "$TMP/mongo.key"
secret app-mongo-keyfile --from-file=keyfile="$TMP/mongo.key"

kubectl -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-pg
spec:
  selector:
    matchLabels: { app: app-pg }
  template:
    metadata:
      labels: { app: app-pg }
    spec:
      securityContext: { runAsUser: 70, runAsGroup: 70, fsGroup: 70 }
      containers:
        - name: postgres
          image: docker.io/library/postgres:18-alpine
          args: ["-c", "ssl=on", "-c", "ssl_cert_file=/tls/tls.crt", "-c", "ssl_key_file=/tls/tls.key"]
          env:
            - { name: POSTGRES_USER, valueFrom: { secretKeyRef: { name: everest-secrets-app-pg, key: user } } }
            - { name: POSTGRES_PASSWORD, valueFrom: { secretKeyRef: { name: everest-secrets-app-pg, key: password } } }
            - { name: PGDATA, value: /var/lib/postgresql/data/pgdata }
          readinessProbe:
            exec: { command: ["pg_isready", "-U", "postgres", "-h", "127.0.0.1"] }
            periodSeconds: 3
          volumeMounts:
            - { name: tls, mountPath: /tls }
            - { name: data, mountPath: /var/lib/postgresql/data }
      volumes:
        - name: tls
          secret: { secretName: app-pg-tls, defaultMode: 0640 }
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: app-pg-pgbouncer
spec:
  selector: { app: app-pg }
  ports: [{ port: 5432 }]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-mysql
spec:
  selector:
    matchLabels: { app: app-mysql }
  template:
    metadata:
      labels: { app: app-mysql }
    spec:
      containers:
        - name: mysql
          image: docker.io/library/mysql:8.4
          env:
            - { name: MYSQL_ROOT_PASSWORD, valueFrom: { secretKeyRef: { name: everest-secrets-app-mysql, key: root } } }
            - { name: MYSQL_ROOT_HOST, value: "%" }
          readinessProbe:
            exec: { command: ["sh", "-c", "mysqladmin ping -uroot -p\"$MYSQL_ROOT_PASSWORD\" --protocol=TCP"] }
            periodSeconds: 3
---
apiVersion: v1
kind: Service
metadata:
  name: app-mysql-haproxy
spec:
  selector: { app: app-mysql }
  ports: [{ port: 3306 }]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-mongo
spec:
  selector:
    matchLabels: { app: app-mongo }
  template:
    metadata:
      labels: { app: app-mongo }
    spec:
      initContainers:
        # mongod wants a key file only its user can read.
        - name: keyfile
          image: docker.io/library/mongo:8.0
          command: ["sh", "-c", "cp /secret/keyfile /keyfile/keyfile && chmod 400 /keyfile/keyfile && chown 999:999 /keyfile/keyfile"]
          volumeMounts:
            - { name: keyfile-secret, mountPath: /secret }
            - { name: keyfile, mountPath: /keyfile }
      containers:
        - name: mongo
          image: docker.io/library/mongo:8.0
          args: ["--replSet", "rs0", "--keyFile", "/keyfile/keyfile", "--bind_ip_all"]
          env:
            - { name: MONGO_INITDB_ROOT_USERNAME, valueFrom: { secretKeyRef: { name: everest-secrets-app-mongo, key: MONGODB_ROOT_USER } } }
            - { name: MONGO_INITDB_ROOT_PASSWORD, valueFrom: { secretKeyRef: { name: everest-secrets-app-mongo, key: MONGODB_ROOT_PASSWORD } } }
          readinessProbe:
            exec: { command: ["mongosh", "--quiet", "--eval", "db.adminCommand('ping')"] }
            periodSeconds: 3
          volumeMounts:
            - { name: keyfile, mountPath: /keyfile }
      volumes:
        - name: keyfile-secret
          secret: { secretName: app-mongo-keyfile }
        - name: keyfile
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: app-mongo-rs0
spec:
  selector: { app: app-mongo }
  ports: [{ port: 27017 }]
EOF

for cluster in app-pg app-mysql app-mongo; do
  kubectl -n "$NS" apply -f - <<EOF
apiVersion: everest.percona.com/v1alpha1
kind: DatabaseCluster
metadata:
  name: $cluster
spec: {}
EOF
done

kubectl -n "$NS" rollout status deploy/app-pg deploy/app-mysql deploy/app-mongo --timeout=600s

# Single-member replica set, then the system users OpenEverest creates (user admin and database admin). The image
# entrypoint first runs a temporary server to create the root user, so the probe can pass before the final one:
# retry until the replica set has a primary.
kubectl -n "$NS" exec deploy/app-mongo -c mongo -- bash -c '
  auth=(-u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --quiet)
  for _ in $(seq 120); do
    mongosh "${auth[@]}" --eval "
      try { rs.status() } catch (e) { rs.initiate({ _id: \"rs0\", members: [{ _id: 0, host: \"app-mongo-rs0:27017\" }] }) }
      quit(db.hello().isWritablePrimary ? 0 : 1)" >/dev/null 2>&1 && exit 0
    sleep 2
  done
  echo "MongoDB replica set not ready" >&2
  exit 1
'
ua_user=$(kubectl -n "$NS" get secret everest-secrets-app-mongo -o jsonpath='{.data.MONGODB_USER_ADMIN_USER}' | base64 -d)
ua_pass=$(kubectl -n "$NS" get secret everest-secrets-app-mongo -o jsonpath='{.data.MONGODB_USER_ADMIN_PASSWORD}' | base64 -d)
da_user=$(kubectl -n "$NS" get secret everest-secrets-app-mongo -o jsonpath='{.data.MONGODB_DATABASE_ADMIN_USER}' | base64 -d)
da_pass=$(kubectl -n "$NS" get secret everest-secrets-app-mongo -o jsonpath='{.data.MONGODB_DATABASE_ADMIN_PASSWORD}' | base64 -d)
kubectl -n "$NS" exec -i deploy/app-mongo -c mongo -- bash -ec '
  read -r ua_user; read -r ua_pass; read -r da_user; read -r da_pass
  export ua_user ua_pass da_user da_pass
  mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --quiet --eval "
    const admin = db.getSiblingDB(\"admin\");
    const ensure = (user, pwd, roles) => admin.getUser(user) ? admin.updateUser(user, { pwd, roles }) : admin.createUser({ user, pwd, roles });
    ensure(process.env.ua_user, process.env.ua_pass, [\"userAdminAnyDatabase\"]);
    ensure(process.env.da_user, process.env.da_pass, [\"readWriteAnyDatabase\", \"dbAdminAnyDatabase\", \"clusterMonitor\"]);
  "
' <<EOF
$ua_user
$ua_pass
$da_user
$da_pass
EOF

for cluster in app-pg app-mysql app-mongo; do
  kubectl -n "$NS" patch databasecluster "$cluster" --subresource=status --type=merge -p '{"status":{"status":"ready"}}'
done
echo "OpenEverest test environment ready in namespace $NS"
