#!/usr/bin/env bash
set -euo pipefail

COMPOSE_DIR="/home/docker"

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

# Check if nginx container is running
RUNNING=$($DC ps --services --filter "status=running" | grep -c "^nginx$" || true)

if [ "$RUNNING" -eq 0 ]; then
  echo "Stack not running. Starting stack..."
  $DC up -d
else
  echo "Stack already running."
fi

echo "Running certbot..."
$DC run --rm certbot

echo "Reloading nginx..."
if $DC exec -T nginx nginx -s reload 2>/dev/null; then
  echo "nginx reloaded successfully."
else
  echo "Reload failed, restarting nginx..."
  $DC restart nginx
fi

echo "Certificate process complete."
