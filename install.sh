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
        echo "$ID$VERSION_ID"
    else
        log_error "Cannot detect Ubuntu release."
    fi
}

is_supported_release() {
    local release
    release=$(detect_ubuntu_release)
    case "$release" in
        20.04|22.04|24.04) return 0 ;;
        *) return 1 ;;
    esac
}

# -- Phase 1: Prerequisites & Ubuntu validation ----------------------------

log_info "Phase 1: Validating Ubuntu server..."

if ! [ -x "$(command -v lsb_release)" ] && ! [ -f /etc/os-release ]; then
    log_error "This installer requires a supported Ubuntu server."
fi

UBUNTU_RELEASE=$(detect_ubuntu_release)
if ! is_supported_release; then
    log_error "Ubuntu $UBUNTU_RELEASE is not a supported release. Supported: 20.04, 22.04, 24.04"
fi

log_info "Detected Ubuntu $UBUNTU_RELEASE - proceeding with installation."

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
    # Load the existing config
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

    # Store configuration outside the repo in /opt/laymatched
    # This file is not tracked by git and contains sensitive credentials
    cat > /opt/laymatched/.env <<EOF
GHCR_TOKEN=${GHCR_TOKEN}
APP_VERSION=${APP_VERSION}
EOF
    chmod 600 /opt/laymatched/.env
    chown root:root /opt/laymatched/.env

    log_info "Configuration stored in /opt/laymatched/.env (permissions 600)."
else
    log_info "Using existing configuration from /opt/laymatched/.env."
fi

# -- Phase 5: Authenticate to GHCR ----------------------------------------

log_info "Phase 5: Authenticating to GitHub Container Registry..."

echo "${GHCR_TOKEN}" | docker login ghcr.io -u ibettison --password-stdin > /dev/null 2>&1 || true

log_info "Authentication to GHCR complete."

# -- Phase 6: Create docker-compose.yml -----------------------------------

log_info "Phase 6: Generating docker-compose.yml..."

cat > /opt/laymatched/docker-compose.yml <<'COMPOSE_EOF'
services:
  laymatched:
    image: ghcr.io/ibettison/laymatched:${APP_VERSION}
    container_name: laymatched
    restart: unless-stopped
    volumes:
      - laymatched_data:/var/lib/laymatched
    environment:
      - GHCR_TOKEN=${GHCR_TOKEN}
    ports:
      - "127.0.0.1:8080:8080"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
volumes:
  laymatched_data:
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

while [ $ELAPSED -lt $MAX_WAIT ]; do
    if docker inspect -f '{{.HealthStatus}' laymatched | grep -q "healthy"; then
        log_info "LayMatched is healthy."
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [ $ELAPSED -lt $MAX_WAIT ]; then
        echo -n "."
    fi
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
    log_warn "Health check timeout reached, but services may still be starting."
fi

# -- Phase 9: Status/instructions ----------------------------------------

cat <<'INSTALL_EOF'

================================================================================
LAYMATCHED INSTALLATION COMPLETE
================================================================================

Installation summary:
  - Server:        Ubuntu $UBUNTU_RELEASE
  - Docker:        Installed
  - LayMatched:    Running via Docker Compose
  - Version:       ${APP_VERSION}
  - Data directory: /opt/laymatched
  - Container:     laymatched (restart: unless-stopped)

Ports configured:
  - HTTP (8080)    Bound to 127.0.0.1 only (private)

Configuration:
  - /opt/laymatched/.env   - GHCR token and version (permissions 600)
  - /opt/laymatched/config - customer configuration (add as needed)

Logs and status:
  - View logs:       docker logs -f laymatched
  - Container status: docker ps
  - Health status:   docker inspect --format='{{.HealthStatus}' laymatched

Update instructions:
  - cd /opt/laymatched
  - git pull
  - sudo ./update.sh

================================================================================
INSTALL_EOF

log_info "LayMatched installer finished successfully."