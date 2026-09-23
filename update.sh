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

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/release_identity.sh"

ACTIVATION_SERVICE_URL="${ACTIVATION_SERVICE_URL:-}"

install_recognition_scheduler() {
    local config_file="/etc/laymatched/recognition.env"
    local existing_url=""
    local central_url="${ACTIVATION_SERVICE_URL:-}"

    if [ -f "$config_file" ]; then
        if [ "$(grep -c '^ACTIVATION_SERVICE_URL=' "$config_file" || true)" -gt 1 ]; then
            log_error "Central recognition configuration is duplicated."
        fi
        existing_url=$(sed -n 's/^ACTIVATION_SERVICE_URL=//p' "$config_file")
    fi
    if [ -z "$central_url" ]; then
        central_url="$existing_url"
    fi
    if [ -z "$central_url" ]; then
        log_info "Central recognition scheduler not configured; local operation remains unchanged."
        return 0
    fi
    case "$central_url" in
        http://*|https://*) ;;
        *) log_error "Central recognition URL must use http:// or https://." ;;
    esac
    if printf '%s' "$central_url" | grep -q '[[:space:]]'; then
        log_error "Central recognition URL contains whitespace."
    fi

    install -d -o root -g root -m 0700 /etc/laymatched
    local config_tmp
    config_tmp=$(mktemp /etc/laymatched/.recognition.env.XXXXXX)
    chmod 600 "$config_tmp"
    printf 'ACTIVATION_SERVICE_URL=%s\n' "$central_url" > "$config_tmp"
    mv -f "$config_tmp" "$config_file"
    chmod 600 "$config_file"

    cat > /opt/laymatched/recognition-heartbeat.sh <<'HEARTBEAT_RUNNER_EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/laymatched/recognition.env"
APP_ENV_FILE="/opt/laymatched/.env"
STATE_DIR="/var/lib/laymatched/activation"

central_url=$(sed -n 's/^ACTIVATION_SERVICE_URL=//p' "$CONFIG_FILE")
app_version=$(sed -n 's/^APP_VERSION=//p' "$APP_ENV_FILE")
if [ -z "$central_url" ] || [ -z "$app_version" ]; then
    echo "recognition heartbeat configuration is incomplete" >&2
    exit 1
fi
case "$central_url" in
    http://*|https://*) ;;
    *) echo "recognition heartbeat URL is invalid" >&2; exit 1 ;;
esac
if printf '%s' "$central_url" | grep -q '[[:space:]]'; then
    echo "recognition heartbeat URL is invalid" >&2
    exit 1
fi

api_status=$(docker inspect -f '{{.State.Health.Status}}' laymatched-api 2>/dev/null || true)
web_status=$(docker inspect -f '{{.State.Health.Status}}' laymatched-web 2>/dev/null || true)
service_status=unknown
if [ "$api_status" = "healthy" ] && [ "$web_status" = "healthy" ]; then
    service_status=healthy
elif [ -n "$api_status" ] || [ -n "$web_status" ]; then
    service_status=degraded
fi

exec /usr/bin/flock -n -E 76 /run/laymatched-recognition-heartbeat.lock \
    /usr/bin/python3 /opt/laymatched/provisioning-current/recognition_client.py \
    --central-url "$central_url" --state-dir "$STATE_DIR" \
    --app-version "$app_version" heartbeat \
    --service-status "$service_status"
HEARTBEAT_RUNNER_EOF
    chown root:root /opt/laymatched/recognition-heartbeat.sh
    chmod 755 /opt/laymatched/recognition-heartbeat.sh

    cat > /etc/systemd/system/laymatched-recognition-heartbeat.service <<'HEARTBEAT_SERVICE_EOF'
[Unit]
Description=LayMatched central recognition heartbeat
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
User=root
Group=root
ExecStart=/opt/laymatched/recognition-heartbeat.sh
TimeoutStartSec=75
HEARTBEAT_SERVICE_EOF

    cat > /etc/systemd/system/laymatched-recognition-heartbeat.timer <<'HEARTBEAT_TIMER_EOF'
[Unit]
Description=Run LayMatched central recognition heartbeat

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true
RandomizedDelaySec=30s
Unit=laymatched-recognition-heartbeat.service

