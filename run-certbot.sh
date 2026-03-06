#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-$SCRIPT_DIR}"

cd "$COMPOSE_DIR"

# Detect compose command
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  echo "ERROR: docker compose not found"
  exit 1
fi

echo "Using compose command: $DC"

# Build domain list from tenants
TENANTS_DIR="$COMPOSE_DIR/tenants"
CERTBOT_DOMAINS=()
for tenant_dir in "$TENANTS_DIR"/*/; do
  [ -d "$tenant_dir" ] || continue
  env_file="${tenant_dir}.env"
  [ -f "$env_file" ] || continue
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^TENANT_DOMAIN=(.+)$ ]]; then
      domain=$(echo "${BASH_REMATCH[1]}" | tr -d '"' | tr -d "'" | tr -d '\r\n')
      CERTBOT_DOMAINS+=("$domain")
      break
    fi
  done < "$env_file"
done

if [ ${#CERTBOT_DOMAINS[@]} -eq 0 ]; then
  echo "No tenants found. Using covan.freightopsconnect.com as fallback."
  CERTBOT_DOMAINS=("covan.freightopsconnect.com")
fi

# Build certbot -d arguments
CERTBOT_ARGS=("certonly" "--webroot" "--webroot-path" "/var/www/certbot/" "--non-interactive" "--agree-tos")
for domain in "${CERTBOT_DOMAINS[@]}"; do
  CERTBOT_ARGS+=("-d" "$domain")
done

echo "Domains: ${CERTBOT_DOMAINS[*]}"

# Check if nginx-proxy is running
RUNNING=$($DC -f docker-compose.shared.yml --env-file .env.shared ps --services --filter "status=running" 2>/dev/null | grep -c "nginx-proxy" || true)

if [ "$RUNNING" -eq 0 ]; then
  echo "Shared stack not running. Starting shared stack..."
  $DC -f docker-compose.shared.yml --env-file .env.shared up -d
else
  echo "Shared stack already running."
fi

echo "Running certbot..."
$DC -f docker-compose.shared.yml --env-file .env.shared run --rm certbot "${CERTBOT_ARGS[@]}"

echo "Reloading nginx-proxy..."
if $DC -f docker-compose.shared.yml --env-file .env.shared exec -T nginx-proxy nginx -s reload 2>/dev/null; then
  echo "nginx-proxy reloaded successfully."
else
  echo "Reload failed, restarting nginx-proxy..."
  $DC -f docker-compose.shared.yml --env-file .env.shared restart nginx-proxy
fi

echo "Certificate process complete."
