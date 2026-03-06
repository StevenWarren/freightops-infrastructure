# FreightOps Infrastructure

Multi-tenant Docker Compose deployment for FreightOps. Supports multiple tenants with isolated configurations (database, webhook, dashboard) while sharing nginx reverse proxy, certbot, pgadmin, and watchtower.

## Architecture

- **Shared services**: nginx-proxy (reverse proxy only), certbot, pgadmin, watchtower
- **Per-tenant services**: freightops-api, freightops-daemon, freightops-dashboard (one container each per tenant)

```
                    ┌─────────────────┐
                    │  nginx-proxy    │
                    │  (port 80/443)  │
                    └────────┬────────┘
         ┌───────────────────┼───────────────────┐
         │                   │                   │
         ▼                   ▼                   ▼
  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
  │ covan       │    │ tenant2     │    │ tenant3     │
  │ dashboard   │    │ dashboard   │    │ dashboard   │
  │ api         │    │ api         │    │ api         │
  │ daemon      │    │ daemon      │    │ daemon      │
  └─────────────┘    └─────────────┘    └─────────────┘
```

## Quick Start

### 1. Initial setup (first time)

```bash
# Create certbot directories (if not present)
mkdir -p config/certbot-conf config/certbot-www

# Generate nginx config from tenants
./scripts/generate-nginx.sh

# Start shared infrastructure
./scripts/manage-tenants.sh shared-start

# Start tenant(s)
./scripts/manage-tenants.sh start covan
```

### 2. Production deployment path

For production at `/home/docker`:

```bash
export COMPOSE_DIR=/home/docker
cd /home/docker
./scripts/manage-tenants.sh shared-start
./scripts/manage-tenants.sh start covan
```

## Tenant Management

| Command | Description |
|---------|-------------|
| `./scripts/manage-tenants.sh shared-start` | Start nginx-proxy, certbot, pgadmin, watchtower |
| `./scripts/manage-tenants.sh shared-stop` | Stop shared infrastructure |
| `./scripts/manage-tenants.sh start [tenant-id]` | Start tenant(s). Omit id to start all |
| `./scripts/manage-tenants.sh stop [tenant-id]` | Stop tenant(s) |
| `./scripts/manage-tenants.sh up [tenant-id]` | Pull images and start tenant(s) |
| `./scripts/manage-tenants.sh logs <tenant-id>` | Follow tenant logs |
| `./scripts/manage-tenants.sh add <tenant-id>` | Add a new tenant |
| `./scripts/manage-tenants.sh create-db <tenant-id>` | Create PostgreSQL databases and users for a tenant |
| `./scripts/manage-tenants.sh list` | List all tenants |

## Adding a New Tenant

```bash
# 1. Scaffold tenant (creates tenants/<id>/.env)
./scripts/manage-tenants.sh add tenant2

# 2. Edit tenants/tenant2/.env with real credentials:
#    - POSTGRES_PASSWORD (maintenance user - copy from covan for shared server)
#    - DEV_DB_PASSWORD, AUTH_DB_PASSWORD (tenant DB users)
#    - Webhook endpoint in OutboxNotifications section

# 3. Create databases and users on PostgreSQL
./scripts/manage-tenants.sh create-db tenant2

# 4. Run EF migrations and seed (from FreightOps dir, with tenant env)
cd ../FreightOps
docker compose --env-file ../freightops-infrastructure/tenants/tenant2/.env run --rm migrations
docker compose --env-file ../freightops-infrastructure/tenants/tenant2/.env run --rm seed
cd ../freightops-infrastructure

# 5. Regenerate nginx config (add-tenant.sh does this automatically)
./scripts/generate-nginx.sh

# 6. Add domain to SSL cert (run from infra root)
docker compose -f docker-compose.shared.yml --env-file .env.shared run --rm certbot \
  certonly --webroot --webroot-path /var/www/certbot/ \
  --non-interactive --agree-tos --expand \
  -d covan.freightopsconnect.com -d tenant2.freightopsconnect.com

# 7. Reload nginx
docker compose -f docker-compose.shared.yml --env-file .env.shared exec nginx-proxy nginx -s reload

# 8. Start the new tenant
./scripts/manage-tenants.sh start tenant2
```

## Certificate Renewal (Certbot)

Certificates are renewed via `run-certbot.sh`, which reads domains from tenant `.env` files.

### systemd timer (Amazon Linux)

Create `/etc/systemd/system/certbot-renew.service`:

```ini
[Unit]
Description=Renew LetsEncrypt Certificates via Docker Compose
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/home/docker/run-certbot.sh
WorkingDirectory=/home/docker
User=root
Environment=COMPOSE_DIR=/home/docker
```

Create `/etc/systemd/system/certbot-renew.timer`:

```ini
[Unit]
Description=Run Certbot renewal twice daily (randomized)

[Timer]
OnCalendar=*-*-* 00,12:00:00
Persistent=true
RandomizedDelaySec=1h
AccuracySec=5m
OnBootSec=10m

[Install]
WantedBy=timers.target
```

Enable: `sudo systemctl enable --now certbot-renew.timer`

### Manual renewal

```bash
./run-certbot.sh
```

## Directory Structure

```
freightops-infrastructure/
├── docker-compose.shared.yml    # nginx-proxy, certbot, pgadmin, watchtower
├── docker-compose.tenant.yml    # api, daemon, dashboard (per-tenant)
├── .env.shared                  # PGADMIN, DOCKER_REGISTRY
├── tenants/
│   ├── covan/
│   │   └── .env                 # Tenant-specific config
│   ├── tenant2/
│   │   └── .env
│   └── ...
├── config/
│   ├── nginx/
│   │   ├── default.conf         # Generated - HTTP, ACME challenge
│   │   └── ssl.conf             # Generated - HTTPS, per-tenant routing
│   ├── certbot-conf/            # Let's Encrypt certificates
│   └── certbot-www/             # ACME challenge webroot
├── scripts/
│   ├── manage-tenants.sh        # Main orchestration CLI
│   ├── add-tenant.sh            # New tenant scaffolding
│   ├── create-tenant-db.sh      # Create PostgreSQL DBs and users per tenant
│   └── generate-nginx.sh        # Build nginx config from tenants
└── run-certbot.sh               # Certificate renewal
```

## Migration from Single-Tenant

If migrating from the original single-tenant setup:

1. Stop the old stack: `docker compose down`
2. Create `tenants/covan/.env` (already done - migrated from root `.env`)
3. Run `./scripts/generate-nginx.sh`
4. Start shared: `./scripts/manage-tenants.sh shared-start`
5. Start covan: `./scripts/manage-tenants.sh start covan`
6. Verify https://covan.freightopsconnect.com

## Important Notes

- **Network**: Tenant containers join the `freightops-proxy` network created by the shared stack. Start shared infrastructure before tenants.
- **Paths**: For production at `/home/docker`, set `COMPOSE_DIR=/home/docker` or run from that directory.
- **Dashboard**: Each tenant gets its own dashboard container. The `freightops-nginx` image uses `entrypoint.sh` to inject `VITE_API_HOST` and `VITE_BASE_URL` at runtime.
