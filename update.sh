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

CANDIDATE_ENV_FILE=""
CANDIDATE_COMPOSE_FILE=""

ensure_mfa_encryption_key() {
    local env_file="$1"
    local helper="${MFA_KEY_HELPER:-/opt/laymatched/ensure-mfa-encryption-key.sh}"

    # New installations carry the shared helper. The inline fallback keeps
    # upgrades safe for older installations that predate that helper.
    if [ -x "$helper" ]; then
        bash "$helper" "$env_file"
        return
    fi

    [ -f "$env_file" ] || { echo "Environment file is missing." >&2; return 1; }
    if grep -Eq '^[[:space:]]*export[[:space:]]+AUTH_MFA_ENCRYPTION_KEY[[:space:]]*=' "$env_file"; then
        echo "AUTH_MFA_ENCRYPTION_KEY uses an unsupported assignment form." >&2
        return 1
    fi
    local key_lines
    local key_count=0
    key_lines="$(grep -nE '^[[:space:]]*AUTH_MFA_ENCRYPTION_KEY[[:space:]]*=' "$env_file" || true)"
    if [ -n "$key_lines" ]; then
        key_count="$(printf '%s\n' "$key_lines" | wc -l | tr -d ' ')"
    fi
    if [ "$key_count" -gt 1 ]; then
        echo "AUTH_MFA_ENCRYPTION_KEY is defined more than once." >&2
        return 1
    fi
    if [ "$key_count" -eq 1 ]; then
        local key
        key="$(printf '%s\n' "$key_lines" | sed -E 's/^[0-9]+:[[:space:]]*AUTH_MFA_ENCRYPTION_KEY[[:space:]]*=[[:space:]]*//')"
        if ! printf '%s' "$key" | grep -Eq '^[A-Za-z0-9_-]{32,}$'; then
            echo "AUTH_MFA_ENCRYPTION_KEY is malformed." >&2
            return 1
        fi
        unset key
        chmod 600 "$env_file"
        return 0
    fi
    local key
    chmod 600 "$env_file"
    umask 077
    command -v openssl >/dev/null 2>&1 || {
        echo "OpenSSL is required to generate the MFA encryption key." >&2
        return 1
    }
    key="$(openssl rand -hex 32)" || {
        echo "Could not generate MFA encryption key." >&2
        return 1
    }
    printf '\nAUTH_MFA_ENCRYPTION_KEY=%s\n' "$key" >> "$env_file"
    unset key
    chmod 600 "$env_file"
}

prepare_candidate_compose() {
    local source_file="$1"
    local destination_file="$2"

    python3 - "$source_file" "$destination_file" <<'PY'
import os
import re
import sys
import tempfile
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
lines = source.read_text().splitlines(keepends=True)

service_start = next((index for index, line in enumerate(lines) if line == "  api:\n"), None)
if service_start is None:
    raise SystemExit("Candidate Compose file has no api service.")

service_end = len(lines)
for index in range(service_start + 1, len(lines)):
    if re.match(r"^  [^ \n].*:\s*$", lines[index]):
        service_end = index
        break

api_lines = lines[service_start:service_end]
if any("AUTH_MFA_ENCRYPTION_KEY" in line for line in api_lines):
    rendered = lines
else:
    environment_index = next(
        (index for index, line in enumerate(api_lines) if line == "    environment:\n"),
        None,
    )
    if environment_index is None:
        raise SystemExit("API service has no environment block.")

    insert_at = environment_index + 1
    while insert_at < len(api_lines):
        line = api_lines[insert_at]
        if line.strip() and not line.startswith("      "):
            break
        insert_at += 1

    existing_environment_lines = [
        line for line in api_lines[environment_index + 1:insert_at] if line.strip()
    ]
    mapping_style = existing_environment_lines and not existing_environment_lines[0].lstrip().startswith("-")
    entry = (
        "      AUTH_MFA_ENCRYPTION_KEY: ${AUTH_MFA_ENCRYPTION_KEY}\n"
        if mapping_style
        else "      - AUTH_MFA_ENCRYPTION_KEY=${AUTH_MFA_ENCRYPTION_KEY}\n"
    )
    rendered = lines[: service_start + insert_at] + [entry] + lines[service_start + insert_at:]

destination.parent.mkdir(parents=True, exist_ok=True)
with tempfile.NamedTemporaryFile("w", dir=destination.parent, delete=False) as temporary:
    temporary.writelines(rendered)
    temporary_path = Path(temporary.name)
os.chmod(temporary_path, 0o600)
os.replace(temporary_path, destination)
PY
}

