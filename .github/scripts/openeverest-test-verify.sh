#!/usr/bin/env bash
# shellcheck disable=SC2016 # the scripts given to kubectl exec expand in the container's shell
# Checks what the openeverest-database-tools Jobs of charts/openeverest-database-tools/ci/e2e-values.yaml created,
# logged in as the application users (not the admin): they can reach their database with the expected rights,
# no more, and the init scripts ran. Passwords go through stdin, never on a command line.
#
# usage: openeverest-test-verify.sh
set -euo pipefail

NS=everest-databases
secret() { kubectl -n "$NS" get secret "$1" -o "jsonpath={.data.$2}" | base64 -d; }
fail() { echo "FAIL: $*" >&2; exit 1; }
expect() { # description, expected, actual
  [ "$3" = "$2" ] || fail "$1: expected '$2', got '$3'"
  echo "ok: $1"
}

# --- PostgreSQL: laravel-app over TLS -----------------------------------------------------------------------------
pg() { # database, then psql arguments
  secret laravel-app-db password | kubectl -n "$NS" exec -i deploy/app-pg -- sh -c '
    IFS= read -r PGPASSWORD; export PGPASSWORD
    db=$1; shift
    psql "host=app-pg-pgbouncer sslmode=require user=laravel-app dbname=$db" -X -A -t -q -v ON_ERROR_STOP=1 "$@"
  ' sh "$@"
}
expect "PostgreSQL: laravel-app logs in over TLS" "laravel-app|t" \
  "$(pg laravel-app -c "SELECT current_user, ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()")"
expect "PostgreSQL: laravel-app owns its database" "laravel-app" \
  "$(pg laravel-app -c "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = current_database()")"
expect "PostgreSQL: init script created the pg_trgm extension" "1" \
  "$(pg laravel-app -c "SELECT count(*) FROM pg_extension WHERE extname = 'pg_trgm'")"
expect "PostgreSQL: laravel-app writes to the table of an init script" "e2e" \
  "$(pg laravel-app -c "INSERT INTO init_log (message) VALUES ('e2e') RETURNING message")"
pg laravel-app -c "CREATE TABLE IF NOT EXISTS created_by_app (id int)" >/dev/null || fail "PostgreSQL: laravel-app cannot create a table in its database"
echo "ok: PostgreSQL: laravel-app creates tables in its database"
if pg reporting -c "CREATE TABLE created_by_app (id int)" >/dev/null 2>&1; then
  fail "PostgreSQL: laravel-app created a table in reporting, a database it was not given"
fi
echo "ok: PostgreSQL: laravel-app cannot create tables in another database"

# --- MySQL: wordpress over TLS --------------------------------------------------------------------------------------
my() { # mysql arguments
  secret wordpress-db password | kubectl -n "$NS" exec -i deploy/app-mysql -- bash -c '
    IFS= read -r MYSQL_PWD; export MYSQL_PWD
    mysql --protocol=TCP -h app-mysql-haproxy -u wordpress --ssl-mode=REQUIRED --batch --skip-column-names "$@"
  ' bash "$@"
}
expect "MySQL: wordpress logs in" "wordpress@%" "$(my -e 'SELECT CURRENT_USER()')"
[ -n "$(my -e "SHOW SESSION STATUS LIKE 'Ssl_cipher'" | cut -f2)" ] || fail "MySQL: the session is not encrypted"
echo "ok: MySQL: the session is encrypted"
grants=$(my -e 'SHOW GRANTS')
for privilege in SELECT INSERT UPDATE DELETE CREATE ALTER INDEX DROP; do
  grep -E "GRANT .*\b${privilege}\b.* ON \`wordpress\`\.\*" <<<"$grants" >/dev/null || fail "MySQL: wordpress lacks $privilege on wordpress.*"
done
echo "ok: MySQL: wordpress has the configured privileges on wordpress.*"
grep -E 'ALL PRIVILEGES|GRANT OPTION|ON \*\.\*' <<<"$grants" | grep -v 'USAGE ON \*\.\*' && fail "MySQL: wordpress has more than the configured privileges"
echo "ok: MySQL: wordpress has no global privilege"
expect "MySQL: wordpress writes to the table of an init script" "e2e" \
  "$(my -e "INSERT INTO wordpress.init_log (message) VALUES ('e2e'); SELECT message FROM wordpress.init_log WHERE id = LAST_INSERT_ID()")"
if my -e 'SELECT COUNT(*) FROM mysql.user' >/dev/null 2>&1; then
  fail "MySQL: wordpress can read mysql.user"
fi
echo "ok: MySQL: wordpress cannot read the system tables"

# --- MongoDB: appdb -------------------------------------------------------------------------------------------------
mongo() { # JavaScript to evaluate as appdb on its database
  secret appdb-user password | kubectl -n "$NS" exec -i deploy/app-mongo -c mongo -- bash -c '
    IFS= read -r APP_PASSWORD; export APP_PASSWORD
    mongosh --quiet --norc --nodb --eval "
      const conn = Mongo(\"mongodb://\" + encodeURIComponent(\"appdb\") + \":\" + encodeURIComponent(process.env.APP_PASSWORD) +
        \"@app-mongo-rs0:27017/?authSource=appdb&replicaSet=rs0\");
      const db = conn.getDB(\"appdb\");
      $1
    "
  ' bash "$1"
}
expect "MongoDB: appdb logs in and writes to its database" "1" \
  "$(mongo 'db.users.deleteMany({ email: "e2e@example.test" }); print(db.users.insertOne({ email: "e2e@example.test" }).acknowledged ? 1 : 0)')"
expect "MongoDB: init script created the unique index" "E11000" \
  "$(mongo 'try { db.users.insertOne({ email: "e2e@example.test" }); print("inserted") } catch (e) { print(e.message.slice(0, 6)) }')"
expect "MongoDB: appdb cannot read another database" "denied" \
  "$(mongo 'try { conn.getDB("admin").getCollectionNames(); print("allowed") } catch (e) { print("denied") }')"

echo "All end-to-end checks passed"
