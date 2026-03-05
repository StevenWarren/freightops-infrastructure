# Freightops Infrastructure

# Docker Compose + Certbot Renewal with systemd Timer (Amazon Linux)

This document describes how to automate **Let's Encrypt certificate renewal** for a Docker Compose stack using **systemd services and timers** on Amazon Linux.

The stack assumes:

* Docker Compose project located at:
  `/home/docker`
* The stack includes an **nginx container** serving the webroot for Certbot.
* A **certbot container** defined in the `docker-compose.yml`.

The automation will:

1. Ensure the Docker stack is running
2. Execute the Certbot container
3. Reload nginx so the updated certificate is used
4. Run automatically twice daily using a **systemd timer**

---

# 1. Create the Renewal Script

Create the script:

```bash
sudo nano /home/docker/run-certbot.sh
```

Paste the following:

```bash
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
  echo "docker compose not found"
  exit 1
fi

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
$DC exec -T nginx nginx -s reload || $DC restart nginx

echo "Certificate renewal complete."
```

Make it executable:

```bash
chmod +x /home/docker/run-certbot.sh
```

---

# 2. Create the systemd Service

Create a systemd service that runs the script.

```bash
sudo nano /etc/systemd/system/certbot-renew.service
```

Contents:

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
```

---

# 3. Create the systemd Timer

Create the timer that schedules the service.

```bash
sudo nano /etc/systemd/system/certbot-renew.timer
```

Contents:

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

### Timer Behavior

| Setting              | Purpose                                            |
| -------------------- | -------------------------------------------------- |
| `OnCalendar`         | Runs at midnight and noon                          |
| `RandomizedDelaySec` | Adds up to 1 hour of jitter to avoid mass renewals |
| `AccuracySec`        | Allows systemd to group timers efficiently         |
| `Persistent=true`    | Runs if a scheduled time was missed                |
| `OnBootSec`          | Runs once shortly after system boot                |

---

# 4. Enable the Timer

Reload systemd:

```bash
sudo systemctl daemon-reload
```

Enable and start the timer:

```bash
sudo systemctl enable --now certbot-renew.timer
```

---

# 5. Verify Timer Status

Check the next scheduled run:

```bash
systemctl list-timers certbot-renew.timer
```

Expected output includes:

```
certbot-renew.timer
```

---

# 6. Test Manually

Run the renewal job immediately:

```bash
sudo systemctl start certbot-renew.service
```

View logs:

```bash
journalctl -u certbot-renew.service -f
```

---

# 7. Verify Certificates

Certificates are stored in:

```
/home/docker/config/certbot-conf
```

Mounted into nginx as:

```
/etc/letsencrypt
```

nginx is reloaded automatically after renewal.

---

# Important Note

Avoid using:

```
--force-renew
```

This forces certificate renewal every run and may trigger **Let's Encrypt rate limits**.

Certbot automatically renews certificates **only when expiration is near**, so forcing renewal is unnecessary.

---

# Architecture Overview

```
systemd timer
      │
      ▼
certbot-renew.service
      │
      ▼
run-certbot.sh
      │
      ├── checks docker compose stack
      ├── starts stack if needed
      ├── runs certbot container
      └── reloads nginx
```

---

# Result

Certificates are automatically:

* Checked **twice daily**
* Renewed **only when needed**
* Reloaded into nginx **without downtime**
* Logged through **systemd journal**

---

# Useful Commands

### View timer

```
systemctl list-timers
```

### View logs

```
journalctl -u certbot-renew.service
```

### Restart timer

```
sudo systemctl restart certbot-renew.timer
```

### Run renewal manually

```
sudo systemctl start certbot-renew.service
```

---

