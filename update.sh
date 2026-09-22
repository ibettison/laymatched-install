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
