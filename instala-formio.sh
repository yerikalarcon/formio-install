#!/usr/bin/env bash
# instala-formio.sh — Form.io CE + MongoDB (local) + Nginx (Ubuntu 22.04/24.04)
# Uso:
#   ./instala-formio.sh formio.urmah.ai
#   ./instala-formio.sh formio.urmah.ai --cert /etc/ssl/certificados/fullchain.pem --key /etc/ssl/certificados/privkey.pem \
#       --allow-origins "https://formio.urmah.ai,https://cliente1.com" \
#       --admin-email "admin@example.com" --admin-pass "CHANGEME"

set -euo pipefail
shopt -s nocasematch

log(){ printf "\n==== %s ====\n" "$*"; }
need(){ command -v "$1" >/dev/null 2>&1; }
die(){ echo "ERROR: $*" >&2; exit 1; }
port_busy(){ ss -ltnp 2>/dev/null | grep -qE "[\.:]${1}\s"; }

# --- sudo automático ---
if [ "${EUID:-$(id -u)}" -ne 0 ]; then exec sudo -E bash "$0" "$@"; fi

# --- args ---
if [[ $# -lt 1 ]]; then
  echo "Uso: $0 <dominio> [--cert <fullchain.pem>] [--key <privkey.pem>] [--allow-origins <CSV>] [--admin-email <email>] [--admin-pass <pass>]"
  exit 1
fi
DOMAIN="$1"; shift || true
CERT_PATH="/etc/ssl/certificados/fullchain.pem"
KEY_PATH="/etc/ssl/certificados/privkey.pem"
ALLOW_ORIGINS="https://${DOMAIN}"
ADMIN_EMAIL="admin@example.com"
ADMIN_PASS="CHANGEME"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cert) CERT_PATH="${2:-}"; shift 2;;
    --key)  KEY_PATH="${2:-}"; shift 2;;
    --allow-origins) ALLOW_ORIGINS="${2:-}"; shift 2;;
    --admin-email) ADMIN_EMAIL="${2:-}"; shift 2;;
    --admin-pass)  ADMIN_PASS="${2:-}"; shift 2;;
    *) die "Opción desconocida: $1";;
  esac
done

RUN_USER="${SUDO_USER:-$USER}"
INSTALL_DIR="/opt/formio"
MONGO_DATA="/var/lib/formio/mongo"
SITE_CONF="/etc/nginx/sites-available/formio-${DOMAIN}.conf"
SITE_LINK="/etc/nginx/sites-enabled/formio-${DOMAIN}.conf"
FORMIO_PORT="3001"
CLIENT_MAX_BODY="50m"

log "1/8 Prerrequisitos"
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y ca-certificates curl gnupg lsb-release nginx git >/dev/null 2>&1
if ! need docker; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y >/dev/null 2>&1
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1
  systemctl enable --now docker >/dev/null 2>&1
fi
systemctl enable --now nginx >/dev/null 2>&1
groupadd docker 2>/dev/null || true
usermod -aG docker "${RUN_USER}" || true

log "2/8 Certificados SSL"
[[ -f "$CERT_PATH" && -f "$KEY_PATH" ]] || die "No se encuentran los certificados en ${CERT_PATH} y ${KEY_PATH}"
sed -i -e 's/\r$//' -e 's/[ \t]*$//' "$CERT_PATH" "$KEY_PATH" || true
chmod 600 "$KEY_PATH"; chmod 644 "$CERT_PATH"; chown root:root "$KEY_PATH" "$CERT_PATH" || true
openssl x509 -noout -in "$CERT_PATH" >/dev/null 2>&1 || die "Certificado inválido"

log "3/8 Directorios"
mkdir -p "${INSTALL_DIR}" "${MONGO_DATA}"
chown -R "${RUN_USER}:${RUN_USER}" "${INSTALL_DIR}" || true

log "4/8 Docker Compose (Form.io CE + MongoDB RS)"
cd "${INSTALL_DIR}"

# compose base
cat > docker-compose.yml <<'YAML'
version: "3.9"
services:
  mongo:
    image: mongo:6
    restart: unless-stopped
    command: ["--replSet","rs0","--bind_ip_all"]
    volumes:
      - mongo-data:/data/db
    healthcheck:
      test: ["CMD", "mongosh", "--quiet", "--eval", "db.adminCommand('ping').ok"]
      interval: 10s
      timeout: 5s
      retries: 60

  formio:
    image: node:20-bookworm
    restart: unless-stopped
    working_dir: /srv/formio/server
    depends_on:
      mongo:
        condition: service_healthy
    environment:
      PORT: "3001"
    # NOTA: usamos Debian (no Alpine) y toolchain para módulos nativos
    command: >
      bash -lc "
        apt-get update &&
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends
          git python3 build-essential pkg-config ca-certificates openssl &&
        npm i -g npm@latest @formio/cli@latest &&
        test -d /srv/formio/server || git clone --depth=1 https://github.com/formio/formio.git /srv/formio/server &&
        npm ci --no-audit --no-fund || npm i &&
        npm run bootstrap &&
        npm run services &&
        node server.js
      "
    healthcheck:
      test: ["CMD-SHELL","curl -sf http://127.0.0.1:3001/health || wget -q -O- http://127.0.0.1:3001/health"]
      interval: 15s
      timeout: 5s
      retries: 60

