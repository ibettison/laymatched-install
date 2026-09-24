#!/usr/bin/env bash
set -euo pipefail

# Host-only HTTPS orchestration. Cloudflare credentials never reach this file
# or the customer VPS; DNS readiness is established by the central activation
# service before certificate issuance.

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
log_info() {
    if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
        printf '%b[INFO]%b %s\n' "$GREEN" "$NC" "$1"
    else
        printf '[INFO] %s\n' "$1"
    fi
}
fail() {
    if [ -t 2 ] && [ "${TERM:-dumb}" != "dumb" ]; then
        printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$1" >&2
    else
        printf '[ERROR] %s\n' "$1" >&2
    fi
    exit 1
}

network_only=0
if [ "${1:-}" = "--network-only" ]; then
    network_only=1
    hostname="${2:-}"
else
    hostname="${1:-}"
fi
state_dir="${ACTIVATION_STATE_DIR:-/var/lib/laymatched/activation}"
web_upstream="${LAYMATCHED_WEB_UPSTREAM:-127.0.0.1:8080}"
nginx_root="${LAYMATCHED_NGINX_ROOT:-/etc/nginx}"
letsencrypt_root="${LAYMATCHED_LETSENCRYPT_DIR:-/etc/letsencrypt}"
nginx_site="${LAYMATCHED_NGINX_SITE:-${nginx_root}/sites-available/laymatched}"
nginx_enabled="${LAYMATCHED_NGINX_ENABLED:-${nginx_root}/sites-enabled/laymatched}"
challenge_root="${LAYMATCHED_CHALLENGE_ROOT:-/var/www/letsencrypt}"
nginx_bin="${LAYMATCHED_NGINX_BIN:-nginx}"
systemctl_bin="${LAYMATCHED_SYSTEMCTL_BIN:-systemctl}"
backup=""
acme_backup=""
http_config_changed=0
hostname_helper="${LAYMATCHED_HOSTNAME_HELPER:-${LAYMATCHED_INSTALLER_DIR:-/opt/laymatched}/provisioning-current/customer_hostname.py}"
certbot_mode="${LAYMATCHED_ACME_MODE:-real}"

[ -n "$hostname" ] || fail "customer hostname is required"
python3 "$hostname_helper" "${hostname%%.matched.laysports.co.uk}" >/dev/null \
    || fail "customer hostname is invalid"

ensure_tls_support_files() {
    local options_file="${letsencrypt_root}/options-ssl-nginx.conf"
    local dhparams_file="${letsencrypt_root}/ssl-dhparams.pem"
    local temporary
    install -d -o root -g root -m 0755 "$letsencrypt_root"
    if [ ! -s "$options_file" ]; then
        temporary="${options_file}.tmp.$$"
        umask 077
        cat > "$temporary" <<'TLS_OPTIONS'
ssl_session_cache shared:laymatched_ssl:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
TLS_OPTIONS
        chmod 0644 "$temporary"
        mv -f "$temporary" "$options_file"
    fi
    if [ ! -s "$dhparams_file" ]; then
        command -v openssl >/dev/null 2>&1 || fail "openssl is required to prepare Nginx TLS parameters"
        temporary="${dhparams_file}.tmp.$$"
        if ! openssl genpkey -genparam -algorithm DH -pkeyopt group:ffdhe2048 -out "$temporary"; then
            rm -f -- "$temporary"
            fail "Could not generate Nginx TLS parameters"
        fi
        chmod 0644 "$temporary"
        mv -f "$temporary" "$dhparams_file"
    fi
}

install -d -o root -g root -m 0755 "$challenge_root/.well-known/acme-challenge"
install -d -o root -g root -m 0700 "$state_dir"

