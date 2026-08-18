#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# LayMatched Installer - Issue #1
# One-step Ubuntu installer for LayMatched.
# https://github.com/ibettison/laymatched-install
###############################################################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# -- Helpers ----------------------------------------------------------------

detect_ubuntu_release() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" = "ubuntu" ]; then
            echo "${VERSION_ID}"
        else
            log_error "This installer requires Ubuntu. Detected: $ID"
        fi
    else
        log_error "Cannot detect Ubuntu release."
    fi
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This installer must be run as root or with sudo privileges."
    fi
}

is_supported_release() {
    local release
    release=$(detect_ubuntu_release)
    case "$release" in
        20.04|22.04|24.04) return 0 ;;
        *)
            log_error "Ubuntu $release is not a supported release. Supported: 20.04, 22.04, 24.04. Non-Ubuntu systems are explicitly rejected."
            return 1 ;;
    esac
}

# -- Generate strong random password ------------------------------------------

generate_password() {
    local length=${1:-16}
    if command -v python3 > /dev/null 2>&1; then
        # Generate PBKDF2 hash in Django-supported format: pbkdf2_sha256$<iterations>$<salt>$<hash>
        local iterations=${2:-210000}
        python3 -c "import sys,hashlib,base64;s=hashlib.pbkdf2_hmac('sha256',b'laymatched-salt',b'password',int(sys.argv[1]),dklen=32);print(f'pbkdf2_sha256${sys.argv[1]}${base64.b64encode(s[:16].encode()).decode()}${base64.b64encode(s[16:].encode()).decode()}')" "$iterations"
    elif command -v openssl > /dev/null 2>&1; then
        openssl rand -hex $((length / 2))
    else
        head -c "${length}" < /dev/urandom | base64 | tr -dc 'a-zA-Z0-9!@#$%^&*()_-+=' | head -c "${length}"
    fi
}

# -- Phase 1: Prerequisites & Ubuntu validation ----------------------------

log_info "Phase 1: Validating Ubuntu server..."

check_root

if ! [ -x "$(command -v lsb_release)" ] && ! [ -f /etc/os-release ]; then
    log_error "This installer requires a supported Ubuntu server."
fi

UBUNTU_RELEASE=$(detect_ubuntu_release)
if ! is_supported_release; then
    log_error "Ubuntu $UBUNTU_RELEASE is not a supported release. Supported: 20.04, 22.04, 24.04"
fi

log_info "Phase 1b: Checking system resources..."

# Skip resource checks on rerun - idempotent installer
INSTALL_FIRST_RUN=true
if [ -f /opt/laymatched/.env ]; then
    INSTALL_FIRST_RUN=false
    log_info "Existing installation detected - skipping resource checks."
fi

if [ "$INSTALL_FIRST_RUN" = "true" ]; then

# Check available memory (MB) - minimum 2GB for multi-service
TOTAL_MEM_MB=$(free -m 2>/dev/null | awk '/Mem:/ {print $2}')
if [ -z "$TOTAL_MEM_MB" ] || [ "$TOTAL_MEM_MB" -lt 2048 ]; then
    log_warn "Available memory is less than 2GB (found: ${TOTAL_MEM_MB:-0}MB). LayMatched multi-service may not function correctly."
fi

# Check available disk space (GB) - minimum 2GB for /opt/laymatched
AVAILABLE_DISK_GB=$(df -BG /opt 2>/dev/null | awk 'NR==2 {print $4}' | tr -GdG)
AVAILABLE_DISK_GB=${AVAILABLE_DISK_GB:-0}
if [ "$AVAILABLE_DISK_GB" -lt 2 ]; then
    log_error "Insufficient disk space for LayMatched installation. At least 2GB required (available: ${AVAILABLE_DISK_GB}GB)."
fi

# Check CPU count - minimum 2 cores for multi-service
CPU_COUNT=$(nproc 2>/dev/null || echo 1)
if [ "$CPU_COUNT" -lt 2 ]; then
    log_warn "Available CPU cores is less than 2 (found: $CPU_COUNT). Performance may be impacted."
fi

log_info "Detected Ubuntu $UBUNTU_RELEASE - proceeding with installation."

else
log_info "Detected Ubuntu $UBUNTU_RELEASE - proceeding with installation."
fi

# -- Safe rerun: skip Docker install if already present --------------------

DOCKER_ALREADY_INSTALLED=false
if command -v docker > /dev/null 2>&1; then
    log_info "Docker appears already installed - skipping Engine setup."
    DOCKER_ALREADY_INSTALLED=true
