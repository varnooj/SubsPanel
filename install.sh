#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/subpanel"
ENV_FILE="/etc/subpanel.env"
SERVICE_FILE="/etc/systemd/system/subpanel.service"
NGINX_SITE_AVAIL="/etc/nginx/sites-available/subpanel"
NGINX_SITE_EN="/etc/nginx/sites-enabled/subpanel"
NGINX_RATE_FILE="/etc/nginx/conf.d/subpanel_rate_limit.conf"

renew_ssl() {
  echo "[+] Running certbot renew..."
  certbot renew
  nginx -t && systemctl reload nginx
  echo "[✓] Renew done."
}

uninstall_all() {
  echo "[!] Uninstalling..."
  systemctl disable --now subpanel 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload

  rm -f "$NGINX_SITE_EN" "$NGINX_SITE_AVAIL"
  rm -f "$NGINX_RATE_FILE"
  nginx -t && systemctl reload nginx

  rm -rf "$APP_DIR"
  rm -f "$ENV_FILE"

  echo "[✓] Uninstalled."
}

write_nginx_http_only_site() {
  local domain="$1"
  cat >"$NGINX_SITE_AVAIL" <<EOF
server {
    listen 80;
    server_name ${domain};

    location /static/ {
        alias ${APP_DIR}/static/;
        expires 7d;
        add_header Cache-Control "public";
    }

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
}

write_nginx_final_site() {
  local domain="$1"
  local https_port="$2"

  cat >"$NGINX_SITE_AVAIL" <<EOF
server {
    listen 80;
    server_name ${domain};

    location /static/ {
        alias ${APP_DIR}/static/;
        expires 7d;
        add_header Cache-Control "public";
    }

    # http -> https on custom port
    return 301 https://\$host:${https_port}\$request_uri;
}

server {
    listen ${https_port} ssl;
    server_name ${domain};

    client_max_body_size 5m;

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location /static/ {
        alias ${APP_DIR}/static/;
        expires 7d;
        add_header Cache-Control "public";
    }

    location = /login {
        limit_req zone=login_zone burst=5 nodelay;

        proxy_pass http://127.0.0.1:${APP_PORT};

        proxy_set_header Host \$host:\$server_port;
        proxy_set_header X-Forwarded-Host \$host:\$server_port;
        proxy_set_header X-Forwarded-Port \$server_port;

        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location ^~ /admin {
        limit_req zone=login_zone burst=20 nodelay;

        proxy_pass http://127.0.0.1:${APP_PORT};

        proxy_set_header Host \$host:\$server_port;
        proxy_set_header X-Forwarded-Host \$host:\$server_port;
        proxy_set_header X-Forwarded-Port \$server_port;

        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};

        proxy_set_header Host \$host:\$server_port;
        proxy_set_header X-Forwarded-Host \$host:\$server_port;
        proxy_set_header X-Forwarded-Port \$server_port;

        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
}

install_all() {
  if [[ $EUID -ne 0 ]]; then
    echo "[-] Please run as root."
    exit 1
  fi

  echo "=== SubsPanel Installer ==="

  read -rp "Domain (e.g. sub.example.com): " DOMAIN
  [[ -z "${DOMAIN}" ]] && echo "[-] Domain is required." && exit 1

  read -rp "Admin username: " ADMIN_USER
  [[ -z "${ADMIN_USER}" ]] && echo "[-] Admin username is required." && exit 1

  read -rsp "Admin password: " ADMIN_PASS
  echo
  [[ -z "${ADMIN_PASS}" ]] && echo "[-] Admin password is required." && exit 1

  read -rp "Internal app port (e.g. 8000): " APP_PORT
  APP_PORT="${APP_PORT:-8000}"

  read -rp "HTTPS port for Nginx (e.g. 8443): " HTTPS_PORT
  HTTPS_PORT="${HTTPS_PORT:-8443}"

  SECRET_KEY="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"

  echo "[+] Installing packages..."
  apt-get update -y
  apt-get install -y nginx certbot python3-certbot-nginx python3 python3-venv python3-pip

  echo "[+] Creating app directory..."
  mkdir -p "$APP_DIR/templates" "$APP_DIR/static"

  echo "[+] Copying project files..."

SRC_DIR="$(pwd)"

if [[ ! -f "$SRC_DIR/app.py" ]]; then
  echo "[!] app.py not found in current directory."
  echo "[+] Downloading repository to /tmp/subspanel-src ..."

  apt-get update -y
  apt-get install -y git

  rm -rf /tmp/subspanel-src
  git clone --depth 1 https://github.com/varnooj/SubsPanel.git /tmp/subspanel-src
  SRC_DIR="/tmp/subspanel-src"
fi

cp -f "$SRC_DIR/app.py" "$APP_DIR/app.py"
cp -f "$SRC_DIR/templates/"*.html "$APP_DIR/templates/"
cp -f "$SRC_DIR/static/style.css" "$APP_DIR/static/style.css"


  echo "[+] Setting up venv..."
  python3 -m venv "$APP_DIR/.venv"
  "$APP_DIR/.venv/bin/pip" install --upgrade pip
  "$APP_DIR/.venv/bin/pip" install fastapi uvicorn jinja2 python-multipart itsdangerous qrcode pillow "qrcode[pil]"

  echo "[+] Writing env file (NOT committed to git)..."
  cat >"$ENV_FILE" <<EOF
DB_PATH=$APP_DIR/db.sqlite3
ADMIN_USER=$ADMIN_USER
ADMIN_PASS=$ADMIN_PASS
SECRET_KEY=$SECRET_KEY
EOF
  chmod 600 "$ENV_FILE"
  chown root:root "$ENV_FILE"

  echo "[+] Creating systemd service..."
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=SubsPanel (FastAPI/Uvicorn)
After=network.target

[Service]
WorkingDirectory=$APP_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$APP_DIR/.venv/bin/uvicorn app:app --host 127.0.0.1 --port $APP_PORT
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now subpanel
  systemctl restart subpanel

  echo "[+] Ensuring nginx rate-limit zone exists..."
  if [[ ! -f "$NGINX_RATE_FILE" ]]; then
    cat >"$NGINX_RATE_FILE" <<'EOF'
limit_req_zone $binary_remote_addr zone=login_zone:10m rate=10r/m;
EOF
  fi

  echo "[+] Preparing temporary HTTP-only nginx site for SSL issuance..."
  write_nginx_http_only_site "$DOMAIN"

  ln -sf "$NGINX_SITE_AVAIL" "$NGINX_SITE_EN"
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

  nginx -t && systemctl reload nginx

  echo "[+] Requesting SSL certificate (certbot) ..."
  certbot certonly --nginx -d "${DOMAIN}" --agree-tos --non-interactive --register-unsafely-without-email

  echo "[+] Writing final nginx site (80 -> https:${HTTPS_PORT}, ssl on ${HTTPS_PORT})..."
  write_nginx_final_site "$DOMAIN" "$HTTPS_PORT"

  nginx -t && systemctl reload nginx

  echo "[+] Enabling certbot timer (auto-renew)..."
  systemctl enable --now certbot.timer 2>/dev/null || true

  echo "[+] Testing renew dry-run..."
  certbot renew --dry-run || true

  echo
  echo "========================================"
  echo "[✓] SubsPanel installed successfully!"
  echo "----------------------------------------"
  echo "Login URL : https://${DOMAIN}:${HTTPS_PORT}/login"
  echo "Admin URL : https://${DOMAIN}:${HTTPS_PORT}/admin"
  echo "----------------------------------------"
  echo "Manual renew: bash install.sh renew"
  echo "Service     : systemctl status subpanel --no-pager"
  echo "========================================"
  echo

}

case "${1:-install}" in
  install) install_all ;;
  renew)   renew_ssl ;;
  uninstall) uninstall_all ;;
  *)
    echo "Usage: $0 [install|renew|uninstall]"
    exit 1
    ;;
esac