write_http_config() {
    # Preserve an existing working HTTPS site. A non-HTTPS legacy placeholder
    # is backed up so a failed ACME attempt can restore it exactly.
    if [ -e "${nginx_site}.network-backup" ]; then
        acme_backup="${nginx_site}.network-backup"
    elif [ -e "$nginx_site" ]; then
        if grep -Eq '(^|[[:space:]])ssl_certificate[[:space:]]' "$nginx_site"; then
            return 0
        fi
        acme_backup="${nginx_site}.acme-backup.$$"
        cp -p "$nginx_site" "$acme_backup"
    fi
    http_config_changed=1
    local temporary="${nginx_site}.tmp.$$"
    umask 077
    cat > "$temporary" <<NGINX
server {
    listen 80;
    server_name $hostname;
    location /.well-known/acme-challenge/ {
        root $challenge_root;
    }
    location /.well-known/laymatched-network/ {
        root $challenge_root;
        default_type text/plain;
    }
    location /.well-known/laymatched-https/ {
        root $challenge_root;
        default_type text/plain;
    }
    location / {
        proxy_pass http://$web_upstream;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

NGINX

    chmod 0644 "$temporary"
    ln -sf "$nginx_site" "$nginx_enabled"
    mv -f "$temporary" "$nginx_site"
    if ! "$nginx_bin" -t; then
        if [ -n "$acme_backup" ] && [ -f "$acme_backup" ]; then
            mv -f "$acme_backup" "$nginx_site"
        else
            rm -f -- "$nginx_site"
        fi
        return 1
    fi
    if ! "$systemctl_bin" reload nginx 2>/dev/null && ! "$systemctl_bin" restart nginx; then
        if [ -n "$acme_backup" ] && [ -f "$acme_backup" ]; then
            mv -f "$acme_backup" "$nginx_site"
            if "$nginx_bin" -t; then
                "$systemctl_bin" reload nginx 2>/dev/null || true
            fi
        else
            rm -f -- "$nginx_site"
        fi
        return 1
    fi
}

write_network_challenge_config() {
    # The central service probes the public IP before DNS reconciliation. Keep
    # this pre-reservation listener challenge-only: no app proxy and no
    # credentials or unrelated routes are exposed before ownership exists.
    if [ -e "$nginx_site" ] && grep -Eq '(^|[[:space:]])ssl_certificate[[:space:]]' "$nginx_site"; then
        grep -q 'laymatched-network' "$nginx_site" \
            || fail "Existing HTTPS configuration has no LayMatched network challenge route"
        return 0
    fi
    if [ -e "$nginx_site" ] && [ ! -e "${nginx_site}.network-backup" ]; then
        cp -p "$nginx_site" "${nginx_site}.network-backup"
    fi
    local temporary="${nginx_site}.network-tmp.$$"
    umask 077
    cat > "$temporary" <<NGINX
server {
    listen 80;
    server_name $hostname;
    location ^~ /.well-known/laymatched-network/ {
        root $challenge_root;
        default_type text/plain;
        try_files \$uri =404;
    }
    location / { return 404; }
    }
NGINX
    chmod 0644 "$temporary"
    ln -sf "$nginx_site" "$nginx_enabled"
    mv -f "$temporary" "$nginx_site"
    if ! "$nginx_bin" -t; then
        if [ -f "${nginx_site}.network-backup" ]; then
            mv -f "${nginx_site}.network-backup" "$nginx_site"
        else
            rm -f -- "$nginx_site" "$nginx_enabled"
        fi
        return 1
    fi
    if ! "$systemctl_bin" reload nginx 2>/dev/null && ! "$systemctl_bin" restart nginx; then
        if [ -f "${nginx_site}.network-backup" ]; then
            mv -f "${nginx_site}.network-backup" "$nginx_site"
            if "$nginx_bin" -t; then
                "$systemctl_bin" reload nginx 2>/dev/null || true
            fi
        else
            rm -f -- "$nginx_site" "$nginx_enabled"
        fi
        return 1
    fi
}

restore_http_config() {
    if [ "$http_config_changed" -eq 0 ]; then
        return 0
    fi
    if [ -n "$acme_backup" ] && [ -f "$acme_backup" ]; then
        mv -f "$acme_backup" "$nginx_site"
        if "$nginx_bin" -t; then
            "$systemctl_bin" reload nginx 2>/dev/null || "$systemctl_bin" restart nginx
        fi
    else
        rm -f -- "$nginx_site"
        rm -f -- "$nginx_enabled"
    fi
    acme_backup=""
    http_config_changed=0
}

write_https_config() {
    local temporary="${nginx_site}.tmp.$$"
    local backup="${nginx_site}.backup.$$"
    umask 077
    if [ -e "$nginx_site" ]; then
        cp -p "$nginx_site" "$backup"
    fi
    cat > "$temporary" <<NGINX
server {
    listen 80;
    server_name $hostname;
    location /.well-known/acme-challenge/ {
        root $challenge_root;
    }
    location /.well-known/laymatched-network/ {
        root $challenge_root;
        default_type text/plain;
    }
    location /.well-known/laymatched-https/ {
        root $challenge_root;
        default_type text/plain;
    }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name $hostname;
    ssl_certificate $letsencrypt_root/live/$hostname/fullchain.pem;
    ssl_certificate_key $letsencrypt_root/live/$hostname/privkey.pem;
    include $letsencrypt_root/options-ssl-nginx.conf;
    ssl_dhparam $letsencrypt_root/ssl-dhparams.pem;
    location ^~ /.well-known/laymatched-https/ {
        root $challenge_root;
        default_type text/plain;
        try_files \$uri =404;
    }
    location / {
        proxy_pass http://$web_upstream;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
NGINX
    chmod 0644 "$temporary"
    mv -f "$temporary" "$nginx_site"
    if ! "$nginx_bin" -t; then
        if [ -f "$backup" ]; then mv -f "$backup" "$nginx_site"; else rm -f -- "$nginx_site"; fi
        return 1
    fi
    if ! "$systemctl_bin" reload nginx 2>/dev/null && ! "$systemctl_bin" restart nginx; then
        if [ -f "$backup" ]; then
            mv -f "$backup" "$nginx_site"
            if "$nginx_bin" -t; then
                "$systemctl_bin" reload nginx 2>/dev/null || true
            fi
        else
            rm -f -- "$nginx_site"
        fi
        return 1
    fi
    rm -f -- "$backup"
}

install_renewal_hook() {
    local hook="${LAYMATCHED_RENEWAL_HOOK:-/etc/letsencrypt/renewal-hooks/deploy/laymatched-https-report.sh}"
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
        --hostname "$hostname" \\
        --certificate /etc/letsencrypt/live/$hostname/cert.pem \\
        --challenge-root "$challenge_root"
fi
HOOK
    chmod 0755 "$hook"
}

if [ "$network_only" -eq 1 ]; then
    write_network_challenge_config \
        || fail "Could not install the temporary public-IP challenge listener"
    log_info "Temporary public-IP challenge listener is ready"
    exit 0
fi

write_http_config
install_renewal_hook
ensure_tls_support_files

if [ "$certbot_mode" = "mock" ]; then
    log_info "ACME mock mode: HTTP challenge configuration rendered"
    exit 0
fi

command -v certbot >/dev/null 2>&1 || fail "certbot is required before customer HTTPS provisioning"
email_args=()
if [ -n "${ACME_EMAIL:-}" ]; then
    email_args=(--email "$ACME_EMAIL")
else
    email_args=(--register-unsafely-without-email)
fi
if ! certbot certonly --webroot -w "$challenge_root" -d "$hostname" \
    "${email_args[@]}" --non-interactive --agree-tos --keep-until-expiring; then
    restore_http_config
    fail "Certbot failed; the previous Nginx configuration was restored"
fi
"$systemctl_bin" enable --now certbot.timer
if ! write_https_config; then
    restore_http_config
    fail "HTTPS Nginx configuration failed; the previous Nginx configuration was restored"
fi
rm -f -- "${nginx_site}.network-backup"
acme_backup=""
printf '%s\n' "$hostname" > "$state_dir/hostname"
chmod 0600 "$state_dir/hostname"
log_info "Customer HTTPS configured; Certbot renewal remains responsible for automatic renewal"
