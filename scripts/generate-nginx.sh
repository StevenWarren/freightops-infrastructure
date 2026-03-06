#!/usr/bin/env bash
# Generate nginx config from tenant .env files in tenants/
# Run from freightops-infrastructure root

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TENANTS_DIR="$INFRA_ROOT/tenants"
CONFIG_DIR="$INFRA_ROOT/config/nginx"
DEFAULT_CONF="$CONFIG_DIR/default.conf"
SSL_CONF="$CONFIG_DIR/ssl.conf"

mkdir -p "$CONFIG_DIR"

# Collect tenants and domains
declare -a TENANT_IDS
declare -a TENANT_DOMAINS

for tenant_dir in "$TENANTS_DIR"/*/; do
  [ -d "$tenant_dir" ] || continue
  env_file="${tenant_dir}.env"
  [ -f "$env_file" ] || continue

  tenant_id=$(basename "$tenant_dir")
  tenant_domain=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^TENANT_DOMAIN=(.+)$ ]]; then
      tenant_domain=$(echo "${BASH_REMATCH[1]}" | tr -d '"' | tr -d "'")
      break
    fi
  done < "$env_file"

  if [ -z "$tenant_domain" ]; then
    tenant_domain="${tenant_id}.freightopsconnect.com"
  fi
  tenant_domain=$(echo "$tenant_domain" | tr -d '\r\n')

  TENANT_IDS+=("$tenant_id")
  TENANT_DOMAINS+=("$tenant_domain")
done

if [ ${#TENANT_IDS[@]} -eq 0 ]; then
  echo "No tenants found in $TENANTS_DIR"
  exit 1
fi

# Build server_name list for HTTP (ACME)
SERVER_NAMES=""
for domain in "${TENANT_DOMAINS[@]}"; do
  domain=$(echo "$domain" | tr -d '\r\n')
  SERVER_NAMES="$SERVER_NAMES $domain"
done
SERVER_NAMES=$(echo "$SERVER_NAMES" | xargs)

# Generate default.conf (HTTP, ACME challenge)
cat > "$DEFAULT_CONF" << EOF
server_names_hash_bucket_size 64;
server {
    listen 80;
    server_name $SERVER_NAMES;
    location / {
        return 200 "Hello World";
    }
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
}
EOF

# Primary domain for SSL cert path (first tenant)
PRIMARY_DOMAIN=$(echo "${TENANT_DOMAINS[0]}" | tr -d '\r\n')

# Generate ssl.conf (HTTPS, one server block per tenant)
{
  echo "server {"
  echo "    listen 443 default_server ssl;"
  echo "    listen [::]:443 ssl;"
  echo "    http2 on;"
  echo ""
  echo "    server_name ${TENANT_DOMAINS[0]};"
  echo ""
  echo "    ssl_certificate /etc/letsencrypt/live/${PRIMARY_DOMAIN}/fullchain.pem;"
  echo "    ssl_certificate_key /etc/letsencrypt/live/${PRIMARY_DOMAIN}/privkey.pem;"
  echo ""
  echo "    location / {"
  echo "        proxy_pass http://fo-dashboard-${TENANT_IDS[0]}:80;"
  echo "        proxy_redirect off;"
  echo "        proxy_http_version 1.1;"
  echo "        proxy_cache_bypass \$http_upgrade;"
  echo "        proxy_set_header Upgrade \$http_upgrade;"
  echo "        proxy_set_header Connection keep-alive;"
  echo "        proxy_set_header Host \$host;"
  echo "        proxy_set_header X-Real-IP \$remote_addr;"
  echo "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
  echo "        proxy_set_header X-Forwarded-Proto \$scheme;"
  echo "        proxy_set_header X-Forwarded-Host \$server_name;"
  echo "    }"
  echo "    location /api/ {"
  echo "        proxy_pass http://fo-api-${TENANT_IDS[0]}:5000;"
  echo "        proxy_redirect off;"
  echo "        proxy_http_version 1.1;"
  echo "        proxy_cache_bypass \$http_upgrade;"
  echo "        proxy_set_header Upgrade \$http_upgrade;"
  echo "        proxy_set_header Connection keep-alive;"
  echo "        proxy_set_header Host \$host;"
  echo "        proxy_set_header X-Real-IP \$remote_addr;"
  echo "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
  echo "        proxy_set_header X-Forwarded-Proto \$scheme;"
  echo "        proxy_set_header X-Forwarded-Host \$server_name;"
  echo "    }"
  echo "    location /swagger/ {"
  echo "        proxy_pass http://fo-api-${TENANT_IDS[0]}:5000/;"
  echo "        proxy_redirect off;"
  echo "        proxy_http_version 1.1;"
  echo "        proxy_cache_bypass \$http_upgrade;"
  echo "        proxy_set_header Upgrade \$http_upgrade;"
  echo "        proxy_set_header Connection keep-alive;"
  echo "        proxy_set_header Host \$host;"
  echo "        proxy_set_header X-Real-IP \$remote_addr;"
  echo "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
  echo "        proxy_set_header X-Forwarded-Proto \$scheme;"
  echo "        proxy_set_header X-Forwarded-Host \$server_name;"
  echo "    }"
  echo "    location /pgadmin4/ {"
  echo "        allow 76.195.46.56;"
  echo "        allow 71.81.251.111;"
  echo "        allow 209.83.83.50;"
  echo "        deny all;"
  echo "        proxy_set_header X-Script-Name /pgadmin4;"
  echo "        proxy_set_header X-Scheme \$scheme;"
  echo "        proxy_set_header Host \$host;"
  echo "        proxy_pass http://pgadmin_container:5050/;"
  echo "        proxy_redirect off;"
  echo "    }"
  echo "}"

  # Additional server blocks for other tenants
  for i in $(seq 1 $((${#TENANT_IDS[@]} - 1))); do
    tid="${TENANT_IDS[$i]}"
    tdom="${TENANT_DOMAINS[$i]}"
    echo ""
    echo "server {"
    echo "    listen 443 ssl;"
    echo "    listen [::]:443 ssl;"
    echo "    http2 on;"
    echo ""
    echo "    server_name $tdom;"
    echo ""
    echo "    ssl_certificate /etc/letsencrypt/live/${PRIMARY_DOMAIN}/fullchain.pem;"
    echo "    ssl_certificate_key /etc/letsencrypt/live/${PRIMARY_DOMAIN}/privkey.pem;"
    echo ""
    echo "    location / {"
    echo "        proxy_pass http://fo-dashboard-${tid}:80;"
    echo "        proxy_redirect off;"
    echo "        proxy_http_version 1.1;"
    echo "        proxy_cache_bypass \$http_upgrade;"
    echo "        proxy_set_header Upgrade \$http_upgrade;"
    echo "        proxy_set_header Connection keep-alive;"
    echo "        proxy_set_header Host \$host;"
    echo "        proxy_set_header X-Real-IP \$remote_addr;"
    echo "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
    echo "        proxy_set_header X-Forwarded-Proto \$scheme;"
    echo "        proxy_set_header X-Forwarded-Host \$server_name;"
    echo "    }"
    echo "    location /api/ {"
    echo "        proxy_pass http://fo-api-${tid}:5000;"
    echo "        proxy_redirect off;"
    echo "        proxy_http_version 1.1;"
    echo "        proxy_cache_bypass \$http_upgrade;"
    echo "        proxy_set_header Upgrade \$http_upgrade;"
    echo "        proxy_set_header Connection keep-alive;"
    echo "        proxy_set_header Host \$host;"
    echo "        proxy_set_header X-Real-IP \$remote_addr;"
    echo "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
    echo "        proxy_set_header X-Forwarded-Proto \$scheme;"
    echo "        proxy_set_header X-Forwarded-Host \$server_name;"
    echo "    }"
    echo "    location /swagger/ {"
    echo "        proxy_pass http://fo-api-${tid}:5000/;"
    echo "        proxy_redirect off;"
    echo "        proxy_http_version 1.1;"
    echo "        proxy_cache_bypass \$http_upgrade;"
    echo "        proxy_set_header Upgrade \$http_upgrade;"
    echo "        proxy_set_header Connection keep-alive;"
    echo "        proxy_set_header Host \$host;"
    echo "        proxy_set_header X-Real-IP \$remote_addr;"
    echo "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
    echo "        proxy_set_header X-Forwarded-Proto \$scheme;"
    echo "        proxy_set_header X-Forwarded-Host \$server_name;"
    echo "    }"
    echo "}"
  done
} > "$SSL_CONF"

echo "Generated $DEFAULT_CONF and $SSL_CONF for ${#TENANT_IDS[@]} tenant(s): ${TENANT_IDS[*]}"