[Install]
WantedBy=timers.target
HEARTBEAT_TIMER_EOF
    chmod 644 /etc/systemd/system/laymatched-recognition-heartbeat.service \
        /etc/systemd/system/laymatched-recognition-heartbeat.timer
    systemctl daemon-reload
    systemctl enable --now laymatched-recognition-heartbeat.timer
    log_info "Central recognition heartbeat scheduler enabled."
}

# Install the customer provisioning helpers as one atomic, self-contained bundle.
# The embedded fallback is required for legacy installations whose old updater
# never received these sidecar files. It contains no credentials or tokens.
install_provisioning_helpers() {
    local install_root="${LAYMATCHED_INSTALL_ROOT:-/opt/laymatched}"
    local stage backup name destination
    local -a names=(customer_hostname.py configure-customer-https.sh recognition_client.py)
    mkdir -p "$install_root"
    stage="$(mktemp -d "$install_root/.helpers-stage.XXXXXX")"
    backup="$(mktemp -d "$install_root/.helpers-backup.XXXXXX")"
    cleanup_helpers() { rm -rf -- "$stage" "$backup"; }
    rollback_helpers() {
        local item
        for item in "${names[@]}"; do
            destination="$install_root/$item"
            if [ -f "$backup/$item" ]; then
                install -o root -g root -m 0755 "$backup/$item" "$destination"
            else
                rm -f -- "$destination"
            fi
        done
        cleanup_helpers
    }
    if [ -f "$SCRIPT_DIR/tools/customer_hostname.py" ] && [ -f "$SCRIPT_DIR/scripts/configure-customer-https.sh" ] && [ -f "$SCRIPT_DIR/tools/recognition_client.py" ]; then
        install -D -m 0755 "$SCRIPT_DIR/tools/customer_hostname.py" "$stage/customer_hostname.py"
        install -D -m 0755 "$SCRIPT_DIR/scripts/configure-customer-https.sh" "$stage/configure-customer-https.sh"
        install -D -m 0755 "$SCRIPT_DIR/tools/recognition_client.py" "$stage/recognition_client.py"
    else
        printf '%s' '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' | base64 -d | tar -xzf - -C "$stage" --strip-components=1
    fi
    for name in "${names[@]}"; do
        [ -s "$stage/$name" ] || { rollback_helpers; return 1; }
        destination="$install_root/$name"
        if [ -f "$destination" ]; then
            cp --preserve=mode,ownership "$destination" "$backup/$name"
        fi
    done
    # Publish the complete bundle behind one atomic pointer. Consumers use
    # provisioning-current, so they never observe a mixture of generations
    # when an update is interrupted or the host stops between writes.
    local bundle_root="$install_root/.provisioning-helper-bundles"
    local release
    release="$bundle_root/release-$(date +%s)-$$"
    local bundle_link_tmp="$bundle_root/.current.$$"
    local install_link_tmp="$install_root/.provisioning-current.$$"
    install -d -o root -g root -m 0755 "$bundle_root"
    mv -- "$stage" "$release"
    stage=""
    ln -s -- "$release" "$bundle_link_tmp"
    mv -Tf -- "$bundle_link_tmp" "$bundle_root/current"
    ln -s -- "$bundle_root/current" "$install_link_tmp"
    mv -Tf -- "$install_link_tmp" "$install_root/provisioning-current"
    cleanup_helpers
}

install_existing_https_renewal_hook() {
    local customer_hostname="$1"
    local hook="/etc/letsencrypt/renewal-hooks/deploy/laymatched-https-report.sh"
    [ -f "/etc/letsencrypt/live/$customer_hostname/cert.pem" ] || return 0
    install -d -o root -g root -m 0755 "$(dirname "$hook")"
    umask 077
    cat > "$hook" <<HOOK
#!/usr/bin/env bash
set -euo pipefail
nginx -t && systemctl reload nginx
central_url="\$(sed -n 's/^ACTIVATION_SERVICE_URL=//p' /etc/laymatched/recognition.env 2>/dev/null || true)"
app_version="\$(sed -n 's/^APP_VERSION=//p' /opt/laymatched/.env 2>/dev/null || true)"
if [ -n "\$central_url" ] && [ -n "\$app_version" ] && [ -x /opt/laymatched/provisioning-current/recognition_client.py ]; then
    exec /usr/bin/python3 /opt/laymatched/provisioning-current/recognition_client.py \\
        --central-url "\$central_url" --state-dir /var/lib/laymatched/activation \\
        --app-version "\$app_version" report-https \\
        --hostname "$customer_hostname" \\
        --certificate /etc/letsencrypt/live/$customer_hostname/cert.pem \\
        --challenge-root /var/www/letsencrypt
fi
HOOK
    chmod 0755 "$hook"
}

