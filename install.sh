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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/tools/release_identity.sh"
ACTIVATION_STATE_DIR="/var/lib/laymatched/activation"
LOCAL_ACTIVATION_HELPER="/opt/laymatched/local_activation.py"
INSTALLATION_ID_FILE="/etc/laymatched/installation-id"
ACTIVATION_SERVICE_URL="${ACTIVATION_SERVICE_URL:-}"
RELEASE_CANDIDATE_MANIFEST=""
if [ "$#" -gt 0 ]; then
    if [ "$#" -ne 2 ] || [ "$1" != "--release-candidate" ] || [ -z "$2" ]; then
        echo "Usage: $0 [--release-candidate manifest.json]" >&2
        exit 2
    fi
    RELEASE_CANDIDATE_MANIFEST="$2"
fi

terminal_color() { [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; }
log_info()  { if terminal_color; then printf '%b[INFO]%b %s\n' "$GREEN" "$NC" "$1"; else printf '[INFO] %s\n' "$1"; fi; }
log_warn()  { if terminal_color; then printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$1"; else printf '[WARN] %s\n' "$1"; fi; }
log_error() { if terminal_color; then printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$1"; else printf '[ERROR] %s\n' "$1"; fi; exit 1; }

MFA_SPINNER_ACTIVE=false
MFA_SPINNER_FRAME=0
INSTALLATION_ACTIVATION_VERIFIED=false
INSTALLATION_HTTPS_VERIFIED=false
RECOGNITION_SCHEDULER_ENABLED=false
cleanup_mfa_wait_ui() {
    if [ "${MFA_SPINNER_ACTIVE:-false}" = "true" ] && [ -t 1 ]; then
        printf '\r\033[2K' >&1
        MFA_SPINNER_ACTIVE=false
    fi
}

# BEGIN EPHEMERAL DOCKER AUTH
# Docker must never write the Installer Token or registry credentials to the
# customer's normal/root credential store. This block is also kept in
# update.sh so older installations can receive the same protection.
EPHEMERAL_DOCKER_CONFIG_DIR=""

cleanup_ephemeral_docker_auth() {
    cleanup_mfa_wait_ui
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

read_local_mfa_status() {
    (cd /opt/laymatched && docker compose exec -T api python3 -m app.customer_activation_status)
}

verify_customer_login_route() {
    local homepage_html
    homepage_html=$(curl --silent --fail --max-time 15 \
        --resolve "${CUSTOMER_HOSTNAME}:443:127.0.0.1" \
        "https://${CUSTOMER_HOSTNAME}/" 2>/dev/null) || \
        log_error "The approved customer application is not serving its login page at the customer root URL; activation remains pending."
    if ! printf '%s' "$homepage_html" | grep -Fq '<div id="root"></div>'; then
        log_error "The approved customer application did not return the expected login page at the customer root URL; activation remains pending."
    fi
    log_info "Customer login page verified at https://${CUSTOMER_HOSTNAME}/."
}

run_central_activation_bootstrap() {
    local activation_assertion_url recognition_status
    activation_assertion_url="${AUTH_API_URL%/installer/authorize}/activation/assertions"
    if printf '%s' "$INSTALLER_TOKEN" | python3 /opt/laymatched/provisioning-current/recognition_client.py \
        --central-url "$ACTIVATION_SERVICE_URL" --state-dir "$ACTIVATION_STATE_DIR" \
        --app-version "$APP_VERSION" bootstrap --auth-url "$activation_assertion_url"; then
        return 0
    else
        recognition_status=$?
    fi
    if [ "$recognition_status" -eq 2 ]; then
        log_error "Central recognition client invocation failed locally; central authentication was not attempted. Check installer arguments."
    fi
    log_error "Central activation could not authenticate this installation; no customer hostname was provisioned."
}

wait_for_local_mfa() {
    local wait_seconds="${ACTIVATION_MFA_WAIT_SECONDS:-900}"
    local elapsed=0
    local status_json
    local interactive=false
    local -a spinner_frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then interactive=true; fi
    printf '\n================================================================\n'
    printf '                         ONE LAST STEP\n\n'
    printf '                 Secure your LayMatched account\n\n'
    printf 'Your private LayMatched server is ready.\n\n'
    printf 'Open:\n\n  https://%s/\n\n' "$CUSTOMER_HOSTNAME"
    printf '1. Sign in\n2. Set up your Authenticator\n3. Enter the 6-digit verification code\n4. Save your recovery codes\n\n'
    printf 'Then return here.\nYou do not need to press anything.\nLayMatched will detect when you are finished.\n\n'
    printf '================================================================\n'
    while [ "$elapsed" -lt "$wait_seconds" ]; do
        status_json=$(read_local_mfa_status 2>/dev/null || true)
        if printf '%s' "$status_json" | python3 -c '
import json, sys
try:
    value = json.loads(sys.stdin.read().strip().splitlines()[-1])
except (json.JSONDecodeError, IndexError):
    raise SystemExit(1)
raise SystemExit(0 if value.get("source") == "customer_mfa_database" and value.get("enabled") and value.get("verified_at") and value.get("recovery_codes_generated") else 1)
'; then
            cleanup_mfa_wait_ui
            printf '\n                         ✓\n\n'
            printf '                    ACCOUNT SECURED\n\n'
            printf '       Authenticator protection confirmed.\n'
            printf '          Finishing your installation...\n\n'
            printf '================================================================\n\n'
            return 0
        fi
        if [ "$interactive" = "true" ]; then
            local frame=${spinner_frames[$MFA_SPINNER_FRAME]}
            MFA_SPINNER_ACTIVE=true
            printf '\r%s  Waiting for account security...' "$frame"
            MFA_SPINNER_FRAME=$(((MFA_SPINNER_FRAME + 1) % 10))
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    cleanup_mfa_wait_ui
    log_error "Verified local MFA was not completed within ${wait_seconds}s. No central activation completion was attempted."
}

complete_central_activation() {
    local status_json profile_complete
    status_json=$(python3 /opt/laymatched/provisioning-current/recognition_client.py \
        --central-url "$ACTIVATION_SERVICE_URL" --state-dir "$ACTIVATION_STATE_DIR" --app-version "$APP_VERSION" \
        status) || \
        log_error "Could not read central activation status before profile completion."
    profile_complete=$(printf '%s' "$status_json" | python3 -c 'import json,sys; print("true" if json.load(sys.stdin).get("profile", {}).get("complete") else "false")')
    if [ "$profile_complete" != "true" ]; then
        printf '\nTo finish connecting your private server to LayMatched, please complete your activation profile.\n'
        printf 'These details are sent to LayMatched for the activation record and are not added to your server configuration.\n'
        read -r -p "Full name: " CUSTOMER_FULL_NAME
        read -r -p "Town or city: " CUSTOMER_TOWN_CITY
        read -r -p "Country code (2 letters, for example GB): " CUSTOMER_COUNTRY_CODE
        CUSTOMER_COUNTRY_CODE=$(printf '%s' "$CUSTOMER_COUNTRY_CODE" | tr '[:lower:]' '[:upper:]')
        if [ -z "$CUSTOMER_FULL_NAME" ] || [ -z "$CUSTOMER_TOWN_CITY" ] || ! printf '%s' "$CUSTOMER_COUNTRY_CODE" | grep -Eq '^[A-Z]{2}$'; then
            log_error "A valid full name, town/city and two-letter country code are required."
        fi
        python3 /opt/laymatched/provisioning-current/recognition_client.py \
            --central-url "$ACTIVATION_SERVICE_URL" --state-dir "$ACTIVATION_STATE_DIR" --app-version "$APP_VERSION" \
            report-profile \
            --full-name "$CUSTOMER_FULL_NAME" --town-city "$CUSTOMER_TOWN_CITY" --country-code "$CUSTOMER_COUNTRY_CODE" >/dev/null || \
            log_error "Central customer profile reporting failed; activation remains incomplete."
    fi
    advance_activation_to profile_pending
    wait_for_local_mfa
    python3 /opt/laymatched/provisioning-current/recognition_client.py \
        --central-url "$ACTIVATION_SERVICE_URL" --state-dir "$ACTIVATION_STATE_DIR" --app-version "$APP_VERSION" \
        report-mfa \
        --compose-dir /opt/laymatched >/dev/null || \
        log_error "Central MFA status reporting failed; activation remains incomplete."
    advance_activation_to mfa_pending
    python3 /opt/laymatched/provisioning-current/recognition_client.py \
        --central-url "$ACTIVATION_SERVICE_URL" --state-dir "$ACTIVATION_STATE_DIR" --app-version "$APP_VERSION" \
        complete >/dev/null || \
        log_error "Central activation completion failed; the private application remains pending."
    advance_activation_to active
    INSTALLATION_ACTIVATION_VERIFIED=true
    log_info "Central activation completed after verified local MFA."
}

# Advance local activation monotonically. Installer retries may revisit a
# completed phase, so skip a target that the journal has already passed.
advance_activation_to() {
    local target="$1" current_stage decision
    current_stage=$(python3 "$LOCAL_ACTIVATION_HELPER" \
        --state-dir "$ACTIVATION_STATE_DIR" status | \
        python3 -c 'import json,sys; print(json.load(sys.stdin)["stage"])')
    decision=$(python3 - "$current_stage" "$target" <<'PY'
import sys
stages = ("installed", "authorized", "nickname_reserved", "dns_pending", "dns_ready", "https_pending", "profile_pending", "mfa_pending", "active")
current, target = sys.argv[1:]
if current not in stages or target not in stages:
    raise SystemExit("unknown activation stage")
print("skip" if stages.index(current) >= stages.index(target) else "advance")
PY
    )
    if [ "$decision" = "advance" ]; then
        python3 "$LOCAL_ACTIVATION_HELPER" \
            --state-dir "$ACTIVATION_STATE_DIR" advance "$target" >/dev/null
    fi
}

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
    RECOGNITION_SCHEDULER_ENABLED=true
    log_info "Central recognition heartbeat scheduler enabled."
}

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

validate_activation_url() {
    case "$1" in
        https://*) ;;
        *) return 1 ;;
    esac
    ! printf '%s' "$1" | grep -q '[[:space:]]'
}

read_release_candidate_manifest() {
    local manifest_path="$1" expected_registry="$2" values
    values=$(python3 "$SCRIPT_DIR/tools/release_candidate_manifest.py" \
        "$manifest_path" "$expected_registry") || return 1
    IFS=$'\t' read -r RELEASE_CANDIDATE_VERSION RELEASE_CANDIDATE_SOURCE_SHA \
        RELEASE_CANDIDATE_API_DIGEST RELEASE_CANDIDATE_WEB_DIGEST <<< "$values"
    API_IMAGE_REF="${REGISTRY_URL}/laymatched-api-staging@${RELEASE_CANDIDATE_API_DIGEST}"
    WEB_IMAGE_REF="${REGISTRY_URL}/laymatched-web-staging@${RELEASE_CANDIDATE_WEB_DIGEST}"
    RELEASE_SOURCE_SHA="$RELEASE_CANDIDATE_SOURCE_SHA"
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
    AUTH_ACTIVATION_SERVICE_URL=$(echo "${response}" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('activation_url') or data.get('activation_service_url') or '')")
    if [ -n "${AUTH_ACTIVATION_SERVICE_URL}" ]; then
        if ! validate_activation_url "${AUTH_ACTIVATION_SERVICE_URL}"; then
            log_error "Invalid activation service URL from authorization service."
        fi
        ACTIVATION_SERVICE_URL="${AUTH_ACTIVATION_SERVICE_URL}"
    fi

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

# Keep the MFA key helper with the installation so future reruns can validate
# the durable setting without regenerating it.
install -o root -g root -m 0755 "$SCRIPT_DIR/scripts/ensure-mfa-encryption-key.sh" \
    /opt/laymatched/ensure-mfa-encryption-key.sh

# Create the durable local installation identity once. The installer token is
# deliberately not passed to or retained by this service.
install -d -o root -g root -m 0700 /etc/laymatched "$ACTIVATION_STATE_DIR"
if [ ! -f "$INSTALLATION_ID_FILE" ]; then
    cat /proc/sys/kernel/random/uuid > "$INSTALLATION_ID_FILE"
    chmod 600 "$INSTALLATION_ID_FILE"
fi
INSTALLATION_ID=$(tr -d '\r\n' < "$INSTALLATION_ID_FILE")
python3 "$SCRIPT_DIR/tools/local_activation.py" --state-dir "$ACTIVATION_STATE_DIR" init "$INSTALLATION_ID" > /dev/null
install -o root -g root -m 0755 "$SCRIPT_DIR/tools/local_activation.py" /opt/laymatched/local_activation.py
install -o root -g root -m 0755 "$SCRIPT_DIR/tools/recognition_client.py" /opt/laymatched/recognition_client.py
install -o root -g root -m 0755 "$SCRIPT_DIR/tools/customer_hostname.py" /opt/laymatched/customer_hostname.py
install -o root -g root -m 0755 "$SCRIPT_DIR/scripts/configure-customer-https.sh" /opt/laymatched/configure-customer-https.sh
# Fresh installs use the same atomic helper pointer as upgrades. The initial
# pointer targets the install root until the updater publishes its first
# versioned helper bundle.
ln -sfn /opt/laymatched /opt/laymatched/provisioning-current
log_info "Local activation state initialized for resumable installation."

# -- Safe rerun: skip config if already provided ---------------------------

CONFIG_ALREADY_PROVIDED=false
if [ -f /opt/laymatched/.env ]; then
    log_info "Configuration already present in /opt/laymatched/.env - skipping interactive prompts."
    CONFIG_ALREADY_PROVIDED=true
    bash "$SCRIPT_DIR/scripts/ensure-mfa-encryption-key.sh" /opt/laymatched/.env || \
        log_error "MFA encryption configuration is missing or invalid."
    # Load only APP_VERSION from .env safely (without expanding $$ in AUTH_PASSWORD_HASH)
    # Use a safe parser that doesn't evaluate shell expansions
    APP_VERSION=$(grep '^APP_VERSION=' /opt/laymatched/.env | cut -d'=' -f2-)
    # Load REGISTRY_URL if present (legacy .env may not have it)
    REGISTRY_URL=$(grep '^REGISTRY_URL=' /opt/laymatched/.env | cut -d'=' -f2-)
    ACTIVATION_SERVICE_URL=$(grep '^ACTIVATION_SERVICE_URL=' /opt/laymatched/.env | cut -d'=' -f2- || true)
    CUSTOMER_NICKNAME=$(grep '^CUSTOMER_NICKNAME=' /opt/laymatched/.env | cut -d'=' -f2- || true)
    CUSTOMER_HOSTNAME=$(grep '^CUSTOMER_HOSTNAME=' /opt/laymatched/.env | cut -d'=' -f2- || true)
fi

if [ -n "$RELEASE_CANDIDATE_MANIFEST" ] && [ "$CONFIG_ALREADY_PROVIDED" = "true" ]; then
    if ! python3 "$SCRIPT_DIR/tools/release_candidate_resume.py" \
        "$RELEASE_CANDIDATE_MANIFEST" "/opt/laymatched/release-candidate.json" \
        /opt/laymatched/.env "$INSTALLATION_ID_FILE" "$ACTIVATION_STATE_DIR/state.json" \
        "$ACTIVATION_STATE_DIR/session.json"; then
        log_error "Release candidate installation requires a clean customer installation or a provable same-candidate MFA-handoff resume."
    fi
    log_info "Verified interrupted Release Candidate installation; resuming at the MFA handoff."
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
    if [ -n "$RELEASE_CANDIDATE_MANIFEST" ]; then
        if ! read_release_candidate_manifest "$RELEASE_CANDIDATE_MANIFEST" "$REGISTRY_URL"; then
            log_error "Release candidate manifest failed validation."
        fi
        APP_VERSION="$RELEASE_CANDIDATE_VERSION"
        log_info "Installing release candidate ${APP_VERSION} from source ${RELEASE_SOURCE_SHA}."
    fi
    if [ -z "${AUTH_ACTIVATION_SERVICE_URL:-}" ]; then
        log_error "Authorization service did not provide the customer activation service URL. Installation cannot provision a private hostname safely."
    fi
    ACTIVATION_SERVICE_URL="${AUTH_ACTIVATION_SERVICE_URL}"
    read -r -p "Choose your LayMatched customer nickname (3-32 lowercase letters, numbers or internal hyphens): " CUSTOMER_NICKNAME_INPUT
    CUSTOMER_NICKNAME=$(python3 "$SCRIPT_DIR/tools/customer_hostname.py" "$CUSTOMER_NICKNAME_INPUT" | sed 's/\.matched\.laysports\.co\.uk$//') || \
        log_error "Invalid customer nickname. Use 3-32 lowercase letters, numbers or internal hyphens."
    CUSTOMER_HOSTNAME="${CUSTOMER_NICKNAME}.matched.laysports.co.uk"

    # Bind the authorized installation and begin central reservation/DNS before
    # collecting local account details or installing the remaining services.
    if [ -f "$ACTIVATION_STATE_DIR/session.json" ]; then
        log_info "Resuming the existing central activation session."
    else
        current_stage=$(python3 "$LOCAL_ACTIVATION_HELPER" --state-dir "$ACTIVATION_STATE_DIR" status | \
            python3 -c 'import json,sys; print(json.load(sys.stdin)["stage"])')
        if [ "$current_stage" != "installed" ]; then
            log_error "Activation is at $current_stage but its central session is missing; refusing to create another activation."
        fi
        run_central_activation_bootstrap
    fi
    advance_activation_to authorized
    public_ipv4="${CUSTOMER_PUBLIC_IPV4:-}"
    if [ -z "$public_ipv4" ]; then
        public_ipv4=$(curl -4fsS --max-time 15 https://api.ipify.org) || \
            log_error "Unable to determine the VPS public IPv4 address. Set CUSTOMER_PUBLIC_IPV4 and rerun safely."
    fi
    while true; do
        if reservation_json=$(python3 /opt/laymatched/provisioning-current/recognition_client.py \
            --central-url "$ACTIVATION_SERVICE_URL" --state-dir "$ACTIVATION_STATE_DIR" \
            --app-version "$APP_VERSION" reserve-hostname --reserve-only \
            --nickname "$CUSTOMER_NICKNAME" --public-ip "$public_ipv4" \
            --challenge-root /var/www/letsencrypt); then
            break
        else
            reservation_status=$?
            if [ "$reservation_status" -ne 3 ]; then
                log_error "Customer hostname reservation could not be started. Retry after resolving the reported central state."
            fi
            log_warn "That nickname is already in use. Please choose another nickname."
            read -r -p "Choose another LayMatched customer nickname (3-32 lowercase letters, numbers or internal hyphens): " CUSTOMER_NICKNAME_INPUT
            CUSTOMER_NICKNAME=$(python3 "$SCRIPT_DIR/tools/customer_hostname.py" "$CUSTOMER_NICKNAME_INPUT" | sed 's/\.matched\.laysports\.co\.uk$//') || \
                log_error "Invalid customer nickname. Use 3-32 lowercase letters, numbers or internal hyphens."
            CUSTOMER_HOSTNAME="${CUSTOMER_NICKNAME}.matched.laysports.co.uk"
        fi
    done
    CUSTOMER_HOSTNAME=$(printf '%s' "$reservation_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hostname"])')
    CUSTOMER_NICKNAME=$(printf '%s' "$reservation_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["nickname"])')
    advance_activation_to nickname_reserved
    advance_activation_to dns_pending
    printf '\n%s\n' "✓ Nickname available" "✓ Your LayMatched address is being prepared" "" "  $CUSTOMER_HOSTNAME" ""
    log_info "We'll continue setting up your server while your address becomes ready."

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
API_IMAGE_REF=${API_IMAGE_REF:-}
WEB_IMAGE_REF=${WEB_IMAGE_REF:-}
RELEASE_SOURCE_SHA=${RELEASE_SOURCE_SHA:-}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
AUTH_USERNAME=${AUTH_USERNAME}
AUTH_PASSWORD_HASH=${AUTH_PASSWORD_HASH}
AUTH_SESSION_SECRET=${AUTH_SESSION_SECRET}
AUTH_SESSION_HOURS=${AUTH_SESSION_HOURS:-24}
COMMUNITY_INSTALLATION_KEY=${COMMUNITY_INSTALLATION_KEY}
COMMUNITY_ATTRIBUTION_SECRET=${COMMUNITY_ATTRIBUTION_SECRET}
ACTIVATION_SERVICE_URL=${ACTIVATION_SERVICE_URL}
CUSTOMER_NICKNAME=${CUSTOMER_NICKNAME}
CUSTOMER_HOSTNAME=
EOF
    bash "$SCRIPT_DIR/scripts/ensure-mfa-encryption-key.sh" /opt/laymatched/.env || \
        log_error "MFA encryption configuration could not be created."
    chmod 600 /opt/laymatched/.env
    chown root:root /opt/laymatched/.env

    if [ -n "$RELEASE_CANDIDATE_MANIFEST" ]; then
        install -o root -g root -m 0644 "$RELEASE_CANDIDATE_MANIFEST" /opt/laymatched/release-candidate.json
    fi

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
    if [ -n "$RELEASE_CANDIDATE_MANIFEST" ]; then
        if [ "$CANDIDATE_REGISTRY_URL" != "$ORIGINAL_REGISTRY_URL" ] || \
            ! read_release_candidate_manifest "$RELEASE_CANDIDATE_MANIFEST" "$CANDIDATE_REGISTRY_URL"; then
            log_error "Release candidate identity or registry does not match the interrupted installation."
        fi
        APP_VERSION="$RELEASE_CANDIDATE_VERSION"
    fi
    log_info "Using existing configuration from /opt/laymatched/.env. Approved version: ${APP_VERSION}"

    # -- Prepare candidate .env for rerun deployment -----------------------
    # Create candidate .env with new version/registry for Compose interpolation
    cd /opt/laymatched
    cp .env .env.candidate
    CANDIDATE_ENV_FILE="/opt/laymatched/.env.candidate"
    CANDIDATE_COMPOSE_FILE="/opt/laymatched/docker-compose.yml"
    write_release_identity_env "$CANDIDATE_ENV_FILE" "$APP_VERSION" "$CANDIDATE_REGISTRY_URL" \
        "$API_IMAGE_REF" "$WEB_IMAGE_REF" "$RELEASE_SOURCE_SHA" || \
        log_error "Could not write the complete approved release identity to the candidate environment."
    cd - > /dev/null
fi

# -- Phase 5: Authenticate to LayMatched Registry ----------------------------

log_info "Phase 5: Authenticating to LayMatched Container Registry..."

# Use ephemeral credentials; candidate pulls use the owner-read token scoped to
# the staging repositories, while normal installs use the customer token.
install_ephemeral_docker_auth_traps
setup_ephemeral_docker_auth
if [ -n "$RELEASE_CANDIDATE_MANIFEST" ]; then
    set +o history
    read -r -p "Enter the owner read-only Release Candidate pull token: " -s RELEASE_CANDIDATE_PULL_TOKEN
    echo
    set -o history
    if [ -z "$RELEASE_CANDIDATE_PULL_TOKEN" ]; then
        log_error "Owner Release Candidate pull token is required."
    fi
    if ! printf '%s' "$RELEASE_CANDIDATE_PULL_TOKEN" | docker login "${REGISTRY_URL}" \
        -u laymatched-owner --password-stdin > /dev/null 2>&1; then
        log_error "Failed to authenticate for owner-only Release Candidate image pulls."
    fi
    unset RELEASE_CANDIDATE_PULL_TOKEN
else
    if ! echo "${REGISTRY_TOKEN}" | docker login "${REGISTRY_URL}" -u laymatched-installer --password-stdin > /dev/null 2>&1; then
        log_error "Failed to authenticate to LayMatched Container Registry. Please verify your Installer Token is valid."
    fi
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
    image: ${API_IMAGE_REF:-${REGISTRY_URL}/laymatched-api:${APP_VERSION}}
    container_name: laymatched-api
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    volumes:
      - bookmaker_icon_cache:/var/lib/laymatchedbetting/bookmaker-icons
      - /var/lib/laymatched/activation/state.json:/var/lib/laymatched/activation/state.json:ro
    environment:
      - DATABASE_URL=postgresql+psycopg://laymatched:${POSTGRES_PASSWORD}@db:5432/laymatched_betting
      - AUTH_USERNAME=${AUTH_USERNAME}
      - AUTH_PASSWORD_HASH=${AUTH_PASSWORD_HASH}
      - AUTH_SESSION_SECRET=${AUTH_SESSION_SECRET}
      - AUTH_MFA_ENCRYPTION_KEY=${AUTH_MFA_ENCRYPTION_KEY}
      - AUTH_SESSION_HOURS=${AUTH_SESSION_HOURS:-24}
      - COMMUNITY_INSTALLATION_KEY=${COMMUNITY_INSTALLATION_KEY}
      - COMMUNITY_ATTRIBUTION_SECRET=${COMMUNITY_ATTRIBUTION_SECRET}
      - ACTIVATION_STATE_DIR=/var/lib/laymatched/activation
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
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1/health"]
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
        return 503 "LayMatched activation pending\n";
    }

    location /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
    }

    location /.well-known/laymatched-network/ {
        root /var/www/letsencrypt;
        default_type text/plain;
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
cp "${SCRIPT_DIR}/update.sh" /opt/laymatched/update.sh
chmod +x /opt/laymatched/update.sh
install -o root -g root -m 0644 "${SCRIPT_DIR}/tools/release_identity.sh" /opt/laymatched/release_identity.sh
log_info "update.sh copied to /opt/laymatched/"

# Complete the public-IP challenge after the challenge-only listener is live.
# Central DNS reconciliation has already started with the early reservation.
DNS_PROVISIONING_STARTED=false
if [ "${CONFIG_ALREADY_PROVIDED}" = "false" ] || [ -z "${CUSTOMER_HOSTNAME:-}" ]; then
    if [ -z "${ACTIVATION_SERVICE_URL:-}" ]; then
        log_error "Customer activation service URL is missing; refusing to expose an unowned hostname."
    fi
    if [ -z "${CUSTOMER_NICKNAME:-}" ]; then
        read -r -p "Choose your LayMatched customer nickname (3-32 lowercase letters, numbers or internal hyphens): " CUSTOMER_NICKNAME_INPUT
        CUSTOMER_NICKNAME=$(python3 /opt/laymatched/provisioning-current/customer_hostname.py "$CUSTOMER_NICKNAME_INPUT" | sed 's/\.matched\.laysports\.co\.uk$//') || \
            log_error "Invalid customer nickname. Use 3-32 lowercase letters, numbers or internal hyphens."
    fi
    CUSTOMER_HOSTNAME="${CUSTOMER_NICKNAME}.matched.laysports.co.uk"
    LAYMATCHED_INSTALLER_DIR=/opt/laymatched \
        /bin/bash /opt/laymatched/provisioning-current/configure-customer-https.sh \
        --network-only "$CUSTOMER_HOSTNAME" || \
        log_error "Could not prepare the temporary public-IP challenge listener."
    public_ipv4="${CUSTOMER_PUBLIC_IPV4:-}"
    if [ -z "$public_ipv4" ]; then
        public_ipv4=$(curl -4fsS --max-time 15 https://api.ipify.org) || \
            log_error "Unable to determine the VPS public IPv4 address. Set CUSTOMER_PUBLIC_IPV4 and rerun safely."
    fi
    if [ -f "$ACTIVATION_STATE_DIR/session.json" ]; then
        log_info "Resuming the existing central activation session."
    else
        current_stage=$(python3 "$LOCAL_ACTIVATION_HELPER" --state-dir "$ACTIVATION_STATE_DIR" status | \
            python3 -c 'import json,sys; print(json.load(sys.stdin)["stage"])')
        if [ "$current_stage" != "installed" ]; then
            log_error "Activation is at $current_stage but its central session is missing; refusing to create another activation."
        fi
        run_central_activation_bootstrap
    fi
    advance_activation_to authorized
    reservation_json=$(python3 /opt/laymatched/provisioning-current/recognition_client.py \
        --central-url "$ACTIVATION_SERVICE_URL" --state-dir "$ACTIVATION_STATE_DIR" \
        --app-version "$APP_VERSION" reserve-hostname --begin-only \
        --nickname "$CUSTOMER_NICKNAME" --public-ip "$public_ipv4" \
        --challenge-root /var/www/letsencrypt) || \
        log_error "Customer hostname reservation could not be started. Retry after resolving the reported central state."
    CUSTOMER_HOSTNAME=$(printf '%s' "$reservation_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hostname"])')
    CUSTOMER_NICKNAME=$(printf '%s' "$reservation_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["nickname"])')
    advance_activation_to nickname_reserved
    advance_activation_to dns_pending
    if grep -q '^CUSTOMER_NICKNAME=' /opt/laymatched/.env; then
        sed -i "s|^CUSTOMER_NICKNAME=.*|CUSTOMER_NICKNAME=${CUSTOMER_NICKNAME}|" /opt/laymatched/.env
    else
        printf 'CUSTOMER_NICKNAME=%s\n' "$CUSTOMER_NICKNAME" >> /opt/laymatched/.env
    fi
    if grep -q '^CUSTOMER_HOSTNAME=' /opt/laymatched/.env; then
        sed -i "s|^CUSTOMER_HOSTNAME=.*|CUSTOMER_HOSTNAME=${CUSTOMER_HOSTNAME}|" /opt/laymatched/.env
    else
        printf 'CUSTOMER_HOSTNAME=%s\n' "$CUSTOMER_HOSTNAME" >> /opt/laymatched/.env
    fi
    DNS_PROVISIONING_STARTED=true
    log_info "Central DNS provisioning is underway while LayMatched services are installed."
fi

# Certbot is not needed by the temporary HTTP challenge listener, so install
# it while central DNS reconciliation is already in progress.
if [ "${LAYMATCHED_ACME_MODE:-real}" != "mock" ] && ! command -v certbot > /dev/null 2>&1; then
    log_info "Installing Certbot for customer HTTPS and automatic renewal..."
    apt-get update
    apt-get install -y certbot
fi

# -- Phase 7: Pull and start services -------------------------------------

log_info "Phase 7: Pulling approved LayMatched release and starting services..."

# Run docker compose from /opt/laymatched
cd /opt/laymatched

# For rerun: use candidate .env with new version/registry
# For fresh install: use persistent .env (already has correct values)
if [ "${CONFIG_ALREADY_PROVIDED}" = "true" ]; then
    log_info "Rerun detected - deploying candidate release..."
    deploy_release_compose "$CANDIDATE_ENV_FILE" "$CANDIDATE_COMPOSE_FILE" || \
        log_error "Approved release pull, identity verification, or deployment failed."
else
    if [ -n "$RELEASE_CANDIDATE_MANIFEST" ]; then
        log_info "Fresh install - deploying immutable Release Candidate artifacts..."
    else
        log_info "Fresh install - deploying approved release..."
    fi
    deploy_release_compose .env docker-compose.yml || \
        log_error "Approved release pull, identity verification, or deployment failed."
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

if [ -n "${CUSTOMER_HOSTNAME:-}" ]; then
    current_stage=$(python3 "$LOCAL_ACTIVATION_HELPER" --state-dir "$ACTIVATION_STATE_DIR" status | \
        python3 -c 'import json,sys; print(json.load(sys.stdin)["stage"])')
    if [ "${DNS_PROVISIONING_STARTED:-false}" = "true" ] || [ "$current_stage" = "dns_pending" ]; then
        log_info "Waiting for central DNS verification before requesting HTTPS."
        public_ipv4="${CUSTOMER_PUBLIC_IPV4:-${public_ipv4:-}}"
        if [ -z "$public_ipv4" ]; then
            public_ipv4=$(curl -4fsS --max-time 15 https://api.ipify.org) || \
                log_error "Unable to determine the VPS public IPv4 address. Set CUSTOMER_PUBLIC_IPV4 and rerun safely."
        fi
        python3 /opt/laymatched/provisioning-current/recognition_client.py \
            --central-url "$ACTIVATION_SERVICE_URL" --state-dir "$ACTIVATION_STATE_DIR" \
            --app-version "$APP_VERSION" reserve-hostname \
            --nickname "$CUSTOMER_NICKNAME" --public-ip "$public_ipv4" \
            --challenge-root /var/www/letsencrypt \
            --wait-seconds "${ACTIVATION_DNS_WAIT_SECONDS:-300}" >/dev/null || \
            log_error "Customer DNS is not ready yet. The saved activation can be resumed safely."
        advance_activation_to dns_ready
    fi
    LAYMATCHED_INSTALLER_DIR=/opt/laymatched \
        /bin/bash /opt/laymatched/provisioning-current/configure-customer-https.sh "$CUSTOMER_HOSTNAME"
    advance_activation_to https_pending
    if [ "${LAYMATCHED_ACME_MODE:-real}" != "mock" ]; then
        python3 /opt/laymatched/provisioning-current/recognition_client.py \
            --central-url "$ACTIVATION_SERVICE_URL" --state-dir "$ACTIVATION_STATE_DIR" \
            --app-version "$APP_VERSION" report-https \
            --hostname "$CUSTOMER_HOSTNAME" \
            --certificate "/etc/letsencrypt/live/$CUSTOMER_HOSTNAME/cert.pem" \
            --challenge-root /var/www/letsencrypt >/dev/null || \
            log_error "Central HTTPS verification failed; the installation remains pending and must be retried safely."
        verify_customer_login_route
        INSTALLATION_HTTPS_VERIFIED=true
        complete_central_activation
    fi
fi

install_recognition_scheduler

# -- Post-health persistence (rerun only) -----------------------------------
if [ "${CONFIG_ALREADY_PROVIDED}" = "true" ]; then
    log_info "Rerun successful - persisting candidate configuration..."

    write_release_identity_env /opt/laymatched/.env "$APP_VERSION" "$CANDIDATE_REGISTRY_URL" \
        "$API_IMAGE_REF" "$WEB_IMAGE_REF" "$RELEASE_SOURCE_SHA" || \
        log_error "Could not atomically persist the deployed approved release identity."

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
    image: ${API_IMAGE_REF:-${REGISTRY_URL}/laymatched-api:${APP_VERSION}}
    container_name: laymatched-api
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    volumes:
      - bookmaker_icon_cache:/var/lib/laymatchedbetting/bookmaker-icons
      - /var/lib/laymatched/activation/state.json:/var/lib/laymatched/activation/state.json:ro
    environment:
      - DATABASE_URL=postgresql+psycopg://laymatched:${POSTGRES_PASSWORD}@db:5432/laymatched_betting
      - AUTH_USERNAME=${AUTH_USERNAME}
      - AUTH_PASSWORD_HASH=${AUTH_PASSWORD_HASH}
      - AUTH_SESSION_SECRET=${AUTH_SESSION_SECRET}
      - AUTH_MFA_ENCRYPTION_KEY=${AUTH_MFA_ENCRYPTION_KEY}
      - AUTH_SESSION_HOURS=${AUTH_SESSION_HOURS:-24}
      - COMMUNITY_INSTALLATION_KEY=${COMMUNITY_INSTALLATION_KEY}
      - COMMUNITY_ATTRIBUTION_SECRET=${COMMUNITY_ATTRIBUTION_SECRET}
      - ACTIVATION_STATE_DIR=/var/lib/laymatched/activation
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
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1/health"]
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

SUPPORT_SUMMARY=/opt/laymatched/installation-support.txt
umask 077
cat > "$SUPPORT_SUMMARY" <<SUPPORT_EOF
LayMatched installation and support summary
===========================================
Server release: Ubuntu ${UBUNTU_RELEASE}
LayMatched version: ${APP_VERSION}
Customer address: https://${CUSTOMER_HOSTNAME:-not-yet-provisioned}/

Services: db, api, web (Docker Compose project directory: /opt/laymatched)
Public HTTP: Nginx on port 80; HTTPS: Nginx on port 443
Web upstream: 127.0.0.1:8080
Persistent volumes: postgres_data, bookmaker_icon_cache

Important locations:
  Compose file: /opt/laymatched/docker-compose.yml
  Private configuration: /opt/laymatched/.env (contains secrets; do not share)
  Nginx site: /etc/nginx/sites-available/laymatched
  Certificates: /etc/letsencrypt/live/${CUSTOMER_HOSTNAME:-not-yet-provisioned}/
  Activation state: /var/lib/laymatched/activation/
  Recognition heartbeat: /opt/laymatched/recognition-heartbeat.sh

Useful diagnostics:
  cd /opt/laymatched && docker compose ps
  docker logs --tail 100 laymatched-api
  docker logs --tail 100 laymatched-web
  docker inspect --format='{{.State.Health.Status}}' laymatched-api laymatched-web
  nginx -t
  systemctl status laymatched-recognition-heartbeat.timer
  cd /opt/laymatched && sudo ./update.sh

This summary excludes secret values. Keep /opt/laymatched/.env private.
SUPPORT_EOF
chmod 600 "$SUPPORT_SUMMARY"
chown root:root "$SUPPORT_SUMMARY"

if [ "$HEALTHY" = "true" ] && [ "$INSTALLATION_HTTPS_VERIFIED" = "true" ] && \
   [ "$INSTALLATION_ACTIVATION_VERIFIED" = "true" ] && [ "$RECOGNITION_SCHEDULER_ENABLED" = "true" ]; then
    log_info "LayMatched installer finished successfully."
    cat <<WELCOME_EOF

================================================================

                       ✓ ALL DONE!

                  WELCOME TO LAYMATCHED

          Your private LayMatched server is ready.

             ✓ LayMatched installed
             ✓ Secure HTTPS enabled
             ✓ Account protected with MFA
             ✓ Connected to LayMatched
             ✓ Automatic health checks enabled

                 YOUR LAYMATCHED ADDRESS

                 https://${CUSTOMER_HOSTNAME}/

               Open it and start LayMatched.

                    Welcome aboard!

================================================================

Technical installation details are saved in:
  ${SUPPORT_SUMMARY}

WELCOME_EOF
else
    log_info "LayMatched installation steps finished; activation status is shown below."
    cat <<STATUS_EOF

================================================================
LayMatched installation steps are complete, but one or more customer-facing
activation checks have not been verified. The installation remains fail-closed.

Technical details: ${SUPPORT_SUMMARY}
STATUS_EOF
fi
