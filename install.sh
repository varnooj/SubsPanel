#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config
# =========================
APP_DIR="/opt/subpanel"
ENV_FILE="/etc/subpanel.env"
SERVICE_FILE="/etc/systemd/system/subpanel.service"
NGINX_SITE_AVAIL="/etc/nginx/sites-available/subpanel"
NGINX_SITE_EN="/etc/nginx/sites-enabled/subpanel"
NGINX_RATE_FILE="/etc/nginx/conf.d/subpanel_rate_limit.conf"

REPO_URL="https://github.com/varnooj/SubsPanel.git"
REPO_BRANCH="main"

# =========================
# Helpers
# =========================
die(){ echo "[-] $*" >&2; exit 1; }
info(){ echo "[+] $*"; }
ok(){ echo "[✓] $*"; }
warn(){ echo "[!] $*"; }

require_root(){
  [[ $EUID -eq 0 ]] || die "Please run as root."
}

ensure_packages(){
  info "Installing required packages..."
  apt-get update -y
  apt-get install -y nginx certbot python3-certbot-nginx python3 python3-venv python3-pip git
}

ensure_rate_limit_zone(){
  info "Ensuring nginx rate-limit zone exists..."
  if [[ ! -f "$NGINX_RATE_FILE" ]]; then
    cat >"$NGINX_RATE_FILE" <<'EOF'
limit_req_zone $binary_remote_addr zone=login_zone:10m rate=10r/m;
EOF
  fi
}

load_env_if_exists(){
  # shellcheck disable=SC1090
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" || true
}

gen_secret(){
  python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
}

fetch_repo_to_tmp(){
  local tmp="/tmp/subspanel-src"
  rm -rf "$tmp"
  git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$tmp"
  echo "$tmp"
}

copy_project_files(){
  local src="$1"
  info "Copying project files from: $src"
  mkdir -p "$APP_DIR/templates" "$APP_DIR/static"
  cp -f "$src/app.py" "$APP_DIR/app.py"
  cp -f "$src/templates/"*.html "$APP_DIR/templates/"
  cp -f "$src/static/style.css" "$APP_DIR/static/style.css"
}

setup_venv_and_deps(){
  info "Setting up venv..."
  python3 -m venv "$APP_DIR/.venv"
  "$APP_DIR/.venv/bin/pip" install --upgrade pip
  # QR deps: qrcode[pil] includes pillow
  "$APP_DIR/.venv/bin/pip" install fastapi uvicorn jinja2 python-multipart itsdangerous "qrcode[pil]"
}

write_env(){
  local admin_user="$1"
  local admin_pass="$2"
  local app_port="$3"
  local https_port="$4"
  local domain="$5"
  local secret_key="$6"

  info "Writing env file (NOT committed to git)..."
  cat >"$ENV_FILE" <<EOF
DB_PATH=$APP_DIR/db.sqlite3
ADMIN_USER=$admin_user
ADMIN_PASS=$admin_pass
SECRET_KEY=$secret_key
APP_PORT=$app_port
HTTPS_PORT=$https_port
DOMAIN=$domain
EOF
  chmod 600 "$ENV_FILE"
  chown root:root "$ENV_FILE"
}

write_systemd_service(){
  local app_port="$1"
  info "Creating systemd service..."
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=SubsPanel (FastAPI/Uvicorn)
After=network.target

[Service]
WorkingDirectory=$APP_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$APP_DIR/.venv/bin/uvicorn app:app --host 127.0.0.1 --port $app_port
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now subpanel
  systemctl restart subpanel
}

