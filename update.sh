#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# LayMatched Update Script - Issue #1
# Update LayMatched installation to newer version.
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

# -- Verify we're in the right directory --------------------------------

if [ ! -f /opt/laymatched/docker-compose.yml ]; then
    log_error "Update script must be run from /opt/laymatched or after cloning the installer."
fi

if [ ! -f /opt/laymatched/.env ]; then
    log_error "Configuration file /opt/laymatched/.env not found. Run install.sh first."
fi

# Load environment config (read-only, never export secrets)
set -a
source /opt/laymatched/.env
set +a

# -- GHCR Authentication -------------------------------------------------

log_info "Authenticating to GitHub Container Registry..."

GHCR_TOKEN=""
if [ -n "${GHCR_TOKEN:-}" ]; then
    log_info "Using GHCR token from environment."
else
    log_warn "GHCR_TOKEN not found in environment. Prompting for token..."
    set +o history
    read -r -p "Enter your GitHub Container Registry (GHCR) authentication token: " -s GHCR_TOKEN
    echo
    set -o history
    if [ -z "$GHCR_TOKEN" ]; then
        log_error "GHCR token is required to pull private images."
    fi
fi

# Authenticate to GHCR (failure stops update - do not hide with || true)
if ! echo "${GHCR_TOKEN}" | docker login ghcr.io -u ibettison --password-stdin > /dev/null 2>&1; then
    log_error "Failed to authenticate to GitHub Container Registry. Please verify your GHCR token is valid."
fi

log_info "Authentication to GHCR complete."

# -- Phase 2: Pull latest LayMatched images ------------------------------

log_info "Phase 2: Pulling latest LayMatched release (${APP_VERSION})..."

docker compose -f /opt/laymatched/docker-compose.yml pull

# -- Phase 3: Restart services -------------------------------------------

log_info "Phase 3: Restarting services..."

docker compose -f /opt/laymatched/docker-compose.yml up -d

# -- Phase 4: Health checks ----------------------------------------------

log_info "Phase 4: Running health checks..."

MAX_WAIT=120
ELAPSED=0
APP_NAME="laymatched-web"

while [ $ELAPSED -lt $MAX_WAIT ]; do
    STATUS=$(docker inspect -f '{{.State.Health.Status}}' "${APP_NAME}" 2>/dev/null)
    if [ "$STATUS" = "healthy" ]; then
        log_info "${APP_NAME} is healthy."
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [ $ELAPSED -lt $MAX_WAIT ]; then
        echo -n "."
    fi
done

# -- Phase 5: Status - fail clearly if unhealthy -------------------------

if [ $ELAPSED -ge $MAX_WAIT ]; then
    log_error "Health check timeout reached after $MAX_WAIT seconds. ${APP_NAME} is not responding. Update failed. Check container logs with: docker logs -f ${APP_NAME}"
fi

# -- Phase 5: Status ----------------------------------------------------

cat <<UPDATE_EOF

================================================================================
LAYMATCHED UPDATE COMPLETE
================================================================================

Updated to version: ${APP_VERSION}

  - Pulled latest image: docker compose -f /opt/laymatched/docker-compose.yml pull
  - Restarted services: docker compose -f /opt/laymatched/docker-compose.yml up -d

Logs and status:
  - View logs:       docker logs -f laymatched-web
  - Container status: docker ps
  - Health status:   docker inspect --format='{{.State.Health.Status}}' laymatched-web

Configuration preserved:
  - /opt/laymatched/.env    - generated secrets, version, and APP_VERSION (GHCR_TOKEN not stored)
  - /opt/laymatched/data    - persistent application data (Docker volumes: postgres_data, bookmaker_icon_cache)

================================================================================
UPDATE_EOF

log_info "LayMatched update finished successfully."