volumes:
  mongo-data:
YAML

# override: puerto + variables
cat > docker-compose.override.yml <<YAML
services:
  formio:
    environment:
      # ReplicaSet obligatorio
      MONGO: "mongodb://mongo:27017/formio?replicaSet=rs0"
      # Credenciales admin (primer arranque)
      ADMIN_EMAIL: "${ADMIN_EMAIL}"
      ADMIN_PASSWORD: "${ADMIN_PASS}"
      # Habilita portal (necesario para admin inicial)
      PORTAL_ENABLED: "true"
    ports:
      - "127.0.0.1:${FORMIO_PORT}:3001"
YAML

# liberar puerto si estuviera tomado
if port_busy "${FORMIO_PORT}"; then
  docker ps --format '{{.ID}} {{.Ports}}' | awk -v p=":${FORMIO_PORT}->" '$0 ~ p {print $1}' | xargs -r docker stop >/dev/null 2>&1 || true
  sleep 1
fi
port_busy "${FORMIO_PORT}" && die "Puerto ${FORMIO_PORT} ocupado"

# levantar
docker compose up -d || die "Fallo al levantar docker compose"

log "5/8 Inicializar Replica Set de Mongo (rs0)"
# esperar hasta que Mongo responda ping (ya hay HC) e iniciar RS si hace falta
for _ in $(seq 1 60); do
  docker compose exec -T mongo mongosh --quiet --eval "db.adminCommand('ping').ok" >/dev/null 2>&1 && break
  sleep 2
done
docker compose exec -T mongo mongosh --quiet <<'JS' >/dev/null 2>&1 || true
try { rs.status().ok } catch (e) { rs.initiate({_id:"rs0", members:[{_id:0, host:"mongo:27017"}]}) }
JS

log "6/8 Nginx (reverse proxy + SSL + CORS + WebSockets)"
ALLOWED_REGEX="^$(echo "$ALLOW_ORIGINS" | sed 's/[[:space:]]//g' | tr ',' '\n' | sed -E 's/([][().^$*+?{}|\\])/\\\1/g' | sed 's/^/^/; s/$/$/;' | paste -sd'|' - )$"
[[ -z "${ALLOWED_REGEX}" ]] && ALLOWED_REGEX="^https://$(echo "$DOMAIN" | sed 's/[][^.$\\*+?{}()|]/\\&/g')$"

cat > "${SITE_CONF}" <<NGINX
map \$http_origin \$cors_allow {
    default "";
    ~${ALLOWED_REGEX} \$http_origin;
}

server {
  listen 80;
  listen [::]:80;
  server_name ${DOMAIN};
  return 301 https://\$host\$request_uri;
}

server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;
  server_name ${DOMAIN};

  ssl_certificate     ${CERT_PATH};
  ssl_certificate_key ${KEY_PATH};

  add_header X-Frame-Options DENY;
  add_header X-Content-Type-Options nosniff;
  add_header Referrer-Policy strict-origin-when-cross-origin;
  client_max_body_size ${CLIENT_MAX_BODY};

  set \$cors_methods "GET, POST, PUT, PATCH, DELETE, OPTIONS";
  set \$cors_headers "DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization";
  if (\$cors_allow != "") {
    add_header Access-Control-Allow-Origin \$cors_allow always;
    add_header Vary Origin always;
    add_header Access-Control-Allow-Credentials true always;
    add_header Access-Control-Allow-Methods \$cors_methods always;
    add_header Access-Control-Allow-Headers \$cors_headers always;
    add_header Access-Control-Expose-Headers "Content-Length,Content-Range" always;
  }

  if (\$request_method = OPTIONS) {
    add_header Content-Length 0;
    add_header Content-Type text/plain;
    return 204;
  }

  location / {
    proxy_pass http://127.0.0.1:${FORMIO_PORT};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 300s;
  }
}
NGINX

ln -sf "${SITE_CONF}" "${SITE_LINK}"
rm -f /etc/nginx/sites-enabled/default || true
nginx -t || die "nginx -t falló"
systemctl reload nginx || die "reload nginx falló"

log "7/8 Esperando salud del servicio (hasta 3 min)"
OK=0
for _ in $(seq 1 90); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${FORMIO_PORT}/health" || true)
  if [[ "$code" -ge 200 && "$code" -lt 500 ]]; then OK=1; break; fi
  sleep 2
done

log "8/8 Listo"
echo "URL:   https://${DOMAIN}"
echo "Nginx: ${SITE_CONF}"
echo "Dir:   ${INSTALL_DIR}"
echo
echo "Admin inicial (primer arranque):"
echo "  ${ADMIN_EMAIL} / ${ADMIN_PASS}"
[[ "$OK" -eq 1 ]] || echo "NOTA: aún inicializando; revisa: docker logs -f \$(docker compose ps -q formio)"

