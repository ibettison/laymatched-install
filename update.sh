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
    /usr/bin/python3 /opt/laymatched/provisioning-current/recognition_client.py heartbeat \
    --state-dir "$STATE_DIR" --central-url "$central_url" \
    --app-version "$app_version" --service-status "$service_status"
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
    exec /usr/bin/python3 /opt/laymatched/provisioning-current/recognition_client.py report-https \\
        --state-dir /var/lib/laymatched/activation --central-url "\$central_url" \\
        --app-version "\$app_version" --hostname "$customer_hostname" \\
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
if ! docker compose --env-file .env.candidate -f "$CANDIDATE_COMPOSE_FILE" pull; then
    handle_candidate_failure "candidate_pull_failed"
    log_error "Candidate image pull failed. Candidate artifacts were retained; automatic rollback was not attempted. Review $RECOVERY_STATE_FILE before recovery."
fi

# -- Phase 5: Restart services with candidate version ----------------------

log_info "Phase 5: Restarting services with candidate release..."

CANDIDATE_RESTART_ATTEMPTED=1
if ! docker compose --env-file .env.candidate -f "$CANDIDATE_COMPOSE_FILE" up -d; then
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
