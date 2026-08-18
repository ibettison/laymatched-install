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

# -- Phase 1: Git pull (installer updates) -------------------------------

log_info "Phase 1: Pulling latest installer updates..."

cd /opt/laymatched
git pull

# -- Phase 2: Pull latest LayMatched image -------------------------------

log_info "Phase 2: Pulling latest LayMatched release (${APP_VERSION})..."

docker compose -f /opt/laymatched/docker-compose.yml pull

# -- Phase 3: Restart services ------------------------------------------

log_info "Phase 3: Restarting services..."

docker compose -f /opt/laymatched/docker-compose.yml up -d

# -- Phase 4: Health checks ---------------------------------------------

log_info "Phase 4: Running health checks..."

MAX_WAIT=120
ELAPSED=0
APP_NAME="laymatched"

while [ $ELAPSED -lt $MAX_WAIT ]; do
    if docker inspect -f '{{.HealthStatus}' "${APP_NAME}" | grep -q "healthy"; then
        log_info "${APP_NAME} is healthy."
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

# -- Phase 5: Status ----------------------------------------------------

cat <<'UPDATE_EOF'

================================================================================
LAYMATCHED UPDATE COMPLETE
================================================================================

Updated to version: ${APP_VERSION}

  - Puller latest image: docker compose -f /opt/laymatched/docker-compose.yml pull
  - Restarted services: docker compose -f /opt/laymatched/docker-compose.yml up -d

Logs and status:
  - View logs:       docker logs -f laymatched
  - Container status: docker ps
  - Health status:   docker inspect --format='{{.HealthStatus}' laymatched

Configuration preserved:
  - /opt/laymatched/.env    - GHCR token and version
  - /opt/laymatched/data    - persistent application data (Docker volume)

================================================================================
UPDATE_EOF

log_info "LayMatched update finished successfully."