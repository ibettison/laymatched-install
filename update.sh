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
        printf '%s' 'H4sIAAAAAAAAA+w8/VfbxrL92X/FVg3FyrVkmxCSmuvcR4nTcEoMx7i97SNUR0hrWxdZUrUy4FK/v/3N7Ie0koVD0rymPS/iHGRLu7Oz8z2zu87iOGRtb8GyeE5TZxazLHLn1E6WX3y0qwPX3u4uv8NVvXef7nS+gH9Pd5/u7ew8e/YFPOns7nxBOh8PhfsvmLmbEvJFGsfZpnbvev83vb76sr1gafsyiNo0uibJMpvF0ZOGYRjHseeGLRLFkcWol9KMXLth4LtZEEdkEqdECQ2JAu8KhaatpAdbLiizAUpjksZz4jiTRbZIqeOQYJ7EaUbcKIozDos1GvJZStUntmTq4wKgxz6Fcd1G4+XJm4OjIekTY+5m3oz6duguGbZjthfbiyujcTo6GQ8Ox4OX0OrOcBfZzGgRI6XTgGXpEj/f3NzgzU0CfvPnQYQf5m4Q4p0tEgRorBqnB+PxYITDpRTAz5MgpM3U+OXctX7rWN9cNP/Vkx+ti7tu60lnpd6Yjwyz0Wj4dAL0S+dAt99okxOlRwANk1gv8N5rELgU+WAcbbJ20dEYvvr+EFDjAEwbOgZJ07Q9l9FJHPpNk4MJcKyMSKTtySIMOZGaCr5J4oJXJIhITiqBB16pGzBKfsSBBmkap00j7zAHdpNLSp5YT3ZIGN/QFBEgB2eHR0ckpFlGU9YifjANMoYjBRE8idyQzJbJjEbMEGiCIC3SKMcDqASIOw5+BunoA2sdB1gROY4h0AKuFfglKYBtToy7gjogK7abTq/Puxfmyr4TIrKSo9FbjyYZaR5FPr3lM2ppszOJywjFT9URgMZN/sJskQmwvY+jsMyHZ2aFWGdLltH54DbIml2z8an1+X0v5oEwZeAB4mgSTEFFLaXW1izLEpj07A+Psdn+7+x1dnZz+/8M23X39jrdz/b/z7gq9v/SZbMGA1tv0UVMkiChEzCLjcZX5DXYdiuOwiV5PR6fnoGGg/0FNeE23CaHYbzwJ6GbUgK+wqdRFrghIxG9BgeRUtebkWwWMK5MAA3sQzajhQv58fRsn7wcnmFTP4goYwQaA3z3MgwYGHpyuRQ9AHIKRsX1suCajw3QGE2vA4+CdQK/hG3SLJgEnpuBmWNs4UYetRuN0eBlf/tt58mT887+k+58u/HdaDAYFo924NHwUH2HL2E8dYJoEjdNcifswoRsb12eHw1fnVxsXZIt9jbaJsYjDseAD8ND/N819smqgXSrdhyMRicjvSegpPcjL77e2QebFWSkizAaEc1u4vTKQbr3O2gpz6HhXbdnrQz0gpYlW3DOGORiH4kUCbei9+3yR8o/9wHGDsJo0JDRtVccfGMSNID8GXX8IMWnB4fjox8PxkcnQ+dsfDAeOC+PRj2rfe2m7TC4bIMjlj65XfAGwNzQS2eRgKBQd45gjg9+fnMwPnw9eOn8e/Ct88Pp2Xg0OHjTs7o7z+wO/HV7zzvPO9AzmgbRrYN6V+k3/O5o+JMzOjkZw/g089q8JfQAL8Ro5KXLJKvrdzwYnw2Gh6OfT8cSeeysdcoHZUFGawc9OxoPetajuwK3VRsbM8u9BoaDtFKNEjk8GuEbvxbkYHjw7TH44FqosmMZpjdzw5BGU1o3ycPXB8fHg+F3A0UgZBCEPLXzBLWvxenbo2HPUlRl3MF5WVjT/Ozns/HgzeH4WHTJm0K3S9e7WiR9CAFdD3x78RX9iiP8jQNTgXn4INtKAJ0ZDROaVsZ5fXI2Hh68GTivB8engxESS3t7NASJhFmPJFvjJNMp1k7S+DpgII9BNAX/lqZgRGpzHiQuGI/LOHPmEIdVkDg4BATenLwECQBpxjk2zokVgUYqEKCB5PffCeo+MXLjlofFYNJS+usiAANpNGSorfWWU0dbcKeebW3Z94S6YAFetH163Y4g0iNvuRZvHjuIeAQPaEM4htF4FjJHhrsOGmaGBosDCjH4J0BHDND5O6RFVb9WbdnCYiwU8mIjYw0Nhj9L3NSdbwKCnVUzO6FzvTuIE6DnpksR40ZgkmC2lk+smGBvYk3lfU46z54+BdpVBzBUeHxOviQWgxb6vMpGkwecakjEVm+6srN5Yj96ZORNF3OXXcG4z/In4HTICxgiB2KQf/5ze3x85pycou08227AdB0GHg7gOh44RkrYDPym3ytE1oE2vW5nvl9qnAVzGi/AN/jV594VxaB7MhEvQN6z2IPEnsDA1117R96fqNd0AnKPXhNuXgDheSp7a4gWU5qBLhCM4Erzyt/Pr4k1KU+5QmLeFPxJlQ8l2VhnBKRcczcCVl+DJILIslCX+J0XX3cLgVcNNBUjGUQwKU0wJhmibCIVCB+RYrJi1HO8hNQ6ywH/L3N0pjRKrugShBA+YC9iueE0ToNsNicvXxML3wIpyDSNF0lvMvFndKez+xykF/iok6wydZ5ezJGullVPdU5SPvXDeBH6PPcDLGiKUc/m6UpOfDBvy2xTzIVw5UHqWfZebfuGhqF1FcU3URsdhZW/N94Jr9MBeHmQAnbtBigPZrRwMLlB+4qcppRLPHEjDLFYBs6AYISEdxHTos+1yQGveYgnIZ263pIkoevRGeTaNJXQQM7Qo4GULRLCYuJyZsBXdBLEzZBgGViDCMQRTDGIIAR19BZCo3BpF4pgUTT2RdCxslVAJ/zlulKUnOnGriIBDotxirbrYKHVFHSFWINfyXbzl9/Pz3ssgUn3Li5MtBlaTK292i5DrRNike536oRvw1S4JIhXJe3zAMOkMhXjkQaoZGvqIo1unXOpDq8rfdnG19p3HjQ1hD1VDhQEjEbkeWeff5W2lnvi3N/v56jwmtoGVWhLqJyiKP4VLRKQVhvgFb5FpQwPg4mXD0ngIsycbJlQoNlt1gZ9CKL3GpQXE/6PhtSggue7XTqJC/kjjthrtx/pCch+pSFkuhB0uaDWPL8lbzlvNrT6yRpB5GcdnULTlM5jsDau76cbe7yK0xs39YEI8An6iSbQzbl1JuodfnoglFP07gCHAWGVEK3Q/AoxFGK6wa6HEXjfyZoSlTIV0bLW+mu9lB37Mn8MGYJBrGzduMhAWddUiJW//hpfTNZe1BgShUup4To2eOVJbS5rhSeta6+ZJGmuupWIBSdYSoMMaBnGLrhd7ml3tLgE5lTbHOtMmWj/ackjh9zMMnU9fN4QimXpokx4jbIfkSkr5ehViaOwImtef6zVjFSZCLTrkjJeTkoWl2HgEdBnWTsSNSgA4wVhIGtb31OaSHC8hgVBpSWCCWGAhK0HLc3x4OWYHsQRxE0Soc0EI9kolnD0GhkYhUUEZAXX6oNZXEDeTzBmpbdJzLDyJTADgwpR3CxIRPTCqlFEybuj6Hx0fy4AArx1Z1LpKNNRdeVR+kDFXSK6UkVnQcaZy5Bix+7yjQCuSlgFXQV5jKpkdNYSjHqK8MTjvSOu+pjjnZGXROcdkYbq+Ukijl/+508KEvDK0qUoMoDrWqQB6e92du/z54qx2ES+Xkn3xknyF/Ruk/cVKx2FjR3/kJOrn7omn5oafQqv92eTTY7813R+H8Qs8IYyxaxNfOWaQU0qBBOnv5LOGoXvN6ofHqK8R3jyIO68F2c2i2WVxiVevSNIWXtdYpwEWCl/46P6EvhKL2CwKiPfI2UVTesz60pSXfY1D6sV1DvEGt/3OVn+KybLSsGfdLpcEBlkySLxxZz21wUohwMOel8klXWM2t19QrD8ib133smzSrhJ1gr07TC4pu28Vxu3rsBcgwgXA2phOFh0fSecJA2uoWEBJYi8cOHXYVC/jlGMLUueNT2rixdVOf1/WZzgYlVUJh4WuX38eKzijfIRah3QPrf891j8/b9QuPSQyOhvHAQ9NEDVeivXUyxBOCkk5Ddu6Mzi+KriQvFRZWV3NBgO/n1w7Lw+Ofl+fVtAWwKzsCeD+SZhvFyz1xZkx3Ga2Wy2kqL6kNWQph+k3GjiMnB8ZZibUkDeAlwootl42M4dwSUrQ4nL+VhiYUOWR8Dmh33j7aMm1hwg1Ntm7V/0PR+D0Y9HhwPnh9Fxv91OtomgUrHrA6sm0yjgJRNEqEYyYHJukjjgKHDdcm2w01Pnx8HoDEaTI5TX8dsbwObx6dtH2nSKAJW/0cYu3tyuDVO7W0CbneOFATyyk2VJBekt9UjOErW6/weAvy2KKJYlZ2XBrNYmaVl8DcwCUSKb9+OUYQI9LEmPNfIIYRaSXe6V7yjQtz1UcC2c/ZouVXw0tkW3WYGQF9K4ulQXDfnmJK4EXDuETxH6xFWEGwKR9+i7oETC0y1xbXMhUatj5TWsYrlVKTgWEnOnJUuK6IWLspWqEKrwXOwrI8b4Qb3EorbrSz/J94d1kATr65219u/e7R45lfRNL3xj2Tz2rsoepkCar3BiA4LNe7yWp2FdLuoBHhAiqIxIQ11b3Jej37+4rxroi/tqr5/a6CIqirp6GQ2Ke7odN52yftMsbATuZXszcAZvDo6O+U66khprfSyLf4MeRQfDLDbNlduKPeY0tRYRcyc0XFo3ARiBRSagmDhtHiao6eCd76i0LIgDhWO4WRd2dCAlXWsIt3xXDH/+XxcrtAO4cM33XXOVp6jj05RSK4sZfL6iNAHksiC06G0SpEAjbeI1RQThboXUS5zFKve+KJ6n9DqIF0xuNygz/sZlCqTP9XUtjhC5Msf6RtHExj0uqSDTei78YGyFMNSh9eH4a/HGxtpvJd3Pt3/KLZ8FH1/omxfysxO4vU/EyOXdDVqDQhUPy9Kfb+KGCSqGSUMAd9xVz+eUQKYTIOnxFIe7AAgwZU+1NP52e9g/Xx9+Zfz8V20A8tHG2Lz/f29v98nT6vmvnc/7//+c6/7zX2dz8EIt3BYYBhG10KURIRvcbqABhYgR/C04Y7XCqskRGqMM/RA/BfY+x8DAoSVuyvLDYJDZ0L1d9c0He4hOAo/u+Jl6+h8WR+pzzGoOlC0uAVWPMlZzxAzB5cfN0hCiZ5uf/ak8k7Wx/Oki8MW0EjebQQM1p1P42mjkx5Z4E65mNs8/HS0clz2+p8szsTbdkAeW3sT+IqTDOHsVLyJ/UBxR4tAeAKfRkKmUc3gyfHV8dDjmu/Z/OIPobrfzTWM8OhieHQ2GYwddh3w3wLcwwm8QMNKsebfbed4iuztP8d83LfI4xUp182mn0yLgncyV2TgECCNInEeD8ehnyBFhsJcIZK8DGHghlrpGhUzgUOJY2QjDkLk8hSVmhoflHPBrQeY4kBaGkxZB57dgPTxKZhYntHyaoZOHKHWfTCC9mBGZR2mHQmRXFSWmFNiBISGWPeSrfp/cRyJeCDKKSgQEzTRtmnaO3sSok3gpIGonIEZ/Iji+E0Ou7gTq6nAaBw0TtRVGEjV5ctAJmANjgK+GsRwukeJMWo98Cyox4JIC4/LThJcgYL2GViuBKBhTgcijolOLNE/O5Am4sdhILL/pIm9Dei+Ywk8LNovy0xq4Or6afJeDgCQnFUTkHlnjsNUxScfDrAVJ5iCzAsqacUJFLMbPTLaIx+3R4xYIgOujTeqRSRi7SjTUnsu+XLm6mQEXyDhd0EJ0SmcJNWIh6GbBFKmEOYVrjglymogTl/fyySw35+PhkcEKBhiX4Z6Ifj4xYnGbZM9jgA+5jKfhJgcuuv0TJrw+ECbf0xgSS1BoQwihzpYV14SHMlXoAxj0iHp5FA123KifH9G1u7nWBq+JcZezdyUng3tpo/wYDfEXmKBwP3OJRhA3x6Aag15FPmQMzTs1x5W5jogpLKWw4/oLn4YuUmUeRM0d8vgx/yBlB+yc2SJdsHc5ecuE51xhIeRRzbl72+zY3ZYAaJbbKVn8R590lYBf7u2qI8CXy4yy8iFgKYjC19mgkuhvsQ+N8ERwU5799Sn/ZrjMCwLDtFNxGNjo5+eNnQTyhCYAkFpzGfvLHvEDD2Yn6vVMfD3nr+HfRYvIkwXc0gJtuk85cthKYCeQ8OEVOlrbX8wT1kTIAAA32LuQJkEObLTwAHXPACIyLDJc0SXrowaatpyGscgm1vP8KLCwl/2Kh7VH4o6zaKHDd/sSgXwK/bvHj+XHFpZkIOeNMmu8TKjRw6PdSRiIBZg2ImysWmROIbLx+8bpydlYjl+yBtxaV/CAr7jTvym/53Tqyzs/PywTKlrWQc4vRS8strKmamhjLadplg4ol2xwrnk1dkcqWJ1PFZ2RTmvCLy2Vpu8cvxZnsbkGXVffezwdSisIhBupU0U5HcrnvPk4SjSnVJfMD5bGh8mNkpRcTJQEfDf4LAAfIgBadPWB/E8Wny3TBsv0w2e5/ESGKeE/lPFZNO8VTVwn/Sycn0g4+dIQygUuFkMEDiFvj1cZyiGk2t7e1+oARQ9Tb2OLFSGZVuBP24Q046JaFErsdBE1z9XBSpRRPMyIdwswEr+ZY/Eb/liKAiyQNWUr4DZvBnfIw+f4+eVgZIDyeDPqXXExx8Qu4VUhaAUeQsi+Tg0eOudI4s+woBQp8qBcOCgwTazDCMK01J4os+Y3ZCRUTcawI5cvB3dPVYTsVVBbiNEgybEUQmLdYg0jEcEjx4ZxJOWeD4wHVKPMnl8Br5riC5OU4Tv9nVgRip9J78TPOh2BYcxsvljQ1OC0iNagWJXsi7F4go2rCM2JYd/xR/htZd8BLAjPkgB0DNc0bowKBFtMixNIs2dSIx5m0CpY57AR5z1tUinlBy71BohqzaTznpL28kh0raIUllmZGU128g6kTQwJxeZmsMX5ZT7AIvDfV4ozAR6pCXlaHjM5gW/Ut0Blc7L4ikbGBxgViSuujSLkYgnofotyGccZ/nJL0sS1Q04bcGGyCpfToc8px5vY+SqUqe9sUfMqG+wKKbGnIKRZUrFzowLFuBACh4RAQyR+cCmIpOFXP3ul84G33UwyOQgezsmP3JTWkXmtEIaR5CqMLcpHnemtuuG7tYn0qgQCdSg9KcBC2+IL/1GyYg9Gj3Daa49WslAqq0T9tSoR+QeprciKAhljuDEjRurWlNtyMmpCi6uDMzzODnY/fx+680vf7clKg8ARmjk88Mid/p1xIPr+xiHBbCbGtxRMVEruON9WxsosgKpJ9dWHliwPcnb7aAggWvGWkjPocrAAb+O/XWWxhS69a3o1+UyuEfdOc2Lc8ZlqG29U8WW7vW2u2tddbZ8NMwpK1Na/yEb65Jw6384/bl+s0KweFaSwvufyUyHOg4mq+6lN1u+uYsR6ksznlecXKL66MdMbao8v7qPIvZfBdytQ5rgZ162syeUe/wHnQebxkRpLtQWNvjDff6hC+QqgwlCrNy3SNXHpA5vnRyXyInaEigjywYJp5GJUU3VFKqiWmYaIELSkg9cGRcwMFmOeyJcA16v78cBSZPN+S03Y413LTTnUB8KTT2cuwxUx/gjmwdwpWivjbWTY/4mDqNkUNBDTb6nmNpu5O0/3eI5k2jN66wdTzGhMjRySEmaeHK1HirXRr40MaUpczCJegKfUd9S2d5kdrfPscatq09/Bv4pWiiYbpVFXEt6c/M4jDyAc3kpyg8QUhUwV2BSJqZQLRTDlJeDVhGuMsfWztTW3tvzx1uve1pve1tl/G4LA9nQudYqD4ITGPFOzs8gV/lJSivu/n6wjjTbWUb0H/Ol/2zvW3jaO4/f8CvaAwGRDynRiu43SK2AUDdAPLQKk+VALAkGJpE1YIgk+KjsC/3t2Hrs7s497UJJjBLcfbPFud24fszOz89rRz3ZPjP5re2dq+qUNp0c1+Q/0pjinXqWqqj64dqZF9a6082pxkQ7oEb7FX6ynxFZUUSvr4PAMXgR84BItNo4TiKbsVsyozs39KWh3uJ07+Rd41bAXoTG/tqqNPw/JpDIJLGoa8wLhGSaIcqsGbIGBR3zh6I46gLaaUY64EWeneTSVSTu5QUhUej7QBtpUyLKUiA70LYQsK8JbB6ycDKJQsE4gwcMdiAw4fappjupF5MlvkuhVsL/LRzkAxJ+BQZS4MaNXMC6n4or7p5e+DH7rBmJ3N5WetvOFWen3iKvxVrBI0EBGklVrpKRGcpCHVycJBbKOU7QF0o4VB2MhaHBsJUi6KVMs2z21lIydlT8DJVOyk59bUxlTAMtxi5kf9sZaQdQHDWqcWzgDemy5gnj6tzK1mq/Hkaaphsy7aQlno9Q/1QJwE89IiCjAkQ6Oy2BknzVfhYxwWyX5eGU7r9awF7p+JNe2EqihMdvpJKO7T2DF/rC5mV/QMODfy1CHf1WgywRyv+WO2qNfxGflVLT+0J8fp+CFzuxrgXluDTCN4FBwdwEzqt5X7VCHUZhgs+bJ4oJaFbuJrm+MQBN4sdh3hw349PURmHCMAr5xkmYplLBg8E04XobbhZwOv1vLvDKMK8+0WjEsySpKIXflGQhbcljW9exOLqfeM6o5P7RrpWp6GBCcVDaVTOSXqVuY/R2s80kfLes94MxZgwwEsKOmIbD9mWQikO3uj/XQ0PSVgWfNhjUQXf31rqoDWL+N21qV09yQSIL3lgs3stvxgk8hP0uZyfIecMrZ70/gXPoCBsaEqpkHnBF7kaY9KnuzpQUJ4p4Mgu5ZkguLoo08NiYjVhg4+yabBpTZJysxuVTEVvfmzwsi4ZSWMUlACV4Lec/d4BC1cS9kbRdmEtZ2L2RtWveoLj/mmseBnjUX39QHp3o7Yx+WKys3uApe4eUnj3X/27m44mJbXLwZvaXLNyZwGcfr4Ytv/wqnHwfqkey1PjvpILKXYASXWUWR1aEwvxeFCBW+h2Ey8XNt621/gekLvoSGvlevEm/CPqRrim0lXu/NnpuDnCrx0g1aVJH2QB/89w0q+YYkNy1X70rrqai/TSDQePfypVfGIdY8pcTPSohFoIXYPb+3TPSZOrCB0l2d6oe9CdGplJDsEAxH4M+RsVxh6Zh7IH3T/NOEEIECBArJ7pEj+WUROcALYJUks52iQ9lmFv4gCc7esWOHk09stUs+YfmjqnvjSW/TUyX/DM6UBJgRSyypQLET7J5WUdNAmo4t0SyY0v0y4tCQQXs/sowZPbQ9SA4AKnsL1wZROD7kt8NstZu42AOuSAR8Bvf1kIAy0CRdfruKPUlozZiTbFHHmmTdasZ0X1Do9HkPBjWhH+ZMRkEa9jH/OiJEPy1DeruZr4CYqQ/IMSm9TG7gopKGA/twutjPt6ZxzSLIypa58vpzdmsvkpyK4w87d1Ubp8Fp/sWQ7Np30+Xe7JLr9Wq2e4ztFQmFWhyMiAAeC6u3Xg1IlAwNXsitB5qC9fqmH30uvRMcDU3B8iR0mSBi4UYB4Rsn1t3YBWJ7upXfMtDKHthsw2PuyonwGJSQo1xmdeUt7Kdntp6TugA/gdEdzEwh36cbjOBacmqzRC4aZxLCRRElekBmlJvbqDLr/W4ke+OIleXNcv9p4owjgq7puU23O0EweW5BjiSkIgl/KPdWjfCCbbMbQoVRkIavjEZC59symhmtkhByi0NZNZTs9svoLwCtJAB2sLIRRcWgHn399Xg7GYyURsj61QanSXLvWW7+/9K+FY+OSbgPwgYBSNz5IJ4+LTKE42BcCKetHhVEi+aYsFzIdo1IZFT/4cSx/QHT39MjCd7+vTnPtKGYWbXEUMJlr193aCsTc5YhfbzLfFvKar2v4V9NJ2S25Mw6oLoysxIlgPbd8DqC8Mjg1QteyNEpVcA9mUErFYGDZIfvNnj1Llbb/LWpQFaMQnzVunmf+88do8+dtO95HA4YB0M/mpSDM/sENOMXRzLk8JlcyAXIkopUziRzkqTUUw3JBhSlzS7vi38tRpiBHHzynhX3ekKbm0ePxbNjSJ9W5ls2N1NaRH49luHL0ca0xzAgTeJAI6Lj3Wkmta9d87JUBx/JRgUE2N0RDHUIsbawetbqMjVBin2Gb0AYomHW7tMPYGfZGGxJ3PDYU2dP7mU0dX/38dMtO2OpzpWhREiBzYzWhR/Xd0Yute7QU+xQHCh8zNMsxyXM0XNvDlQo3tJ5y2D29+PxMdH60USP5/dS8H6mDz7QCr+nA7dbk5mGpEaJJ3aUTjCxkxbbk2vEEu+w04zOQPkstAaKRo3mdAeKi5Gn4zpEyLO+rooSGFnqleGs340HUlpul92gJrPBU29lGd9vBo3zIJMBtD6Xnr6zI01oI6Eu0i5qub+BHpESP1Latd9TT9qYOMbSrFKi4UACNZqXy9C5kxHAieBlRr2YloDX4pJNe76wD5pJwJy8zUFkhwpCXsq1ZB4F/Wgl7NIkRKLuwuD0fIs4E4f+ua6rGMCPr8bf+8g/tvO7dJ/wYrW2UX8CPP4m927pmVATBTjEbOb0J5kcOPjPBgOd7TbmoA/pL4AKXoxeXLrYseIcvlkMzvCqeiYx89VsMiP95qOP1sAG0E87PBoFaZKBpO7PbD4saLNB5zE7SNMpuGp61rN+3r2v/9f7+i1qbTm+7ldII1jOKO3ir0aMOzvsr2mqrBiRVL/bP4eUm9NmZRcLPuHFPpdIJtTesplBdqcA57GdLXdriBid7vu+u8U34/H5eAyz/Vbp0MP9LA5Zpu76CjXjM1LPyylbre/64eAbf1m5NbeSlyhdtMG+9eJk62JjgUeIOlrIEcKNy51qOhRxpKZWQWkUTLEhHmEjWxbxE3P6qHYDrfLcewweFEcKNzSFeN8axVTNDEPe3VPZqhaPa+foJD7qTg/gXDGROk33wGyC/fpuNbkGHS2/dA+AIhgZCzAInNzse/ns9I3D8/dEmwYdvVrsGu5Nj5yHHrpxiLBXHg5OPxQ8yq5kJL5dTL9kBK5IZiB4/Gx9/cHwG8TWW7hmD/6EDO7IyoF4FtPNEpMeUEZMfH5Lzzdn7u74yHKk2P/drGTsx2/ARNRmPoiFAvyX4u/cXAiSFCZG0MIDYOKuj7KDk18lLFYLrQ/ba1Z4uwMVrDQIElNISlbY0HXIlOdG2I9B2RuQDA2MX5J2jlhxsgIog00lIhS7ib3Q2llKa7y46IIHdyL8949v+FbBvcCL5X7Xsx0xEuF2fXMLySONRDI3u/VTERBCO6DzHi1PQQQDPAf26/0GUEIO61yN6kK9C3xy86N132JY8+sDBGFPdMSG/lCm6uXgdHprEGDEaP00JPeXVmIKLKd1a/qjE1uLroLCfMlUVwQFgs+h2S/vwDdwe7tjXD4dCe1MfBmistBKc8eShoY/Gjqafm33V/Pp/ndyK5IIHAnrNEDy0bIKbO1WbXsPiYiu1h/pM9jMoM/B+p67PEIC1LB3cRmgeJzuIxsSUpfQYwjujBiqbsUHrqOfHkVXobnpX/++gA6Z+hR0VATxItirIIKIkxbQpcir+Z3hhPNb0DbNDltMucrZkqerT2FMKnJ/NsbO5nCHy/bTmdRDJSaO+jsQ1ix6Itya4PslP74YX3o9bBjw0OI0p+gS7SwK03Ppj5MJj9O5b4dKwJDxfUNIfRBG+omd85dXvgOpqGYY+wWt4eVpMWOnElS3G7zxpT5SSkxw44CoqujdfFEhUnFYFE5biOytcoo0CZ4a5FGxWT4YF36t1zkKDXqsmJtEoE2Eh8nhQFFGt0YROIPU5wwDbBlyZ8sDsasmFhxnrSEenRBaByWejwehiZpMDfszU7M0JjXuRJzm3xYSSNKJ9IXn3Q9e9IB+UJrwBbptmSkyEwcqmJKThZnPhxbxsOfMRDfrTX+szI4hb8I1bMTbcEJuwlSWsv7ZYWWkwg/926VBJ/NMBfUEkhaYGvtawMLbMCDni70Z4+zN9t0BDq0/4RvmB1TtDO7unPL7fiHuhuOcVJD1THw+00rcN9eqnbhTLt1ud7jCZISuNShp8JdhMoZQlAXfDJZu7jJ1TdysGAAIiB70C5/MK90k7rM5POQH6vAv/0XPUdNN4jUh8W7kTrPX79fmNzB/0/Zm/x5DFGbzd1tDAWAmisOKYrkGLrVl6ao6b3QMAMj2kiuMAkOibhd11XkYJienpjF7aC1BS0KLKx3pToGobwYsxGzgzYd3d3fytsFmQ4RIhJH1jBn24BrlEqxVDvZ3NjclXUZWMcP+0sQibhF92K1EGvGqmgr72SmtT5lF1nfXDt9q6VOtop6AVWGUn4Oa1mB2GF1bX/G2rdkoMUJDRRIAaEDrhmvqFGHtxKdQA8xk2M+2vh20kLqX/IeVO1z40qlLOOzFSB+e3uJ/eGOgT6RpNdR4GyO4BXr6GeUfCTKHZkF4ghiBCDQJWRBqL0VQYi+VOkAWK3OglG2uDhiseQ6Qs49kgdijfgggE6eYheOWOoKU1R5+pfqbihj7Ci8FnaClbzLB70wmIJRMJkUqmTJq4X/Gmx3/+XG575P8wu4WoZhYL34OpdHmH0ClZj/RL3vBUHQoqpIk+b4kuvvmWCUuRgN5MeguQuxKV7rSla50pStd6UpXutKVrnSlK13pSle60pWudKUrXelKV7rSla50pStd6cqXXn4DEXYhvADIAAA=' | base64 -d | tar -xzf - -C "$stage" --strip-components=1
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