# BEGIN EPHEMERAL DOCKER AUTH
# Keep registry credentials out of the customer's normal/root Docker
# credential store. This is intentionally self-contained for older installs
# whose copied update.sh predates the helper changes.
EPHEMERAL_DOCKER_CONFIG_DIR=""

cleanup_ephemeral_docker_auth() {
    if [ -n "${CANDIDATE_ENV_FILE:-}" ]; then
        rm -f -- "$CANDIDATE_ENV_FILE" || true
        CANDIDATE_ENV_FILE=""
    fi
    if [ -n "${CANDIDATE_COMPOSE_FILE:-}" ]; then
        rm -f -- "$CANDIDATE_COMPOSE_FILE" || true
        CANDIDATE_COMPOSE_FILE=""
    fi
    local config_dir="${EPHEMERAL_DOCKER_CONFIG_DIR:-}"
    if [ -z "$config_dir" ]; then
        return 0
    fi
    case "$config_dir" in
        /tmp/laymatched-docker-config.*) ;;
        *)
            EPHEMERAL_DOCKER_CONFIG_DIR=""
            unset DOCKER_CONFIG
            return 0
            ;;
    esac
    rm -rf -- "$config_dir" || true
    EPHEMERAL_DOCKER_CONFIG_DIR=""
    unset DOCKER_CONFIG
}

setup_ephemeral_docker_auth() {
    EPHEMERAL_DOCKER_CONFIG_DIR="$(mktemp -d /tmp/laymatched-docker-config.XXXXXX)"
    chmod 700 "$EPHEMERAL_DOCKER_CONFIG_DIR"
    export DOCKER_CONFIG="$EPHEMERAL_DOCKER_CONFIG_DIR"
}

install_ephemeral_docker_auth_traps() {
    trap cleanup_ephemeral_docker_auth EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
}
# END EPHEMERAL DOCKER AUTH

# -- Auth API: Exchange Installer Token for registry credentials -------------
# Calls LayMatched Auth API to validate the Installer Token and obtain the
# approved version. Docker exchanges that token for a short-lived registry JWT.
# Sets: REGISTRY_TOKEN, APPROVED_VERSION, REGISTRY_URL

AUTH_API_URL="https://auth.matched.laysports.co.uk/installer/authorize"

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

# -- Verify we're in the right directory --------------------------------

if [ ! -f /opt/laymatched/docker-compose.yml ]; then
    log_error "Update script must be run from /opt/laymatched or after cloning the installer."
fi

if [ ! -f /opt/laymatched/.env ]; then
    log_error "Configuration file /opt/laymatched/.env not found. Run install.sh first."
fi

ensure_mfa_encryption_key /opt/laymatched/.env || \
    log_error "MFA encryption configuration is missing or invalid."

# -- Parse version override argument --------------------------------------
# Usage: update.sh [APPROVED_VERSION]
# An optional version is accepted only when it matches the version returned by
# the Auth API; customers cannot use this script to bypass release approval.

NEW_VERSION_ARG="${1:-}"

# Load current APP_VERSION from .env safely (without expanding $$ in AUTH_PASSWORD_HASH)
CURRENT_APP_VERSION=$(grep '^APP_VERSION=' /opt/laymatched/.env | cut -d'=' -f2-)
# Load REGISTRY_URL if present (legacy .env may not have it)
CURRENT_REGISTRY_URL=$(grep '^REGISTRY_URL=' /opt/laymatched/.env | cut -d'=' -f2-)