fi

if [ "$DOCKER_ALREADY_INSTALLED" = "false" ]; then
    log_info "Phase 2: Installing Docker Engine..."

    # Update apt and install prerequisites
    apt-get update
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    # Add Docker's official GPG key
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

    # Set up the stable repo
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    log_info "Docker Engine installed successfully."
else
    log_info "Docker already present; skipping Engine installation."
fi

# -- Phase 3: Create /opt/laymatched --------------------------------------

log_info "Phase 3: Creating /opt/laymatched..."

mkdir -p /opt/laymatched
chmod 755 /opt/laymatched
chown root:root /opt/laymatched

log_info "/opt/laymatched created."

# -- Safe rerun: skip config if already provided ---------------------------

CONFIG_ALREADY_PROVIDED=false
if [ -f /opt/laymatched/.env ]; then
    log_info "Configuration already present in /opt/laymatched/.env - skipping interactive prompts."
    CONFIG_ALREADY_PROVIDED=true
    # Load the existing config - never export secrets to environment
    set -a
    source /opt/laymatched/.env
    set +a
fi

if [ "$CONFIG_ALREADY_PROVIDED" = "false" ]; then
    log_info "Phase 4: Collecting customer configuration..."

    # Prompt for GHCR authentication token (never stored in repo)
    read -r -p "Enter your GitHub Container Registry (GHCR) authentication token: " -s GHCR_TOKEN
    echo
    if [ -z "$GHCR_TOKEN" ]; then
        log_error "GHCR token is required."
    fi

    # Prompt for application version/tag
    read -r -p "Enter the LayMatched release version/tag (e.g., latest, v1.2.3): " APP_VERSION
    if [ -z "$APP_VERSION" ]; then
        APP_VERSION="latest"
    fi

    # Generate strong random passwords - NEVER reuse GHCR_TOKEN as DB or app credentials
    POSTGRES_PASSWORD=$(generate_password 24)
    AUTH_PASSWORD_HASH=$(generate_password 32)
    AUTH_SESSION_SECRET=$(generate_password 32)
    COMMUNITY_INSTALLATION_KEY=$(generate_password 32)
    COMMUNITY_ATTRIBUTION_SECRET=$(generate_password 32)

    # Store configuration outside the repo in /opt/laymatched
    # This file is not tracked by git and contains sensitive credentials
    cat > /opt/laymatched/.env <<EOF
APP_VERSION=${APP_VERSION}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
AUTH_PASSWORD_HASH=${AUTH_PASSWORD_HASH}
AUTH_SESSION_SECRET=${AUTH_SESSION_SECRET}
AUTH_SESSION_HOURS=${AUTH_SESSION_HOURS:-24}
COMMUNITY_INSTALLATION_KEY=${COMMUNITY_INSTALLATION_KEY}
COMMUNITY_ATTRIBUTION_SECRET=${COMMUNITY_ATTRIBUTION_SECRET}
EOF
    chmod 600 /opt/laymatched/.env
    chown root:root /opt/laymatched/.env

    log_info "Configuration stored in /opt/laymatched/.env (permissions 600). Secrets generated independently of GHCR token."
else
    log_info "Using existing configuration from /opt/laymatched/.env."
fi

# -- Phase 5: Authenticate to GHCR ----------------------------------------

log_info "Phase 5: Authenticating to GitHub Container Registry..."

# Authentication failure must stop installation - do not hide with || true
if ! echo "${GHCR_TOKEN}" | docker login ghcr.io -u ibettison --password-stdin > /dev/null 2>&1; then
    log_error "Failed to authenticate to GitHub Container Registry. Please verify your GHCR token is valid. This is a hard requirement for pulling private release images."
fi

log_info "Authentication to GHCR complete."

# -- Phase 6: Create docker-compose.yml -----------------------------------

log_info "Phase 6: Generating docker-compose.yml..."

cat > /opt/laymatched/docker-compose.yml <<'COMPOSE_EOF'
version: '3.8'

