#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
zones="$root/deployment/nginx/laymatched-rate-limits.conf"

api_block() {
    awk '
        /location \/v2\// { in_api=1; depth=1; print; next }
        in_api {
            print
            opens=gsub(/\{/, "{")
            closes=gsub(/\}/, "}")
            depth += opens - closes
            if (depth == 0) exit
        }
    ' "$1"
}

grep -Eq 'limit_conn_zone .*zone=registry_connections:' "$zones" || {
    echo "FAIL: Registry connection zone is missing" >&2
    exit 1
}

for config in \
    "$root/deployment/nginx/laymatched-registry-final.conf" \
    "$root/deployment/nginx/laymatched-registry-bootstrap.conf" \
    "$root/deployment/nginx/laymatched.conf"
do
    block=$(api_block "$config")
    printf '%s\n' "$block" | grep -Eq 'limit_conn registry_connections 100;' || {
        echo "FAIL: $config /v2/ lacks the connection ceiling" >&2
        exit 1
    }
    if printf '%s\n' "$block" | grep -Eq 'limit_req'; then
        echo "FAIL: $config /v2/ still has request-rate limiting" >&2
        exit 1
    fi
done

# Optional live regression. Launch more simultaneous requests than the old
# burst=20 policy allowed and require every authenticated response to succeed.
if [ -n "${REGISTRY_BEARER_TOKEN:-}" ] && [ -n "${REGISTRY_BLOB_URL:-}" ]; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT HUP INT TERM
    pids=""
    i=1
    while [ "$i" -le 32 ]; do
        curl -sS -o /dev/null -w '%{http_code}\n' \
            -H "Authorization: Bearer $REGISTRY_BEARER_TOKEN" \
            "$REGISTRY_BLOB_URL" >"$tmp/$i" &
        pids="$pids $!"
        i=$((i + 1))
    done
    for pid in $pids; do wait "$pid"; done
    if grep -qv '^200$' "$tmp"/*; then
        echo "FAIL: concurrent Registry requests did not all return 200" >&2
        grep -H . "$tmp"/* >&2
        exit 1
    fi
fi

echo "PASS: Registry /v2/ uses connection protection without request-rate limiting"