if [ -n "$NEW_VERSION_ARG" ]; then
    # Validate version argument using the same validation function
    if ! validate_version "$NEW_VERSION_ARG"; then
        log_error "Invalid version format: '$NEW_VERSION_ARG'. Use a valid release tag like 'v0.1.1'."
    fi
    APP_VERSION="$NEW_VERSION_ARG"
    log_info "Version override specified: $APP_VERSION (current: $CURRENT_APP_VERSION)"
else
    APP_VERSION="$CURRENT_APP_VERSION"
    log_info "No version override - using current: $APP_VERSION"
fi

# -- LayMatched Authorization ---------------------------------------------

log_info "Authenticating to LayMatched authorization service..."

INSTALLER_TOKEN=""
if [ -n "${INSTALLER_TOKEN:-}" ]; then
    log_info "Using Installer Token from environment."
else
    log_warn "INSTALLER_TOKEN not found in environment. Prompting for token..."
    set +o history
    read -r -p "Enter your LayMatched Installer Token: " -s INSTALLER_TOKEN
    echo
    set -o history
    if [ -z "$INSTALLER_TOKEN" ]; then
        log_error "LayMatched Installer Token is required to pull private images."
    fi
fi

# Call Auth API to get registry credentials and approved version
call_auth_api "$INSTALLER_TOKEN"

# Determine candidate version. Any requested override must still be explicitly
# approved by the Auth API.
if [ -n "$NEW_VERSION_ARG" ]; then
    if [ "$NEW_VERSION_ARG" != "$APPROVED_VERSION" ]; then
        log_error "Requested version is not the currently approved LayMatched release."
    fi
    CANDIDATE_VERSION="$APPROVED_VERSION"
    log_info "Requested version is approved: $CANDIDATE_VERSION (current: $CURRENT_APP_VERSION)"
else
    CANDIDATE_VERSION="${APPROVED_VERSION}"
    log_info "Using approved version from authorization service: ${CANDIDATE_VERSION}"
fi

# Candidate registry URL from Auth API
CANDIDATE_REGISTRY_URL="${REGISTRY_URL}"

# -- Phase 2: Authenticate to LayMatched Registry -------------------------

log_info "Authenticating to LayMatched Container Registry..."

# Use the validated Installer Token in an ephemeral Docker credential store.
# The registry exchanges it for a short-lived JWT during the image pull.
install_ephemeral_docker_auth_traps
setup_ephemeral_docker_auth
if ! echo "${REGISTRY_TOKEN}" | docker login "${REGISTRY_URL}" -u laymatched-installer --password-stdin > /dev/null 2>&1; then
    log_error "Failed to authenticate to LayMatched Container Registry. Please verify your Installer Token is valid."
fi

log_info "Authentication to LayMatched Registry complete."

# -- Phase 3: Create temporary .env with candidate version/registry --------
# This ensures docker compose pull/up uses the candidate release for deployment

log_info "Phase 3: Preparing candidate deployment environment..."

# Create candidate .env by copying persistent .env and updating candidate values
cd /opt/laymatched
cp .env .env.candidate
CANDIDATE_ENV_FILE="/opt/laymatched/.env.candidate"
CANDIDATE_COMPOSE_FILE="/opt/laymatched/docker-compose.candidate.yml"
# Update candidate APP_VERSION
sed -i "s/^APP_VERSION=.*/APP_VERSION=${CANDIDATE_VERSION}/" .env.candidate
# Handle REGISTRY_URL: replace if exists, append if missing (legacy .env migration)
if grep -q '^REGISTRY_URL=' .env.candidate; then
    sed -i "s|^REGISTRY_URL=.*|REGISTRY_URL=${CANDIDATE_REGISTRY_URL}|" .env.candidate
else
    echo "REGISTRY_URL=${CANDIDATE_REGISTRY_URL}" >> .env.candidate
fi

# Keep the persistent Compose file unchanged until the candidate is healthy.
# Legacy files may lack the MFA API mapping, so prepare an ephemeral candidate
# file for the first restart instead of deploying from the old template.
prepare_candidate_compose docker-compose.yml "$CANDIDATE_COMPOSE_FILE"

# -- Phase 4: Pull candidate LayMatched images -----------------------------