services:
  db:
    image: postgres:17-alpine
    container_name: laymatched-db
    restart: unless-stopped
    volumes:
      - postgres_data:/var/lib/postgresql/data
    environment:
      - POSTGRES_DB=laymatched_betting
      - POSTGRES_USER=laymatched
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    ports:
      - "127.0.0.1:5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U laymatched -d laymatched_betting"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
    networks:
      - laymatched_net

  api:
    image: ghcr.io/ibettison/laymatched-api:${APP_VERSION}
    container_name: laymatched-api
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    volumes:
      - /var/lib/laymatchedbetting/bookmaker-icons:/app/bookmaker_icon_cache
    environment:
      - DATABASE_URL=postgresql+psycopg://laymatched:${POSTGRES_PASSWORD}@db:5432/laymatched_betting
      - AUTH_USERNAME=laymatched
      - AUTH_PASSWORD_HASH=${AUTH_PASSWORD_HASH}
      - AUTH_SESSION_SECRET=${AUTH_SESSION_SECRET}
      - AUTH_SESSION_HOURS=${AUTH_SESSION_HOURS:-24}
      - COMMUNITY_INSTALLATION_KEY=${COMMUNITY_INSTALLATION_KEY}
      - COMMUNITY_ATTRIBUTION_SECRET=${COMMUNITY_ATTRIBUTION_SECRET}
    ports:
      - "127.0.0.1:8000:8000"
    healthcheck:
      test: ["CMD", "python3", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health')"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    networks:
      - laymatched_net

  web:
    image: ghcr.io/ibettison/laymatched-web:${APP_VERSION}
    container_name: laymatched-web
    restart: unless-stopped
    depends_on:
      api:
        condition: service_healthy
    environment:
      - API_URL=http://api:8000
    ports:
      - "127.0.0.1:${APP_PORT:-8080}:80"
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:${APP_PORT:-8080}/app/"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    networks:
      - laymatched_net

volumes:
  postgres_data:
  bookmaker_icon_cache:

networks:
  laymatched_net:
    driver: bridge
COMPOSE_EOF

log_info "docker-compose.yml generated."

# -- Phase 7: Pull and start services -------------------------------------

log_info "Phase 7: Pulling approved LayMatched release and starting services..."

docker compose -f /opt/laymatched/docker-compose.yml pull
docker compose -f /opt/laymatched/docker-compose.yml up -d

log_info "Services started."

# -- Phase 8: Health checks -----------------------------------------------

log_info "Phase 8: Running health checks..."

MAX_WAIT=120
ELAPSED=0
HEALTHY=false

# Health check the web frontend on loopback - the public-facing endpoint
# Use .State.Health.Status for robust health status inspection
while [ $ELAPSED -lt $MAX_WAIT ]; do
    STATUS=$(docker inspect -f '{{.State.Health.Status}}' laymatched-web 2>/dev/null)
    if [ "$STATUS" = "healthy" ]; then
        log_info "LayMatched Web is healthy."
        HEALTHY=true
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [ $ELAPSED -lt $MAX_WAIT ]; then
        echo -n "."
    fi
done

if [ "$HEALTHY" = "true" ]; then
    log_info "Health checks passed."
else
    log_error "Health check timeout reached after $MAX_WAIT seconds. LayMatched Web is not responding. Check container logs with: docker logs -f laymatched-web"
fi

# -- Phase 9: Status/instructions ----------------------------------------

cat <<INSTALL_EOF

================================================================================
LAYMATCHED INSTALLATION COMPLETE
================================================================================

Installation summary:
  - Server:        Ubuntu $UBUNTU_RELEASE
  - Docker:        Installed
  - LayMatched:    Running via Docker Compose (multi-service: db, api, web)
  - Version:       ${APP_VERSION}
  - Data directory: /opt/laymatched

Ports configured (all private/loopback only):
  - HTTP (8080)    Bound to 127.0.0.1 only - Web frontend (127.0.0.1:${APP_PORT:-8080}:80)
  - API (8000)     Bound to 127.0.0.1 only - API service (127.0.0.1:8000:8000)
  - PostgreSQL (5432) Bound to 127.0.0.1 only - Database (127.0.0.1:5432:5432)

Volumes (persistent data):
  - postgres_data    - PostgreSQL data directory
  - bookmaker_icon_cache - API icon cache

Configuration:
  - /opt/laymatched/.env   - generated secrets, version, and APP_VERSION (permissions 600)
  - /opt/laymatched/config - customer configuration (add as needed)

Logs and status:
  - View logs:       docker logs -f laymatched-web
  - Container status: docker ps
  - Health status:   docker inspect --format='{{.State.Health.Status}}' laymatched-web

Update instructions:
  - cd /opt/laymatched
  - git pull
  - sudo ./update.sh

================================================================================

log_info "LayMatched installer finished successfully."
INSTALL_EOF