write_nginx_http_only_site(){
  local domain="$1"
  local app_port="$2"

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
        proxy_pass http://127.0.0.1:${app_port};
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

write_nginx_final_site(){
  local domain="$1"
  local app_port="$2"
  local https_port="$3"

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

        proxy_pass http://127.0.0.1:${app_port};
        proxy_set_header Host \$host:\$server_port;
        proxy_set_header X-Forwarded-Host \$host:\$server_port;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location ^~ /admin {
        limit_req zone=login_zone burst=20 nodelay;

        proxy_pass http://127.0.0.1:${app_port};
        proxy_set_header Host \$host:\$server_port;
        proxy_set_header X-Forwarded-Host \$host:\$server_port;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:${app_port};
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

enable_nginx_site(){
  ln -sf "$NGINX_SITE_AVAIL" "$NGINX_SITE_EN"
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
  nginx -t && systemctl reload nginx
}

request_certificate(){
  local domain="$1"
  info "Requesting SSL certificate for: $domain"
  # Port 80 must be open + DNS correct
  certbot certonly --nginx -d "$domain" --agree-tos --non-interactive --register-unsafely-without-email
}

enable_certbot_timer(){
  info "Enabling certbot timer (auto-renew)..."
  systemctl enable --now certbot.timer 2>/dev/null || true
}

print_success(){
  local domain="$1"
  local https_port="$2"
  echo
  echo "========================================"
  ok "SubsPanel is ready!"
  echo "----------------------------------------"
  echo "Login URL : https://${domain}:${https_port}/login"
  echo "Admin URL : https://${domain}:${https_port}/admin"
  echo "----------------------------------------"
  echo "Service   : systemctl status subpanel --no-pager"
  echo "Logs      : journalctl -u subpanel -n 200 --no-pager"
  echo "Renew SSL : bash install.sh renew"
  echo "========================================"
  echo
}

# =========================
# Actions
# =========================
install_panel(){
  require_root
  echo "=== SubsPanel Installer ==="

  read -rp "Domain (e.g. sub.example.com): " DOMAIN
  [[ -n "${DOMAIN:-}" ]] || die "Domain is required."

  read -rp "Admin username: " ADMIN_USER
  [[ -n "${ADMIN_USER:-}" ]] || die "Admin username is required."

  read -rsp "Admin password: " ADMIN_PASS
  echo
  [[ -n "${ADMIN_PASS:-}" ]] || die "Admin password is required."

  read -rp "Internal app port (e.g. 8000): " APP_PORT
  APP_PORT="${APP_PORT:-8000}"

  read -rp "HTTPS port for Nginx (e.g. 8443): " HTTPS_PORT
  HTTPS_PORT="${HTTPS_PORT:-8443}"

  SECRET_KEY="$(gen_secret)"

  ensure_packages

  info "Creating app directory..."
  mkdir -p "$APP_DIR/templates" "$APP_DIR/static"

  local src
  if [[ -f "./app.py" ]]; then
    src="$(pwd)"
  else
    warn "app.py not found in current directory. Downloading repo..."
    src="$(fetch_repo_to_tmp)"
  fi

  copy_project_files "$src"
  setup_venv_and_deps
  write_env "$ADMIN_USER" "$ADMIN_PASS" "$APP_PORT" "$HTTPS_PORT" "$DOMAIN" "$SECRET_KEY"
  write_systemd_service "$APP_PORT"

  ensure_rate_limit_zone

  info "Preparing temporary HTTP-only nginx site for SSL issuance..."
  write_nginx_http_only_site "$DOMAIN" "$APP_PORT"
  enable_nginx_site

  request_certificate "$DOMAIN"

  info "Writing final nginx site (80 -> https:${HTTPS_PORT}, ssl on ${HTTPS_PORT})..."
  write_nginx_final_site "$DOMAIN" "$APP_PORT" "$HTTPS_PORT"
  enable_nginx_site

  enable_certbot_timer
  info "Testing renew dry-run..."
  certbot renew --dry-run || true

  print_success "$DOMAIN" "$HTTPS_PORT"
}

renew_certificate(){
  require_root
  info "Running certbot renew..."
  certbot renew
  nginx -t && systemctl reload nginx
  ok "Renew done."
}

change_configuration(){
  require_root
  load_env_if_exists

  echo "=== Change Configuration ==="
  echo "(Current) DOMAIN=${DOMAIN:-?}  APP_PORT=${APP_PORT:-?}  HTTPS_PORT=${HTTPS_PORT:-?}"
  echo

  read -rp "New Domain (leave empty to keep current): " NEW_DOMAIN
  NEW_DOMAIN="${NEW_DOMAIN:-${DOMAIN:-}}"
  [[ -n "$NEW_DOMAIN" ]] || die "Domain is required."

  read -rp "New Admin username (leave empty to keep current): " NEW_ADMIN_USER
  NEW_ADMIN_USER="${NEW_ADMIN_USER:-${ADMIN_USER:-admin}}"

  read -rsp "New Admin password (leave empty to keep current): " NEW_ADMIN_PASS
  echo
  NEW_ADMIN_PASS="${NEW_ADMIN_PASS:-${ADMIN_PASS:-}}"
  [[ -n "$NEW_ADMIN_PASS" ]] || die "Admin password cannot be empty."

  read -rp "New Internal app port (leave empty to keep current): " NEW_APP_PORT
  NEW_APP_PORT="${NEW_APP_PORT:-${APP_PORT:-8000}}"

  read -rp "New HTTPS port (leave empty to keep current): " NEW_HTTPS_PORT
  NEW_HTTPS_PORT="${NEW_HTTPS_PORT:-${HTTPS_PORT:-8443}}"

  # Keep SECRET_KEY if exists; regenerate only if missing
  local NEW_SECRET_KEY="${SECRET_KEY:-}"
  if [[ -z "$NEW_SECRET_KEY" ]]; then
    NEW_SECRET_KEY="$(gen_secret)"
    warn "SECRET_KEY was missing. Generated a new one."
  fi

  ensure_packages
  ensure_rate_limit_zone

  # Update env + service
  write_env "$NEW_ADMIN_USER" "$NEW_ADMIN_PASS" "$NEW_APP_PORT" "$NEW_HTTPS_PORT" "$NEW_DOMAIN" "$NEW_SECRET_KEY"
  write_systemd_service "$NEW_APP_PORT"

  # Prepare nginx HTTP-only, get/renew cert for NEW_DOMAIN, then final
  info "Preparing temporary HTTP-only nginx site for SSL issuance..."
  write_nginx_http_only_site "$NEW_DOMAIN" "$NEW_APP_PORT"
  enable_nginx_site

  request_certificate "$NEW_DOMAIN"

  info "Writing final nginx site..."
  write_nginx_final_site "$NEW_DOMAIN" "$NEW_APP_PORT" "$NEW_HTTPS_PORT"
  enable_nginx_site

  enable_certbot_timer
  print_success "$NEW_DOMAIN" "$NEW_HTTPS_PORT"
}

update_panel(){
  require_root
  ensure_packages

  info "Updating panel to latest code (DB/env will be kept)..."
  local src
  src="$(fetch_repo_to_tmp)"

  # Update app/templates/static only
  copy_project_files "$src"

  # Ensure deps exist (safe re-run)
  if [[ -d "$APP_DIR/.venv" ]]; then
    "$APP_DIR/.venv/bin/pip" install --upgrade pip
    "$APP_DIR/.venv/bin/pip" install fastapi uvicorn jinja2 python-multipart itsdangerous "qrcode[pil]"
  else
    setup_venv_and_deps
  fi

  systemctl restart subpanel || true
  ok "Updated."
  load_env_if_exists
  if [[ -n "${DOMAIN:-}" && -n "${HTTPS_PORT:-}" ]]; then
    echo "Admin: https://${DOMAIN}:${HTTPS_PORT}/admin"
  fi
}

uninstall_panel(){
  require_root
  warn "Uninstalling..."
  systemctl disable --now subpanel 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload

  rm -f "$NGINX_SITE_EN" "$NGINX_SITE_AVAIL"
  rm -f "$NGINX_RATE_FILE"
  nginx -t && systemctl reload nginx || true

  rm -rf "$APP_DIR"
  rm -f "$ENV_FILE"

  ok "Uninstalled."
}

# =========================
# Menu / CLI
# =========================
menu(){
  echo "========================================"
  echo " SubsPanel Manager"
  echo "========================================"
  echo "1) Install Panel"
  echo "2) Renew Certificate"
  echo "3) Change Configuration (Ports/User/Domain + New Certificate)"
  echo "4) Update Panel (to latest code)"
  echo "5) Uninstall Panel"
  echo "0) Exit"
  echo "----------------------------------------"
  read -rp "Select an option: " choice
  case "$choice" in
    1) install_panel ;;
    2) renew_certificate ;;
    3) change_configuration ;;
    4) update_panel ;;
    5) uninstall_panel ;;
    0) exit 0 ;;
    *) die "Invalid option." ;;
  esac
}

case "${1:-menu}" in
  menu) menu ;;
  install) install_panel ;;
  renew) renew_certificate ;;
  config) change_configuration ;;
  update) update_panel ;;
  uninstall) uninstall_panel ;;
  *)
    echo "Usage: $0 [menu|install|renew|config|update|uninstall]"
    exit 1
    ;;
esac