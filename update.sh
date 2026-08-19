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

# -- Parse version override argument --------------------------------------
# Usage: update.sh [NEW_VERSION]
# If NEW_VERSION is provided, use it for this update and persist on success.
# If not provided, use current APP_VERSION from .env.

NEW_VERSION_ARG="${1:-}"

# Load current APP_VERSION from .env safely (without expanding $$ in AUTH_PASSWORD_HASH)
CURRENT_APP_VERSION=$(grep '^APP_VERSION=' /opt/laymatched/.env | cut -d'=' -f2-)

if [ -n "$NEW_VERSION_ARG" ]; then
    # Validate version argument: non-empty, reasonable format
    if [ -z "$NEW_VERSION_ARG" ]; then
        log_error "Version argument provided but empty."
    fi
    # Basic sanity: version should not contain spaces or shell metacharacters
    case "$NEW_VERSION_ARG" in
        *[[:space:]]*|*[\$\`\;]*)
            log_error "Invalid version format: '$NEW_VERSION_ARG'. Use a valid tag like 'v0.1.1' or 'latest'."
            ;;
    esac
    APP_VERSION="$NEW_VERSION_ARG"
    log_info "Version override specified: $APP_VERSION (current: $CURRENT_APP_VERSION)"
else
    APP_VERSION="$CURRENT_APP_VERSION"
    log_info "No version override - using current: $APP_VERSION"
fi

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

log_info "Phase 2: Pulling LayMatched release (${APP_VERSION})..."

# Run docker compose from /opt/laymatched so it loads the .env file
cd /opt/laymatched
docker compose pull

# -- Phase 3: Restart services -------------------------------------------

log_info "Phase 3: Restarting services..."

docker compose up -d
cd - > /dev/null

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

# -- Phase 6: Persist new version if override was used and update succeeded --

if [ -n "$NEW_VERSION_ARG" ] && [ "$APP_VERSION" != "$CURRENT_APP_VERSION" ]; then
    log_info "Persisting new version $APP_VERSION to /opt/laymatched/.env..."
    # Use sed to replace only the APP_VERSION line, preserving all other secrets
    sed -i "s/^APP_VERSION=.*/APP_VERSION=${APP_VERSION}/" /opt/laymatched/.env
    log_info "Version updated in configuration."
fi

# -- Phase 7: Status ----------------------------------------------------

cat <<UPDATE_EOF

================================================================================
LAYMATCHED UPDATE COMPLETE
================================================================================

Updated to version: ${APP_VERSION}

  - Pulled latest image: docker compose pull
  - Restarted services: docker compose up -d

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