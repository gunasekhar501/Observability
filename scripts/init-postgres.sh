#!/bin/bash
# Creates one database per service on the shared PostgreSQL instance.
set -e

create_db() {
  local db=$1
  echo "Creating database: $db"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    SELECT 'CREATE DATABASE $db' WHERE NOT EXISTS (
      SELECT FROM pg_database WHERE datname = '$db'
    )\gexec
EOSQL
}

for db in secureops sonarqube wikijs plane mattermost; do
  create_db "$db"
done

echo "All databases ready."