CANDIDATE_ENV_FILE=""
CANDIDATE_COMPOSE_FILE=""
CANDIDATE_RESTART_ATTEMPTED=0
PERSISTENT_COMPOSE_FILE="/opt/laymatched/docker-compose.yml"
RECOVERY_STATE_FILE="/opt/laymatched/.update-recovery"
PRESERVE_RECOVERY_ARTIFACTS=0
RECOVERY_REASON=""

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
for index, line in enumerate(lines):
    line = line.replace(
        "image: ${REGISTRY_URL}/laymatched-api:${APP_VERSION}",
        "image: ${API_IMAGE_REF:-${REGISTRY_URL}/laymatched-api:${APP_VERSION}}",
    )
    line = line.replace(
        "image: ${REGISTRY_URL}/laymatched-web:${APP_VERSION}",
        "image: ${WEB_IMAGE_REF:-${REGISTRY_URL}/laymatched-web:${APP_VERSION}}",
    )
    lines[index] = line

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

write_recovery_state() {
    if [ -z "${CANDIDATE_ENV_FILE:-}" ] || [ -z "${CANDIDATE_COMPOSE_FILE:-}" ]; then
        return 0
    fi
    if [ ! -f "$CANDIDATE_ENV_FILE" ] && [ ! -f "$CANDIDATE_COMPOSE_FILE" ]; then
        return 0
    fi
    cat > "$RECOVERY_STATE_FILE" <<EOF
status=manual_recovery_required
reason=${RECOVERY_REASON:-candidate_deployment_failed}
previous_compose=${PERSISTENT_COMPOSE_FILE}
candidate_env=${CANDIDATE_ENV_FILE}
candidate_compose=${CANDIDATE_COMPOSE_FILE}
old_version=${CURRENT_APP_VERSION:-unknown}
candidate_version=${CANDIDATE_VERSION:-unknown}
database_rollback=not_attempted
automatic_container_restore=not_safe_without_migration_policy_and_snapshot
next_action=review_database_migration_state_and_pre_update_snapshot_before_restarting_any_previous_application_image
EOF
    chmod 600 "$RECOVERY_STATE_FILE"
}

handle_candidate_failure() {
    local reason="$1"
    PRESERVE_RECOVERY_ARTIFACTS=1
    RECOVERY_REASON="$reason"
    if [ "${CANDIDATE_RESTART_ATTEMPTED:-0}" = 1 ] \
        && [ -f "${CANDIDATE_ENV_FILE:-}" ] \
        && [ -f "${CANDIDATE_COMPOSE_FILE:-}" ]; then
        # A pull failure has not started a candidate and must not stop the
        # existing installation. After a restart attempt, stop only the
        # application services that may be candidate containers; leave the
        # database service and volume available for diagnosis/recovery.
        docker compose --env-file "$CANDIDATE_ENV_FILE" -f "$CANDIDATE_COMPOSE_FILE" \
            stop api web >/dev/null 2>&1 || true
    fi
    write_recovery_state
}

# BEGIN EPHEMERAL DOCKER AUTH
# Keep registry credentials out of the customer's normal/root Docker
# credential store. This is intentionally self-contained for older installs
# whose copied update.sh predates the helper changes.
EPHEMERAL_DOCKER_CONFIG_DIR=""

cleanup_ephemeral_docker_auth() {
    if [ "${PRESERVE_RECOVERY_ARTIFACTS:-0}" = 1 ]; then
        write_recovery_state
    else
        if [ -n "${CANDIDATE_ENV_FILE:-}" ]; then
            rm -f -- "$CANDIDATE_ENV_FILE" || true
            CANDIDATE_ENV_FILE=""
        fi
        if [ -n "${CANDIDATE_COMPOSE_FILE:-}" ]; then
            rm -f -- "$CANDIDATE_COMPOSE_FILE" || true
            CANDIDATE_COMPOSE_FILE=""
        fi
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

AUTH_RESPONSE_DIR=""

cleanup_auth_response() {
    local response_dir="${AUTH_RESPONSE_DIR:-}"
    if [ -z "$response_dir" ]; then
        return 0
    fi
    case "$response_dir" in
        /tmp/laymatched-auth-response.*) rm -rf -- "$response_dir" || true ;;
    esac
    AUTH_RESPONSE_DIR=""
}

