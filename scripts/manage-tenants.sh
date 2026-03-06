#!/usr/bin/env bash
# Manage FreightOps tenant containers
# Usage: ./manage-tenants.sh <command> [tenant-id]
# Commands: start, stop, restart, up, logs, add

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TENANTS_DIR="$INFRA_ROOT/tenants"

# Detect compose command
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  echo "ERROR: docker compose not found"
  exit 1
fi

cd "$INFRA_ROOT"

list_tenants() {
  for d in "$TENANTS_DIR"/*/; do
    [ -d "$d" ] || continue
    [ -f "${d}.env" ] || continue
    basename "$d"
  done
}

run_tenant() {
  local tenant_id="$1"
  local cmd="$2"
  shift 2
  local env_file="$TENANTS_DIR/$tenant_id/.env"
  if [ ! -f "$env_file" ]; then
    echo "ERROR: Tenant '$tenant_id' not found (no $env_file)"
    exit 1
  fi
  export TENANT_ENV_FILE="$env_file"
  $DC -f docker-compose.tenant.yml --env-file "$env_file" -p "freightops-$tenant_id" "$cmd" "$@"
}

cmd_start() {
  local tenant_id="${1:-}"
  if [ -z "$tenant_id" ]; then
    for t in $(list_tenants); do
      echo "Starting tenant: $t"
      run_tenant "$t" up -d
    done
  else
    run_tenant "$tenant_id" up -d
  fi
}

cmd_stop() {
  local tenant_id="${1:-}"
  if [ -z "$tenant_id" ]; then
    for t in $(list_tenants); do
      echo "Stopping tenant: $t"
      run_tenant "$t" down
    done
  else
    run_tenant "$tenant_id" down
  fi
}

cmd_restart() {
  local tenant_id="${1:-}"
  if [ -z "$tenant_id" ]; then
    cmd_stop
    cmd_start
  else
    run_tenant "$tenant_id" down
    run_tenant "$tenant_id" up -d
  fi
}

cmd_up() {
  local tenant_id="${1:-}"
  if [ -z "$tenant_id" ]; then
    for t in $(list_tenants); do
      echo "Pulling and starting tenant: $t"
      run_tenant "$t" pull
      run_tenant "$t" up -d
    done
  else
    run_tenant "$tenant_id" pull
    run_tenant "$tenant_id" up -d
  fi
}

cmd_logs() {
  local tenant_id="$1"
  shift || true
  run_tenant "$tenant_id" logs -f "$@"
}

cmd_add() {
  local tenant_id="$1"
  exec "$SCRIPT_DIR/add-tenant.sh" "$tenant_id"
}

cmd_create_db() {
  local tenant_id="$1"
  if [ -z "$tenant_id" ]; then
    echo "Usage: $0 create-db <tenant-id>"
    exit 1
  fi
  exec "$SCRIPT_DIR/create-tenant-db.sh" "$tenant_id"
}

cmd_migrate() {
  local tenant_id="$1"
  if [ -z "$tenant_id" ]; then
    echo "Usage: $0 migrate <tenant-id>"
    exit 1
  fi
  local env_file="$TENANTS_DIR/$tenant_id/.env"
  if [ ! -f "$env_file" ]; then
    echo "ERROR: Tenant '$tenant_id' not found (no $env_file)"
    exit 1
  fi
  # Load DOCKER_REGISTRY from .env.shared or tenant env
  local registry="manicapps904/freightops"
  [ -f ".env.shared" ] && source .env.shared 2>/dev/null || true
  [ -n "${DOCKER_REGISTRY:-}" ] && registry="$DOCKER_REGISTRY"
  source "$env_file" 2>/dev/null || true
  [ -n "${DOCKER_REGISTRY:-}" ] && registry="$DOCKER_REGISTRY"
  # Expand ${VAR} refs in .env for docker (docker run --env-file does not expand)
  local expanded_env
  expanded_env=$(mktemp)
  set -a
  source "$env_file" 2>/dev/null || true
  set +a
  envsubst < "$env_file" > "$expanded_env" 2>/dev/null || cp "$env_file" "$expanded_env"
  echo "Running migrations for tenant '$tenant_id' (image: ${registry}-migrations:latest)..."
  docker run --rm \
    --env-file "$expanded_env" \
    --network host \
    "${registry}-migrations:latest"
  rm -f "$expanded_env"
}

cmd_list() {
  echo "Tenants:"
  for t in $(list_tenants); do
    echo "  - $t"
  done
}

cmd_shared_start() {
  echo "Starting shared infrastructure (nginx-proxy, certbot, pgadmin, watchtower)..."
  $DC -f docker-compose.shared.yml --env-file .env.shared up -d
}

cmd_shared_stop() {
  echo "Stopping shared infrastructure..."
  $DC -f docker-compose.shared.yml --env-file .env.shared down
}

cmd_shared_logs() {
  $DC -f docker-compose.shared.yml --env-file .env.shared logs -f "$@"
}

# Main
CMD="${1:-}"
TENANT_ID="${2:-}"

case "$CMD" in
  start)  cmd_start "$TENANT_ID" ;;
  stop)   cmd_stop "$TENANT_ID" ;;
  restart) cmd_restart "$TENANT_ID" ;;
  up)    cmd_up "$TENANT_ID" ;;
  logs)
    if [ -z "$TENANT_ID" ]; then
      echo "Usage: $0 logs <tenant-id> [service...]"
      exit 1
    fi
    cmd_logs "$TENANT_ID" "${@:3}"
    ;;
  add)
    if [ -z "$TENANT_ID" ]; then
      echo "Usage: $0 add <tenant-id>"
      exit 1
    fi
    cmd_add "$TENANT_ID"
    ;;
  create-db)
    if [ -z "$TENANT_ID" ]; then
      echo "Usage: $0 create-db <tenant-id>"
      exit 1
    fi
    cmd_create_db "$TENANT_ID"
    ;;
  migrate)
    if [ -z "$TENANT_ID" ]; then
      echo "Usage: $0 migrate <tenant-id>"
      exit 1
    fi
    cmd_migrate "$TENANT_ID"
    ;;
  list)  cmd_list ;;
  shared-start)  cmd_shared_start ;;
  shared-stop)   cmd_shared_stop ;;
  shared-logs)   cmd_shared_logs ;;
  *)
    echo "Usage: $0 <command> [tenant-id]"
    echo ""
    echo "Commands:"
    echo "  start [tenant-id]    Start tenant(s). Omit tenant-id to start all."
    echo "  stop [tenant-id]    Stop tenant(s)."
    echo "  restart [tenant-id] Restart tenant(s)."
    echo "  up [tenant-id]      Pull images and start tenant(s)."
    echo "  logs <tenant-id>    Follow logs for a tenant."
    echo "  add <tenant-id>      Add a new tenant (scaffold .env)."
    echo "  create-db <tenant-id> Create PostgreSQL databases and users for a tenant."
    echo "  migrate <tenant-id>  Run EF migrations and Marten seed (uses freightops-migrations image)."
    echo "  list                List all tenants."
    echo "  shared-start        Start shared infrastructure (nginx, certbot, pgadmin, watchtower)."
    echo "  shared-stop         Stop shared infrastructure."
    echo "  shared-logs         Follow shared infrastructure logs."
    exit 1
    ;;
esac
