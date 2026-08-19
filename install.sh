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

# -- Generate strong random secret (for DB, sessions, keys) --------------------

generate_secret() {
    local length=${1:-32}
    if command -v openssl > /dev/null 2>&1; then
        openssl rand -hex $((length / 2))
    elif command -v python3 > /dev/null 2>&1; then
        python3 -c "import secrets; print(secrets.token_hex($((length // 2))))"
    else
        head -c "${length}" < /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c "${length}"
    fi
}

# -- Auth API: Exchange Installer Token for registry credentials -------------
# Calls LayMatched Auth API to get short-lived registry token and approved version.
# Sets: REGISTRY_TOKEN, APPROVED_VERSION, REGISTRY_URL

AUTH_API_URL="https://api.laymatched.com/installer/authorize"

# Validate version string: alphanumeric, dots, dashes, underscores only
validate_version() {
    local version="$1"
    case "$version" in
        *[![:alnum:]._-]*) return 1 ;;
        "") return 1 ;;
        *) return 0 ;;
    esac
}

# Validate registry URL: must be a valid hostname (no scheme, no path)
validate_registry_url() {
    local url="$1"
    # Allow hostname:port or just hostname
    case "$url" in
        *[![:alnum:].:-]*) return 1 ;;
        "") return 1 ;;
        *) return 0 ;;
    esac
}

call_auth_api() {
    local installer_token="$1"
    log_info "Contacting LayMatched authorization service..."

    # Build JSON safely using python3 to avoid injection issues
    local json_payload
    json_payload=$(python3 -c "import json, sys; print(json.dumps({'installer_token': sys.argv[1])})" "$installer_token")

    local response
    if ! response=$(curl -fsS -X POST \
        -H "Content-Type: application/json" \
        -d "$json_payload" \
        "${AUTH_API_URL}" 2>/dev/null); then
        log_error "Failed to contact LayMatched authorization service. Check network connectivity and try again."
    fi

    # Parse JSON response using python3 (available on target Ubuntu)
    REGISTRY_TOKEN=$(echo "${response}" | python3 -c "import sys, json; print(json.load(sys.stdin).get('registry_token', ''))")
    APPROVED_VERSION=$(echo "${response}" | python3 -c "import sys, json; print(json.load(sys.stdin).get('approved_version', ''))")
    REGISTRY_URL=$(echo "${response}" | python3 -c "import sys, json; print(json.load(sys.stdin).get('registry_url', ''))")

    if [ -z "${REGISTRY_TOKEN}" ] || [ -z "${APPROVED_VERSION}" ] || [ -z "${REGISTRY_URL}" ]; then
        log_error "Invalid response from authorization service. Token may be invalid or expired."
    fi

    # Validate approved_version and registry_url before use
    if ! validate_version "${APPROVED_VERSION}"; then
        log_error "Invalid approved_version from authorization service: ${APPROVED_VERSION}"
    fi
    if ! validate_registry_url "${REGISTRY_URL}"; then
        log_error "Invalid registry_url from authorization service: ${REGISTRY_URL}"
    fi

    log_info "Authorization successful. Approved version: ${APPROVED_VERSION}"
}

# -- Generate PBKDF2 password hash matching backend/scripts/create_credentials.py ---
# Takes password as argument, outputs: pbkdf2_sha256$$600000$$<urlsafe_b64_salt>$$<urlsafe_b64_digest>
# NOTE: Outputs DOUBLE dollar ($$) for Docker Compose .env interpolation.
# Docker Compose resolves $$ -> $ in .env files, so container receives correct single $ hash.