auth_response_signal_exit() {
    local exit_code="$1"
    cleanup_auth_response
    trap - EXIT HUP INT TERM
    exit "$exit_code"
}

call_auth_api() {
    local installer_token="$1"
    API_IMAGE_REF=""
    WEB_IMAGE_REF=""
    RELEASE_SOURCE_SHA=""
    log_info "Contacting LayMatched authorization service..."

    # Build JSON safely using python3 to avoid injection issues
    local json_payload
    json_payload=$(python3 -c '
import json, sys
print(json.dumps({"installer_token": sys.argv[1]}))
' "$installer_token")

	local response response_file http_status
	AUTH_RESPONSE_DIR=$(mktemp -d /tmp/laymatched-auth-response.XXXXXX) || \
		log_error "Cannot create a temporary authorization response directory."
	trap cleanup_auth_response EXIT
	trap 'auth_response_signal_exit 129' HUP
	trap 'auth_response_signal_exit 130' INT
	trap 'auth_response_signal_exit 143' TERM
	response_file="${AUTH_RESPONSE_DIR}/response.json"
	if ! http_status=$(curl -sS -X POST \
		-H "Content-Type: application/json" \
		-d "$json_payload" \
		-o "$response_file" -w "%{http_code}" \
		"${AUTH_API_URL}" 2>/dev/null); then
		cleanup_auth_response
		log_error "Failed to contact LayMatched authorization service. Check network connectivity and try again."
	fi

	case "$http_status" in
		200)
			response=$(cat "$response_file")
			cleanup_auth_response
			trap - EXIT HUP INT TERM
			;;
		401)
			cleanup_auth_response
			log_error "Authorization service rejected the installer token (HTTP 401). Verify the token is correct, active, and not expired."
			;;
		4??|5??)
			cleanup_auth_response
			log_error "Authorization service returned HTTP ${http_status}. Try again later or contact support."
			;;
		*)
			cleanup_auth_response
			log_error "Authorization service returned an invalid HTTP status. Check network connectivity and try again."
			;;
	esac

	# Parse JSON response using python3 (available on target Ubuntu)
    REGISTRY_TOKEN=$(echo "${response}" | python3 -c "import sys, json; print(json.load(sys.stdin).get('registry_token', ''))")
    APPROVED_VERSION=$(echo "${response}" | python3 -c "import sys, json; print(json.load(sys.stdin).get('approved_version', ''))")
    REGISTRY_URL=$(echo "${response}" | python3 -c "import sys, json; print(json.load(sys.stdin).get('registry_url', ''))")
    APPROVED_SOURCE_SHA=$(echo "${response}" | python3 -c "import sys, json; print(json.load(sys.stdin).get('source_sha', ''))")
    API_IMAGE_DIGEST=$(echo "${response}" | python3 -c "import sys, json; print(json.load(sys.stdin).get('api_image_digest', ''))")
    WEB_IMAGE_DIGEST=$(echo "${response}" | python3 -c "import sys, json; print(json.load(sys.stdin).get('web_image_digest', ''))")

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
    set_approved_release_image_refs || \
        log_error "Authorization returned an incomplete or invalid approved release identity."
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

# Supported updater bundles carry the provisioning helpers alongside update.sh.
# The embedded fallback also upgrades genuinely old installations atomically.
install_provisioning_helpers || log_error "Could not install the customer provisioning helper bundle."

CUSTOMER_HOSTNAME=$(grep '^CUSTOMER_HOSTNAME=' /opt/laymatched/.env | cut -d'=' -f2- || true)
if [ -n "$CUSTOMER_HOSTNAME" ] && [ -x /opt/laymatched/provisioning-current/customer_hostname.py ]; then
    expected_hostname=$(python3 /opt/laymatched/provisioning-current/customer_hostname.py "${CUSTOMER_HOSTNAME%%.matched.laysports.co.uk}" 2>/dev/null || true)
    if [ "$expected_hostname" != "$CUSTOMER_HOSTNAME" ]; then
        log_error "Stored customer hostname is invalid; refusing to update the installation."
    fi