log_info "Phase 4: Pulling candidate LayMatched release (${CANDIDATE_VERSION})..."

# Use the candidate environment and candidate Compose file for interpolation
# and the first candidate restart. The persistent Compose file is unchanged.
docker compose --env-file .env.candidate -f "$CANDIDATE_COMPOSE_FILE" pull

# -- Phase 5: Restart services with candidate version ----------------------

log_info "Phase 5: Restarting services with candidate release..."

docker compose --env-file .env.candidate -f "$CANDIDATE_COMPOSE_FILE" up -d
cd - > /dev/null

# -- Phase 6: Health checks ----------------------------------------------

log_info "Phase 6: Running health checks on candidate release..."

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

# -- Phase 7: Status - fail clearly if unhealthy -------------------------

if [ $ELAPSED -ge $MAX_WAIT ]; then
    # Clean up candidate env on failure
    rm -f /opt/laymatched/.env.candidate
    rm -f /opt/laymatched/docker-compose.candidate.yml
    CANDIDATE_ENV_FILE=""
    CANDIDATE_COMPOSE_FILE=""
    log_error "Health check timeout reached after $MAX_WAIT seconds. ${APP_NAME} is not responding. Update failed. Check container logs with: docker logs -f ${APP_NAME}"
fi

# -- Phase 8: Candidate healthy - persist new version and regenerate Compose --

log_info "Phase 8: Candidate healthy. Persisting new version and regenerating configuration..."

cd /opt/laymatched

# Persist candidate values to persistent .env
if [ "$CANDIDATE_VERSION" != "$CURRENT_APP_VERSION" ]; then
    log_info "Persisting new version $CANDIDATE_VERSION to /opt/laymatched/.env..."
    sed -i "s/^APP_VERSION=.*/APP_VERSION=${CANDIDATE_VERSION}/" .env
    log_info "Version updated in configuration."
fi

CURRENT_REGISTRY_URL=$(grep '^REGISTRY_URL=' /opt/laymatched/.env | cut -d'=' -f2-)
# Persist registry URL if it changed (or is missing - legacy migration)
if [ -z "${CURRENT_REGISTRY_URL:-}" ] || [ "$CANDIDATE_REGISTRY_URL" != "$CURRENT_REGISTRY_URL" ]; then
    log_info "Persisting registry URL ${CANDIDATE_REGISTRY_URL} to /opt/laymatched/.env..."
    if grep -q '^REGISTRY_URL=' .env; then
        sed -i "s|^REGISTRY_URL=.*|REGISTRY_URL=${CANDIDATE_REGISTRY_URL}|" .env
    else
        echo "REGISTRY_URL=${CANDIDATE_REGISTRY_URL}" >> .env
    fi
fi

# Regenerate docker-compose.yml with updated configuration (uses persistent .env)
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
      - AUTH_MFA_ENCRYPTION_KEY=${AUTH_MFA_ENCRYPTION_KEY}
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
CANDIDATE_ENV_FILE=""
rm -f "$CANDIDATE_COMPOSE_FILE"
CANDIDATE_COMPOSE_FILE=""

cd - > /dev/null

log_info "docker-compose.yml regenerated with updated version and registry."

# -- Phase 9: Status ----------------------------------------------------

cat <<UPDATE_EOF

================================================================================
LAYMATCHED UPDATE COMPLETE
================================================================================

Updated to version: ${CANDIDATE_VERSION}

  - Pulled candidate image: docker compose --env-file .env.candidate pull
  - Restarted services: docker compose --env-file .env.candidate up -d
  - Health checks passed on candidate release
  - Persisted version and regenerated docker-compose.yml

Logs and status:
  - View logs:       docker logs -f laymatched-web
  - Container status: docker ps
  - Health status:   docker inspect --format='{{.State.Health.Status}}' laymatched-web

Configuration preserved:
  - /opt/laymatched/.env    - generated secrets, version, and APP_VERSION (Installer Token not stored)
  - /opt/laymatched/data    - persistent application data (Docker volumes: postgres_data, bookmaker_icon_cache)

================================================================================
UPDATE_EOF

log_info "LayMatched update finished successfully."
