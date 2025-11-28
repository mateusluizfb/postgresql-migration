#!/bin/bash

set -e

SCRIPT_NAME=$(basename "$0")

DB_HOST="localhost"
DB_USER="postgres"
DB_PASSWORD="postgres"
DB_NAME="healthcare"

migration_setup() {
  echo "Setting up migration infrastructure..."

  PGPASSWORD="$DB_PASSWORD" psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
  CREATE TABLE IF NOT EXISTS schema_migrations (
      version TEXT PRIMARY KEY
  );
  "
}

migration_create() {
  if [ -z "$1" ]; then
    echo "❌ ERROR: Migration name is required for 'create'."
    echo "   Usage: $SCRIPT_NAME create <migration_name>"
    exit 1
  fi

  MIGRATION_NAME=$1
  TIMESTAMP=$(date +'%Y%m%d%H%M%S')
  FILENAME="${TIMESTAMP}_${MIGRATION_NAME}.sql"
  MIGRATION_DIR="./db/migrations"

  mkdir -p "$MIGRATION_DIR" # Ensure directory exists

  echo "✨ Creating new migration file: $MIGRATION_DIR/$FILENAME"

  echo "-- Up Migration" > "$MIGRATION_DIR/${TIMESTAMP}_${MIGRATION_NAME}.up.sql"
  echo "" >> "$MIGRATION_DIR/${TIMESTAMP}_${MIGRATION_NAME}.up.sql"
  echo "-- Write your SQL commands for the UP migration here" >> "$MIGRATION_DIR/${TIMESTAMP}_${MIGRATION_NAME}.up.sql"

  echo "-- Down Migration" > "$MIGRATION_DIR/${TIMESTAMP}_${MIGRATION_NAME}.down.sql"
  echo "" >> "$MIGRATION_DIR/${TIMESTAMP}_${MIGRATION_NAME}.down.sql"
  echo "-- Write your SQL commands for the DOWN migration here" >> "$MIGRATION_DIR/${TIMESTAMP}_${MIGRATION_NAME}.down.sql"
}

migration_up() {
  # Check if schema_migrations table exists
  SCHEMA_MIGRATIONS_EXISTS=$(PGPASSWORD="$DB_PASSWORD" psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "
    SELECT to_regclass('public.schema_migrations');
  " | xargs)
  if [ "$SCHEMA_MIGRATIONS_EXISTS" != "schema_migrations" ]; then
    echo "❌ ERROR: schema_migrations table does not exist. Run '$SCRIPT_NAME setup' first."
    exit 1
  fi

  LATEST_VERSION=$(PGPASSWORD="$DB_PASSWORD" psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "
    SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1;
  " | xargs)

  MIGRATIONS_TO_APPLY=$(ls ./db/migrations/*.up.sql | grep -E "/([0-9]{14})_.*\.up\.sql$" | awk -F'/' '{print $NF}' | awk -F'_' '{print $1}' | sort)

  if [ -n "$LATEST_VERSION" ]; then
    MIGRATIONS_TO_APPLY=$(echo "$MIGRATIONS_TO_APPLY" | awk -v last="$LATEST_VERSION" '$0 > last')
  fi

  if [ -z "$MIGRATIONS_TO_APPLY" ]; then
    echo "No new migrations to apply."
    return
  fi

  for migration in $MIGRATIONS_TO_APPLY; do
    echo "Applying migration: $migration"
    MIGRATION_OUTPUT=$(PGPASSWORD="$DB_PASSWORD" psql -h $DB_HOST -U $DB_USER -d $DB_NAME -f ./db/migrations/${migration}_*.up.sql 2>&1)
    echo "$MIGRATION_OUTPUT"

    if echo "$MIGRATION_OUTPUT" | grep -qi "error"; then
      echo "❌ ERROR: Migration $migration failed due to error in output. Stopping further migrations."
      exit 1
    else
      PGPASSWORD="$DB_PASSWORD" psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
        INSERT INTO schema_migrations (version) VALUES ('$migration');
      "
    fi
  done
}

migration_down() {
  # Check if schema_migrations table exists
  SCHEMA_MIGRATIONS_EXISTS=$(PGPASSWORD="$DB_PASSWORD" psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "
    SELECT to_regclass('public.schema_migrations');
  " | xargs)
  if [ "$SCHEMA_MIGRATIONS_EXISTS" != "schema_migrations" ]; then
    echo "❌ ERROR: schema_migrations table does not exist. Run '$SCRIPT_NAME setup' first."
    exit 1
  fi

  echo "Rolling back last migration..."
  LAST_VERSION=$(PGPASSWORD="$DB_PASSWORD" psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "
    SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1;
  " | xargs)

  if [ -z "$LAST_VERSION" ]; then
    echo "No migrations to roll back."
    return
  fi

  MIGRATION_OUTPUT=$(PGPASSWORD="$DB_PASSWORD" psql -h $DB_HOST -U $DB_USER -d $DB_NAME -f ./db/migrations/${LAST_VERSION}_*.down.sql 2>&1)
  echo "$MIGRATION_OUTPUT"

  if echo "$MIGRATION_OUTPUT" | grep -qi "error"; then
    echo "❌ ERROR: Rollback of migration $LAST_VERSION failed due to error in output. Not deleting migration record."
    exit 1
  else
    echo "Deleting migration record for version: $LAST_VERSION"
    PGPASSWORD="$DB_PASSWORD" psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
      DELETE FROM schema_migrations WHERE version = '$LAST_VERSION';
    "
  fi
}

case "$1" in
    setup)
        migration_setup
        ;;

    create)
        migration_create "$2"
        ;;

    up)
        migration_up
        ;;

    down)
        migration_down
        ;;

    *)
        echo "Usage: $SCRIPT_NAME <command> [options]"
        echo ""
        echo "Commands:"
        echo "  setup              Initialize the migration environment (e.g., config, directories)."
        echo "  create <name>      Create a new migration file with a unique timestamp."
        echo "  up                 Apply all pending migrations to the database."
        echo "  down               Rollback the most recently applied migration."
        echo ""
        exit 1
        ;;
esac