generate_password_hash() {
    local password="$1"
    if [ -z "$password" ]; then
        log_error "Password cannot be empty."
    fi
    if command -v python3 > /dev/null 2>&1; then
        python3 -c '
import hashlib, base64, secrets, sys
password = sys.argv[1].encode()
salt = secrets.token_bytes(18)
iterations = 600000
dk = hashlib.pbkdf2_hmac("sha256", password, salt, iterations, dklen=32)
salt_b64 = base64.urlsafe_b64encode(salt).decode().rstrip("=")
dk_b64 = base64.urlsafe_b64encode(dk).decode().rstrip("=")
# Use $$ in f-string (followed by {) to output $$ (double dollar) for Docker Compose .env escaping
print(f"pbkdf2_sha256$${iterations}$${salt_b64}$${dk_b64}")
' "$password"
    else
        log_error "Python3 is required to generate password hash."
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
AVAILABLE_DISK_GB=$(df -BG /opt 2>/dev/null | awk 'NR==2 {gsub(/G/, "", $4); print $4}')
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

# -- Verify Docker Compose plugin is available -----------------------------

log_info "Verifying Docker Compose plugin..."

if ! docker compose version > /dev/null 2>&1; then
    log_warn "Docker Compose plugin not available - attempting to install..."
    apt-get update
    if apt-get install -y docker-compose-plugin; then
        log_info "Docker Compose plugin installed successfully."
        # Re-verify after installation
        if ! docker compose version > /dev/null 2>&1; then
            log_error "Docker Compose plugin installed but 'docker compose version' still fails. Compose is not usable."
        fi
        log_info "Docker Compose plugin verified: $(docker compose version --short)"
    else
        log_error "Failed to install Docker Compose plugin. Please install it manually: apt-get install docker-compose-plugin"
    fi
else
    log_info "Docker Compose plugin verified: $(docker compose version --short)"
fi

# -- Phase 3: Create /opt/laymatched --------------------------------------

log_info "Phase 3: Creating /opt/laymatched..."

mkdir -p /opt/laymatched
chmod 750 /opt/laymatched
chown root:root /opt/laymatched

log_info "/opt/laymatched created."

# -- Safe rerun: skip config if already provided ---------------------------

CONFIG_ALREADY_PROVIDED=false
if [ -f /opt/laymatched/.env ]; then
    log_info "Configuration already present in /opt/laymatched/.env - skipping interactive prompts."
    CONFIG_ALREADY_PROVIDED=true
    # Load only APP_VERSION from .env safely (without expanding $$ in AUTH_PASSWORD_HASH)
    # Use a safe parser that doesn't evaluate shell expansions
    APP_VERSION=$(grep '^APP_VERSION=' /opt/laymatched/.env | cut -d'=' -f2-)
    # Load REGISTRY_URL if present (legacy .env may not have it)
    REGISTRY_URL=$(grep '^REGISTRY_URL=' /opt/laymatched/.env | cut -d'=' -f2-)
fi

if [ "$CONFIG_ALREADY_PROVIDED" = "false" ]; then
    log_info "Phase 4: Collecting customer configuration..."

    # Prompt for LayMatched Installer Token (never stored in .env, never in repo)
    # Prevent token from appearing in shell history
    set +o history
    read -r -p "Enter your LayMatched Installer Token: " -s INSTALLER_TOKEN
    echo
    set -o history
    if [ -z "$INSTALLER_TOKEN" ]; then
        log_error "LayMatched Installer Token is required."
    fi

    # Call Auth API to get registry credentials and approved version
    call_auth_api "$INSTALLER_TOKEN"
    APP_VERSION="${APPROVED_VERSION}"

    # Prompt for LayMatched login credentials (matches backend/scripts/create_credentials.py)
    # Collect Login ID in outer scope
    login_id=""
    while [ -z "$login_id" ]; do
        read -r -p "Enter LayMatched Login ID: " login_id
        if [ -z "$login_id" ]; then
            log_error "Login ID cannot be empty."
        fi
    done
    AUTH_USERNAME=$login_id

    # Collect password in outer scope (hidden, with confirmation)
    password=""
    password_confirm=""
    while true; do
        set +o history
        read -r -p "Enter LayMatched password (min 12 chars): " -s password
        echo
        read -r -p "Confirm LayMatched password: " -s password_confirm
        echo
        set -o history

        if [ ${#password} -lt 12 ]; then
            log_warn "Password must be at least 12 characters."
            continue
        fi
        if [ "$password" != "$password_confirm" ]; then
            log_warn "Passwords do not match."
            continue
        fi
        break
    done

    # Generate hash using pure helper
    AUTH_PASSWORD_HASH=$(generate_password_hash "$password")

    # Generate strong random secrets - NEVER reuse installer token as DB or app credentials
    POSTGRES_PASSWORD=$(generate_secret 24)
    AUTH_SESSION_SECRET=$(generate_secret 32)
    COMMUNITY_INSTALLATION_KEY=$(generate_secret 32)
    COMMUNITY_ATTRIBUTION_SECRET=$(generate_secret 32)

    # Store configuration outside the repo in /opt/laymatched
    # This file is not tracked by git and contains sensitive credentials
    # Installer Token and Registry Token are NOT persisted - only used for initial auth/pull
    cat > /opt/laymatched/.env <<EOF
APP_VERSION=${APP_VERSION}
REGISTRY_URL=${REGISTRY_URL}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
AUTH_USERNAME=${AUTH_USERNAME}
AUTH_PASSWORD_HASH=${AUTH_PASSWORD_HASH}
AUTH_SESSION_SECRET=${AUTH_SESSION_SECRET}
AUTH_SESSION_HOURS=${AUTH_SESSION_HOURS:-24}
COMMUNITY_INSTALLATION_KEY=${COMMUNITY_INSTALLATION_KEY}
COMMUNITY_ATTRIBUTION_SECRET=${COMMUNITY_ATTRIBUTION_SECRET}
EOF
    chmod 600 /opt/laymatched/.env
    chown root:root /opt/laymatched/.env

    log_info "Configuration stored in /opt/laymatched/.env (permissions 600). Secrets generated independently of installer token."
else
    # On rerun: Load existing APP_VERSION and re-authenticate via Auth API
    log_info "Existing installation detected - re-authorizing for image pull."
    ORIGINAL_APP_VERSION=$(grep '^APP_VERSION=' /opt/laymatched/.env | cut -d'=' -f2-)
    ORIGINAL_REGISTRY_URL=$(grep '^REGISTRY_URL=' /opt/laymatched/.env | cut -d'=' -f2-)
    set +o history
    read -r -p "Enter your LayMatched Installer Token: " -s INSTALLER_TOKEN
    echo
    set -o history
    if [ -z "$INSTALLER_TOKEN" ]; then
        log_error "LayMatched Installer Token is required."
    fi
    call_auth_api "$INSTALLER_TOKEN"
    # Use the approved version from API (could differ from stored if new release approved)
    APP_VERSION="${APPROVED_VERSION}"
    # Candidate registry URL - will be persisted only after health checks pass
    CANDIDATE_REGISTRY_URL="${REGISTRY_URL}"
    log_info "Using existing configuration from /opt/laymatched/.env. Approved version: ${APP_VERSION}"

    # -- Prepare candidate .env for rerun deployment -----------------------
    # Create candidate .env with new version/registry for Compose interpolation
    cd /opt/laymatched
    cp .env .env.candidate
    sed -i "s/^APP_VERSION=.*/APP_VERSION=${APP_VERSION}/" .env.candidate
    # Handle REGISTRY_URL: replace if exists, append if missing (legacy .env migration)
    if grep -q '^REGISTRY_URL=' .env.candidate; then
        sed -i "s|^REGISTRY_URL=.*|REGISTRY_URL=${CANDIDATE_REGISTRY_URL}|" .env.candidate
    else
        echo "REGISTRY_URL=${CANDIDATE_REGISTRY_URL}" >> .env.candidate
    fi
    cd - > /dev/null
fi

# -- Phase 5: Authenticate to LayMatched Registry ----------------------------

log_info "Phase 5: Authenticating to LayMatched Container Registry..."

# Authenticate using short-lived registry token from Auth API
if ! echo "${REGISTRY_TOKEN}" | docker login "${REGISTRY_URL}" -u laymatched-installer --password-stdin > /dev/null 2>&1; then
    log_error "Failed to authenticate to LayMatched Container Registry. Please verify your Installer Token is valid."
fi

log_info "Authentication to LayMatched Registry complete."

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
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U laymatched -d laymatched_betting"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
    networks:
      - laymatched_net

  api:
    image: ${REGISTRY_URL}/laymatched-api:${APP_VERSION}
    container_name: laymatched-api
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    volumes:
      - bookmaker_icon_cache:/var/lib/laymatchedbetting/bookmaker-icons
    environment:
      - DATABASE_URL=postgresql+psycopg://laymatched:${POSTGRES_PASSWORD}@db:5432/laymatched_betting
      - AUTH_USERNAME=${AUTH_USERNAME}
      - AUTH_PASSWORD_HASH=${AUTH_PASSWORD_HASH}
      - AUTH_SESSION_SECRET=${AUTH_SESSION_SECRET}
      - AUTH_SESSION_HOURS=${AUTH_SESSION_HOURS:-24}
      - COMMUNITY_INSTALLATION_KEY=${COMMUNITY_INSTALLATION_KEY}
      - COMMUNITY_ATTRIBUTION_SECRET=${COMMUNITY_ATTRIBUTION_SECRET}
    healthcheck:
      test: ["CMD", "python3", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=5)"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    networks:
      - laymatched_net

  web:
    image: ${REGISTRY_URL}/laymatched-web:${APP_VERSION}
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
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1/app/"]
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

# -- Phase 6b: Install and configure Nginx reverse proxy -------------------

log_info "Phase 6b: Installing and configuring Nginx reverse proxy..."

# Install Nginx if not already installed
NGINX_ALREADY_INSTALLED=false
if command -v nginx > /dev/null 2>&1; then
    log_info "Nginx appears already installed - skipping package installation."
    NGINX_ALREADY_INSTALLED=true
fi

if [ "$NGINX_ALREADY_INSTALLED" = "false" ]; then
    apt-get update
    apt-get install -y nginx
    log_info "Nginx installed successfully."
else
    log_info "Nginx already present; skipping package installation."
fi

# Create LayMatched Nginx site configuration
cat > /etc/nginx/sites-available/laymatched <<'NGINX_EOF'
server {
    listen 80;
    server_name _;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
    add_header Referrer-Policy "strict-origin-when-cross-origin";

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        # Timeouts
        proxy_connect_timeout 30s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    # Health endpoint for load balancer checks
    location /nginx-health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
NGINX_EOF

log_info "Nginx site configuration created at /etc/nginx/sites-available/laymatched."

# Enable LayMatched site and disable default site
ln -sf /etc/nginx/sites-available/laymatched /etc/nginx/sites-enabled/laymatched
rm -f /etc/nginx/sites-enabled/default
log_info "Nginx site enabled (default site disabled)."

# Validate Nginx configuration
if ! nginx -t; then
    log_error "Nginx configuration test failed."
fi
log_info "Nginx configuration test passed."

# Start or reload Nginx
if systemctl is-active --quiet nginx; then
    systemctl reload nginx
    log_info "Nginx reloaded."
else
    systemctl enable --now nginx
    log_info "Nginx enabled and started."
fi

# Copy update.sh to installation directory for future updates
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "${SCRIPT_DIR}/update.sh" /opt/laymatched/update.sh
chmod +x /opt/laymatched/update.sh
log_info "update.sh copied to /opt/laymatched/"

# -- Phase 7: Pull and start services -------------------------------------

log_info "Phase 7: Pulling approved LayMatched release and starting services..."

# Run docker compose from /opt/laymatched
cd /opt/laymatched

# For rerun: use candidate .env with new version/registry
# For fresh install: use persistent .env (already has correct values)
if [ "${CONFIG_ALREADY_PROVIDED}" = "true" ]; then
    log_info "Rerun detected - deploying candidate release..."
    docker compose --env-file .env.candidate pull
    docker compose --env-file .env.candidate up -d
else
    log_info "Fresh install - deploying approved release..."
    docker compose pull
    docker compose up -d
fi
cd - > /dev/null

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
    # Clean up candidate env on failure (rerun only)
    if [ "${CONFIG_ALREADY_PROVIDED}" = "true" ]; then
        rm -f /opt/laymatched/.env.candidate
    fi
    log_error "Health check timeout reached after $MAX_WAIT seconds. LayMatched Web is not responding. Check container logs with: docker logs -f laymatched-web"
fi

# -- Post-health persistence (rerun only) -----------------------------------
if [ "${CONFIG_ALREADY_PROVIDED}" = "true" ]; then
    log_info "Rerun successful - persisting candidate configuration..."

    # Persist version if it changed
    if [ -n "${ORIGINAL_APP_VERSION:-}" ] && [ "$APP_VERSION" != "$ORIGINAL_APP_VERSION" ]; then
        log_info "Persisting updated version $APP_VERSION to /opt/laymatched/.env..."
        sed -i "s/^APP_VERSION=.*/APP_VERSION=${APP_VERSION}/" /opt/laymatched/.env
        log_info "Version updated in configuration."
    fi

    # Persist registry URL if it changed (or is missing - legacy migration)
    if [ -z "${ORIGINAL_REGISTRY_URL:-}" ] || [ "${CANDIDATE_REGISTRY_URL}" != "${ORIGINAL_REGISTRY_URL}" ]; then
        log_info "Persisting registry URL ${CANDIDATE_REGISTRY_URL} to /opt/laymatched/.env..."
        if grep -q '^REGISTRY_URL=' /opt/laymatched/.env; then
            sed -i "s|^REGISTRY_URL=.*|REGISTRY_URL=${CANDIDATE_REGISTRY_URL}|" /opt/laymatched/.env
        else
            echo "REGISTRY_URL=${CANDIDATE_REGISTRY_URL}" >> /opt/laymatched/.env
        fi
        log_info "Registry URL updated in configuration."
    fi

    # Regenerate docker-compose.yml with updated configuration (uses persistent .env)
    cd /opt/laymatched
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
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U laymatched -d laymatched_betting"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
    networks:
      - laymatched_net

  api:
    image: ${REGISTRY_URL}/laymatched-api:${APP_VERSION}
    container_name: laymatched-api
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    volumes:
      - bookmaker_icon_cache:/var/lib/laymatchedbetting/bookmaker-icons
    environment:
      - DATABASE_URL=postgresql+psycopg://laymatched:${POSTGRES_PASSWORD}@db:5432/laymatched_betting
      - AUTH_USERNAME=${AUTH_USERNAME}
      - AUTH_PASSWORD_HASH=${AUTH_PASSWORD_HASH}
      - AUTH_SESSION_SECRET=${AUTH_SESSION_SECRET}
      - AUTH_SESSION_HOURS=${AUTH_SESSION_HOURS:-24}
      - COMMUNITY_INSTALLATION_KEY=${COMMUNITY_INSTALLATION_KEY}
      - COMMUNITY_ATTRIBUTION_SECRET=${COMMUNITY_ATTRIBUTION_SECRET}
    healthcheck:
      test: ["CMD", "python3", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=5)"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    networks:
      - laymatched_net

  web:
    image: ${REGISTRY_URL}/laymatched-web:${APP_VERSION}
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
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1/app/"]
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

    # Clean up candidate env file
    rm -f .env.candidate
    cd - > /dev/null

    log_info "docker-compose.yml regenerated with updated version and registry."
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

Ports configured:
  - HTTP (80)      Public via Nginx reverse proxy - Web frontend (external access)
  - HTTP (8080)    Bound to 127.0.0.1 only - Web frontend (internal, proxied by Nginx)

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
  - sudo ./update.sh

================================================================================
INSTALL_EOF

log_info "LayMatched installer finished successfully."
