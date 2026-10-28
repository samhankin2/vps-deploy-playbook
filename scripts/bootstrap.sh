#!/bin/bash
#
# cloud-init bootstrap for a small Node app on a fresh Ubuntu 24.04 VM.
# Runs as root on first boot. Installs Node 24 + Caddy, clones the app,
# registers a systemd service, and puts Caddy in front of it with TLS.
#
# Configure with environment variables (passed in via instance metadata or
# written into the script before upload):
#
#   APP_NAME      short app name, e.g. myapp
#   REPO_URL      git URL of the app
#   PORT          port the app listens on (default 3000)
#   HEALTH_PATH   health endpoint (default /api/health)
#   FRONTEND_ORIGIN  allowed CORS origin (optional)
#
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

APP_NAME="${APP_NAME:-myapp}"
REPO_URL="${REPO_URL:?REPO_URL is required}"
PORT="${PORT:-3000}"
HEALTH_PATH="${HEALTH_PATH:-/api/health}"
FRONTEND_ORIGIN="${FRONTEND_ORIGIN:-}"

APP_DIR="/opt/${APP_NAME}"
DATA_DIR="/var/lib/${APP_NAME}"
SERVICE="${APP_NAME}"
LOG="/var/log/${APP_NAME}-bootstrap.log"

exec > >(tee -a "$LOG") 2>&1
echo "== bootstrap start $(date) =="

echo "== base packages =="
apt-get update -y
apt-get install -y curl ca-certificates gnupg ufw rsync git python3 apt-transport-https

echo "== node 24 =="
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt-get install -y nodejs
node --version

echo "== caddy =="
if ! command -v caddy >/dev/null 2>&1; then
  curl -1sLf "https://dl.cloudsmith.io/public/caddy/stable/gpg.key" \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf "https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt" \
    | tee /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y
  apt-get install -y caddy
fi
caddy version

echo "== application =="
rm -rf "$APP_DIR"
git clone --depth 1 "$REPO_URL" "$APP_DIR"

getent group "$APP_NAME" >/dev/null || groupadd --system "$APP_NAME"
id -u "$APP_NAME" >/dev/null 2>&1 \
  || useradd --system --gid "$APP_NAME" --home "$APP_DIR" --shell /usr/sbin/nologin "$APP_NAME"
mkdir -p "$DATA_DIR"
chown -R "$APP_NAME":"$APP_NAME" "$DATA_DIR"

if [ -f "$APP_DIR/deploy/app.service" ]; then
  install -m 0644 "$APP_DIR/deploy/app.service" "/etc/systemd/system/${SERVICE}.service"
else
  cat > "/etc/systemd/system/${SERVICE}.service" <<UNIT
[Unit]
Description=${APP_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_NAME}
Group=${APP_NAME}
WorkingDirectory=${APP_DIR}
Environment=PORT=${PORT}
Environment=HOST=127.0.0.1
Environment=DATA_DIR=${DATA_DIR}
Environment=CONFIG_DIR=${APP_DIR}/data
ExecStart=/usr/bin/node ${APP_DIR}/server.js
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${DATA_DIR}

[Install]
WantedBy=multi-user.target
UNIT
fi

systemctl daemon-reload
systemctl enable --now "$SERVICE"
sleep 3
systemctl --no-pager --lines=5 status "$SERVICE" || true

echo "== firewall =="
ufw allow 22/tcp || true
ufw allow 80/tcp || true
ufw allow 443/tcp || true
ufw --force enable || true

# Oracle's Ubuntu image installs an iptables REJECT rule AHEAD of the ufw
# chains, so ufw alone does not open 80/443. Insert the accepts before that
# rule and persist them across reboots.
for PORT_NUM in 80 443; do
  if ! iptables -C INPUT -p tcp --dport "$PORT_NUM" -j ACCEPT 2>/dev/null; then
    iptables -I INPUT 4 -p tcp --dport "$PORT_NUM" -j ACCEPT
  fi
done
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save || true
else
  mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4 || true
fi

echo "== https =="
# The public IP is not always present in the instance metadata, so fall back to
# the address the instance uses for outbound traffic.
PUBIP="$(curl -fsS -H 'Authorization: Bearer Oracle' http://169.254.169.254/opc/v2/instance/ \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("publicIp") or d.get("ipMetadata",{}).get("publicIp") or "")' 2>/dev/null || true)"
if [ -z "$PUBIP" ]; then
  PUBIP="$(curl -fsS https://api.ipify.org || curl -fsS https://ifconfig.me/ip || true)"
fi
PUBIP="$(echo "$PUBIP" | tr -d '[:space:]')"
if [ -z "$PUBIP" ]; then
  echo "could not determine the public IP" >&2
  exit 1
fi
HOST="${APP_NAME}.${PUBIP}.sslip.io"
cat > /etc/caddy/Caddyfile <<EOF
${HOST} {
	encode zstd gzip
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "no-referrer"
		-Server
	}
	reverse_proxy 127.0.0.1:${PORT}
}
EOF
systemctl enable caddy
caddy validate --config /etc/caddy/Caddyfile
systemctl restart caddy
echo "hostname: ${HOST}"
if [ -n "$FRONTEND_ORIGIN" ]; then
  echo "allowed frontend origin: ${FRONTEND_ORIGIN}"
fi

echo "== health =="
systemctl is-active --quiet "$SERVICE" && echo "service: active"
curl -fsS "http://127.0.0.1:${PORT}${HEALTH_PATH}"
echo
echo "== bootstrap done $(date) =="
