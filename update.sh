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
