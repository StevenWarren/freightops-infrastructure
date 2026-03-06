#!/usr/bin/env bash
# Add a new FreightOps tenant - creates directory and .env template
# Usage: ./add-tenant.sh <tenant-id>

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

# Validate tenant id (alphanumeric, hyphen)
if ! [[ "$TENANT_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
  echo "ERROR: Tenant ID must be alphanumeric (may include - or _)"
  exit 1
fi

TENANT_DIR="$TENANTS_DIR/$TENANT_ID"
ENV_FILE="$TENANT_DIR/.env"

if [ -d "$TENANT_DIR" ] && [ -f "$ENV_FILE" ]; then
  echo "Tenant '$TENANT_ID' already exists at $TENANT_DIR"
  echo "Edit $ENV_FILE to modify configuration."
  exit 0
fi

mkdir -p "$TENANT_DIR"

# Default domain
DEFAULT_DOMAIN="${TENANT_ID}.freightopsconnect.com"

# Sanitize tenant ID for DB names (hyphens -> underscores; PostgreSQL identifiers can't have hyphens)
DB_TENANT_ID="${TENANT_ID//-/_}"

cat > "$ENV_FILE" << EOF
# Tenant identification
TENANT_ID=$TENANT_ID
TENANT_DOMAIN=$DEFAULT_DOMAIN

# Container names (must be unique across tenants)
API_NAME=fo-api-$TENANT_ID
DAEMON_NAME=fo-daemon-$TENANT_ID
DASHBOARD_NAME=fo-dashboard-$TENANT_ID

# Docker registry
DOCKER_REGISTRY=manicapps904/freightops

# Database (tenant-specific)
# POSTGRES_USER/POSTGRES_PASSWORD = maintenance user (must have CREATE DATABASE privilege)
# Use same as covan for shared PostgreSQL server
DATABASE_NAME=172.23.0.10
POSTGRES_USER=freightops-maintfreightops-ma
POSTGRES_PASSWORD=CHANGE_ME_MAINTENANCE_PASSWORD
POSTGRES_PORT=5432
DEV_DB=fo_app_${DB_TENANT_ID}
DEV_DB_USER=fo_${DB_TENANT_ID}
DEV_DB_PASSWORD=CHANGE_ME
AUTH_DB=fo_auth_${DB_TENANT_ID}
AUTH_DB_USER=fo_auth_${DB_TENANT_ID}
AUTH_DB_PASSWORD=CHANGE_ME

ConnectionStrings__PgConnection="Server=\${DATABASE_NAME};Database=\${DEV_DB};Port=\${POSTGRES_PORT};User Id=\${DEV_DB_USER};Password=\${DEV_DB_PASSWORD};"
ConnectionStrings__CorpConnection="Server=\${DATABASE_NAME};Database=\${DEV_DB};Port=\${POSTGRES_PORT};User Id=\${DEV_DB_USER};Password=\${DEV_DB_PASSWORD};"
ConnectionStrings__AuthConnection="Server=\${DATABASE_NAME};Database=\${AUTH_DB};Port=\${POSTGRES_PORT};User Id=\${AUTH_DB_USER};Password=\${AUTH_DB_PASSWORD};"

# For migrations (command line format)
DATABASE_CONNECTION_STRING="Host=\${DATABASE_NAME};Port=\${POSTGRES_PORT};Username=\${AUTH_DB_USER};Password=\${AUTH_DB_PASSWORD};Database=\${AUTH_DB};"

# Dashboard runtime config
VITE_API_HOST="https://$DEFAULT_DOMAIN"
VITE_BASE_URL="https://$DEFAULT_DOMAIN"

# Daemon webhook config (tenant-specific) - UPDATE THESE
OutboxNotifications__Status="ProStowedEvent"
OutboxNotifications__Notification__Type="api"
OutboxNotifications__Notification__Configuration__endpoint="https://example.com/webhook/received"
OutboxNotifications__Notification__Configuration__method="POST"
OutboxNotifications__Notification__Configuration__RequiresAuth="false"
OutboxNotifications__Notification__Configuration__Params__0__Key="Account"
OutboxNotifications__Notification__Configuration__Params__0__Value="Terminal"
OutboxNotifications__Notification__Configuration__Params__1__Key="TrackingNo"
OutboxNotifications__Notification__Configuration__Params__1__Value="ProNumber"
EOF

echo "Created tenant '$TENANT_ID' at $TENANT_DIR"
echo ""
echo "Next steps:"
echo "1. Edit $ENV_FILE with real database credentials (POSTGRES_PASSWORD, DEV_DB_PASSWORD, AUTH_DB_PASSWORD) and webhook endpoint"
echo "2. Create databases: ./scripts/create-tenant-db.sh $TENANT_ID"
echo "3. Run EF migrations and seed (from FreightOps dir with tenant env)"
echo "4. Run: ./scripts/generate-nginx.sh  (regenerates nginx config)"
echo "5. Add domain to certbot (see README for --expand command)"
echo "6. Run: ./scripts/manage-tenants.sh start $TENANT_ID"
echo ""

# Regenerate nginx config
"$SCRIPT_DIR/generate-nginx.sh"
