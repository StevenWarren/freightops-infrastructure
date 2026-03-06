#!/usr/bin/env bash
# Create PostgreSQL databases and users for a new tenant
# Usage: ./create-tenant-db.sh <tenant-id>
# Requires: tenant's .env with DATABASE_NAME, POSTGRES_USER, POSTGRES_PASSWORD,
#           DEV_DB, AUTH_DB, DEV_DB_USER, DEV_DB_PASSWORD, AUTH_DB_USER, AUTH_DB_PASSWORD

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TENANTS_DIR="$INFRA_ROOT/tenants"

TENANT_ID="${1:-}"
if [ -z "$TENANT_ID" ]; then
  echo "Usage: $0 <tenant-id>"
  echo "Example: $0 tenant2"
  exit 1
fi

ENV_FILE="$TENANTS_DIR/$TENANT_ID/.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: Tenant '$TENANT_ID' not found. Run add-tenant.sh first."
  exit 1
fi

# Load required vars from tenant .env
while IFS= read -r line || [ -n "$line" ]; do
  [[ "$line" =~ ^# ]] && continue
  if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    value="${value%\"}"
    value="${value#\"}"
    case "$key" in
      DATABASE_NAME|POSTGRES_USER|POSTGRES_PASSWORD|POSTGRES_PORT|DEV_DB|AUTH_DB|DEV_DB_USER|DEV_DB_PASSWORD|AUTH_DB_USER|AUTH_DB_PASSWORD)
        export "$key=$value"
        ;;
    esac
  fi
done < "$ENV_FILE"

# Required vars
for var in DATABASE_NAME POSTGRES_USER POSTGRES_PASSWORD POSTGRES_PORT \
           DEV_DB AUTH_DB DEV_DB_USER DEV_DB_PASSWORD AUTH_DB_USER AUTH_DB_PASSWORD; do
  val="${!var:-}"
  if [ -z "$val" ]; then
    echo "ERROR: $var not set in $ENV_FILE"
    exit 1
  fi
done

POSTGRES_PORT="${POSTGRES_PORT:-5432}"
CONN_STR="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${DATABASE_NAME}:${POSTGRES_PORT}/postgres"

echo "Creating databases for tenant '$TENANT_ID' on ${DATABASE_NAME}..."
echo "  DEV_DB=$DEV_DB, AUTH_DB=$AUTH_DB"
echo "  Users: $DEV_DB_USER, $AUTH_DB_USER"
echo ""

# Use Docker postgres client if psql not available
run_sql() {
  local db="$1"
  shift
  local sql="$*"
  if command -v psql >/dev/null 2>&1; then
    psql "$CONN_STR" -d "$db" -v ON_ERROR_STOP=1 -c "$sql"
  else
    docker run --rm -e PGPASSWORD="$POSTGRES_PASSWORD" \
      postgres:15-alpine psql -h "$DATABASE_NAME" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$db" -v ON_ERROR_STOP=1 -c "$sql"
  fi
}

run_sql_postgres() {
  local sql="$*"
  if command -v psql >/dev/null 2>&1; then
    psql "$CONN_STR" -v ON_ERROR_STOP=1 -c "$sql"
  else
    docker run --rm -e PGPASSWORD="$POSTGRES_PASSWORD" \
      postgres:15-alpine psql -h "$DATABASE_NAME" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -c "$sql"
  fi
}

# Query that returns single value (for existence checks)
run_sql_postgres_query() {
  local sql="$1"
  if command -v psql >/dev/null 2>&1; then
    psql "$CONN_STR" -t -A -v ON_ERROR_STOP=1 -c "$sql" 2>/dev/null
  else
    docker run --rm -e PGPASSWORD="$POSTGRES_PASSWORD" \
      postgres:15-alpine psql -h "$DATABASE_NAME" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d postgres -t -A -v ON_ERROR_STOP=1 -c "$sql" 2>/dev/null
  fi
}

# Create databases (PostgreSQL does not allow CREATE DATABASE inside a function/block)
# Check if exists first, then create
dev_exists=$(run_sql_postgres_query "SELECT count(*) FROM pg_database WHERE datname = '$DEV_DB'" | tr -d ' \r\n' || echo "0")
auth_exists=$(run_sql_postgres_query "SELECT count(*) FROM pg_database WHERE datname = '$AUTH_DB'" | tr -d ' \r\n' || echo "0")
[ "${dev_exists:-0}" = "0" ] && run_sql_postgres "CREATE DATABASE $DEV_DB;"
[ "${auth_exists:-0}" = "0" ] && run_sql_postgres "CREATE DATABASE $AUTH_DB;"

# Create users (skip if exists)
run_sql_postgres "
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$DEV_DB_USER') THEN
    EXECUTE format('CREATE USER %I WITH PASSWORD %L LOGIN', '$DEV_DB_USER', '$DEV_DB_PASSWORD');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$AUTH_DB_USER') THEN
    EXECUTE format('CREATE USER %I WITH PASSWORD %L LOGIN', '$AUTH_DB_USER', '$AUTH_DB_PASSWORD');
  END IF;
END
\$\$;
"

# Grant privileges
run_sql_postgres "GRANT ALL PRIVILEGES ON DATABASE $DEV_DB TO $DEV_DB_USER;"
run_sql_postgres "GRANT ALL PRIVILEGES ON DATABASE $AUTH_DB TO $AUTH_DB_USER;"

# Schema grants (connect to each database)
run_sql "$DEV_DB" "GRANT ALL ON SCHEMA public TO $DEV_DB_USER; GRANT ALL ON SCHEMA public TO postgres;"
run_sql "$AUTH_DB" "GRANT ALL ON SCHEMA public TO $AUTH_DB_USER; GRANT ALL ON SCHEMA public TO postgres;"

echo "Databases and users created successfully for tenant '$TENANT_ID'."
echo ""
echo "Next: Run EF migrations and Marten seed for this tenant:"
echo "  cd FreightOps && docker compose run --rm migrations  # uses DATABASE_CONNECTION_STRING from tenant .env"
echo "  cd FreightOps && docker compose run --rm seed        # seeds auth data"
echo ""
echo "Or use the tenant's connection strings with dotnet ef database update."