fi
if [ -n "$CUSTOMER_HOSTNAME" ]; then
    install_existing_https_renewal_hook "$CUSTOMER_HOSTNAME"
fi

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
APP_VERSION="$CANDIDATE_VERSION"

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
PRESERVE_RECOVERY_ARTIFACTS=1
RECOVERY_REASON="candidate_deployment_failed"
write_release_identity_env "$CANDIDATE_ENV_FILE" "$CANDIDATE_VERSION" "$CANDIDATE_REGISTRY_URL" \
    "$API_IMAGE_REF" "$WEB_IMAGE_REF" "$RELEASE_SOURCE_SHA" || \
    log_error "Could not write the complete approved release identity to the candidate environment."

# Keep the persistent Compose file unchanged until the candidate is healthy.
# Legacy files may lack the MFA API mapping, so prepare an ephemeral candidate
# file for the first restart instead of deploying from the old template.
prepare_candidate_compose docker-compose.yml "$CANDIDATE_COMPOSE_FILE"

# -- Phase 4: Pull candidate LayMatched images -----------------------------

log_info "Phase 4: Pulling candidate LayMatched release (${CANDIDATE_VERSION})..."

# Use the candidate environment and candidate Compose file for interpolation
# and the first candidate restart. The persistent Compose file is unchanged.
if ! prepare_release_compose "$CANDIDATE_ENV_FILE" "$CANDIDATE_COMPOSE_FILE"; then
    handle_candidate_failure "candidate_pull_or_identity_failed"
    log_error "Candidate pull, identity verification, or deployment failed. Review $RECOVERY_STATE_FILE before recovery."
fi

# -- Phase 5: Restart services with candidate version ----------------------

log_info "Phase 5: Restarting services with candidate release..."

CANDIDATE_RESTART_ATTEMPTED=1
if ! start_release_compose "$CANDIDATE_ENV_FILE" "$CANDIDATE_COMPOSE_FILE"; then
    handle_candidate_failure "candidate_restart_failed"
    log_error "Candidate restart failed. Candidate artifacts were retained; automatic rollback was not attempted. Review $RECOVERY_STATE_FILE before recovery."
fi
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
    handle_candidate_failure "candidate_health_check_timeout"
    log_error "Candidate health gate failed. Candidate containers were stopped; automatic rollback was not attempted because migration compatibility and a pre-update database snapshot were not available. Review $RECOVERY_STATE_FILE before restarting any previous application image."
fi

# -- Phase 8: Candidate healthy - persist new version and regenerate Compose --

log_info "Phase 8: Candidate healthy. Persisting new version and regenerating configuration..."

cd /opt/laymatched

# Persist candidate values to persistent .env
write_release_identity_env /opt/laymatched/.env "$CANDIDATE_VERSION" "$CANDIDATE_REGISTRY_URL" \
    "$API_IMAGE_REF" "$WEB_IMAGE_REF" "$RELEASE_SOURCE_SHA" || \
    log_error "Could not atomically persist the deployed approved release identity."

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
    image: ${API_IMAGE_REF:-${REGISTRY_URL}/laymatched-api:${APP_VERSION}}
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
    image: ${WEB_IMAGE_REF:-${REGISTRY_URL}/laymatched-web:${APP_VERSION}}
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

# The candidate is now healthy and the persistent Compose file has been
# regenerated for the promoted release. Recovery artifacts are no longer
# needed on the successful path.
rm -f "$RECOVERY_STATE_FILE"
PRESERVE_RECOVERY_ARTIFACTS=0

# Clean up candidate env file
rm -f .env.candidate
CANDIDATE_ENV_FILE=""
rm -f "$CANDIDATE_COMPOSE_FILE"
CANDIDATE_COMPOSE_FILE=""

cd - > /dev/null

log_info "docker-compose.yml regenerated with updated version and registry."

install_recognition_scheduler

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
  - Customer hostname       - ${CUSTOMER_HOSTNAME:-not configured}; certificates and Nginx routing were preserved

================================================================================
UPDATE_EOF

log_info "LayMatched update finished successfully."
