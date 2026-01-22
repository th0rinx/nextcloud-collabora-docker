#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

need_cmd() { command -v "$1" >/dev/null 2>&1; }

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: ejecutá como root (o con sudo)." >&2
  exit 1
fi

# Cargar .env
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

# Defaults
NPM_IP="${NPM_IP:-34.118.175.190}"

NEXTCLOUD_HTTP_PORT="${NEXTCLOUD_HTTP_PORT:-8081}"
COLLABORA_HTTP_PORT="${COLLABORA_HTTP_PORT:-9980}"

NEXTCLOUD_DOMAIN="${NEXTCLOUD_DOMAIN:-cloud.tudominio.com}"
COLLABORA_DOMAIN="${COLLABORA_DOMAIN:-office.tudominio.com}"

echo "[install] start: $(date -Iseconds)"

# ---- Base packages (Ubuntu/Debian) ----
if need_cmd apt-get; then
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release ufw
else
  echo "ERROR: este script asume Debian/Ubuntu (apt-get)." >&2
  exit 1
fi

# ---- Docker + Compose v2 ----
if ! need_cmd docker; then
  echo "[install] Docker no encontrado. Instalando Docker Engine + Compose v2..."
  install -m 0755 -d /etc/apt/keyrings

  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  fi
  chmod a+r /etc/apt/keyrings/docker.gpg

  CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
  ARCH="$(dpkg --print-architecture)"

  cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable
EOF

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable docker
  systemctl restart docker
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: Docker Compose v2 plugin no está disponible (docker compose)." >&2
  exit 1
fi

# ---- Firewall (UFW): solo NPM ----
echo "[install] configurando UFW..."
ufw allow 22/tcp >/dev/null || true

# Nextcloud: SOLO desde NPM_IP
ufw delete allow "${NEXTCLOUD_HTTP_PORT}/tcp" >/dev/null 2>&1 || true
ufw allow from "${NPM_IP}" to any port "${NEXTCLOUD_HTTP_PORT}" proto tcp >/dev/null || true

# Collabora: SOLO desde NPM_IP
ufw delete allow "${COLLABORA_HTTP_PORT}/tcp" >/dev/null 2>&1 || true
ufw allow from "${NPM_IP}" to any port "${COLLABORA_HTTP_PORT}" proto tcp >/dev/null || true

ufw --force enable >/dev/null || true
ufw status verbose || true

# ---- Deploy ----
echo "[install] validando docker-compose.yml..."
docker compose config >/dev/null

echo "[install] levantando stack..."
docker compose up -d

echo "[install] estado:"
docker compose ps

# ---- Best-effort: esperar Nextcloud y configurar reverse proxy + Collabora ----
echo "[install] configurando Nextcloud (reverse proxy + richdocuments) (best-effort)..."

# Esperar a que Nextcloud responda occ
for i in {1..40}; do
  if docker exec -u www-data nextcloud php occ status >/dev/null 2>&1; then
    echo "[install] Nextcloud listo. Aplicando config..."

    # reverse-proxy correctness (evita loops / 301 / mixed content)
    docker exec -u www-data nextcloud php occ config:system:set overwriteprotocol --value="https" >/dev/null || true
    docker exec -u www-data nextcloud php occ config:system:set overwritehost --value="${NEXTCLOUD_DOMAIN}" >/dev/null || true

    # trusted proxies (NPM)
    docker exec -u www-data nextcloud php occ config:system:set trusted_proxies 0 --value="${NPM_IP}" >/dev/null || true

    # headers típicos de proxy (opcional pero recomendado)
    docker exec -u www-data nextcloud php occ config:system:set overwrite.cli.url --value="https://${NEXTCLOUD_DOMAIN}" >/dev/null || true

    # App Nextcloud Office (Collabora) => richdocuments
    docker exec -u www-data nextcloud php occ app:install richdocuments >/dev/null 2>&1 || true
    docker exec -u www-data nextcloud php occ app:enable richdocuments >/dev/null 2>&1 || true

    break
  fi
  sleep 5
done

echo
echo "=================================================="
echo "[NEXT STEPS] NPM + Nextcloud Office (Collabora)"
echo "=================================================="
echo "1) En NPM / Reverse Proxy:"
echo "   - ${NEXTCLOUD_DOMAIN}  -> http://<IP_VPS>:${NEXTCLOUD_HTTP_PORT}"
echo "   - ${COLLABORA_DOMAIN}  -> http://<IP_VPS>:${COLLABORA_HTTP_PORT}"
echo "     (IMPORTANTE: habilitar WebSockets para Collabora)"
echo
echo "2) En Nextcloud (Admin -> Settings -> Nextcloud Office):"
echo "   - URL del servidor Collabora: https://${COLLABORA_DOMAIN}"
echo
echo "3) Si al abrir un .docx ves error de socket/proxy:"
echo "   - Revisar que NPM tenga WebSocket Support ON"
echo "   - Revisar que el hostname que pusiste en Collabora (domain=...) matchee el dominio público de Nextcloud"
echo
echo "[install] done."
