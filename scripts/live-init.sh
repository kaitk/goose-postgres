#!/bin/sh
# Runs in the Postgres container's first start, from docker-entrypoint-initdb.d,
# after the entrypoint wrote pg_hba.conf: adds the user `plain`, whose
# connections authenticate with a cleartext password, for
# test/session/cleartext.goose. Everyone else keeps the image's
# scram-sha-256.
set -eu
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
CREATE ROLE plain LOGIN PASSWORD 'plain pass';
GRANT SELECT ON items TO plain;
SQL
sed -i '1i host all plain all password' "$PGDATA/pg_hba.conf"
