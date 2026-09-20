#!/usr/bin/env bash
set -euo pipefail

env_file="${1:?environment file is required}"
[ -f "$env_file" ] || { echo "Environment file is missing." >&2; exit 1; }

# Treat whitespace around the assignment as the same setting so an unsafe
# legacy edit cannot be silently shadowed by a newly generated value.
if grep -Eq '^[[:space:]]*export[[:space:]]+AUTH_MFA_ENCRYPTION_KEY[[:space:]]*=' "$env_file"; then
    echo "AUTH_MFA_ENCRYPTION_KEY uses an unsupported assignment form." >&2
    exit 1
fi
key_lines="$(grep -nE '^[[:space:]]*AUTH_MFA_ENCRYPTION_KEY[[:space:]]*=' "$env_file" || true)"
key_count=0
if [ -n "$key_lines" ]; then
    key_count="$(printf '%s\n' "$key_lines" | wc -l | tr -d ' ')"
fi

if [ "$key_count" -gt 1 ]; then
    echo "AUTH_MFA_ENCRYPTION_KEY is defined more than once." >&2
    exit 1
fi

if [ "$key_count" -eq 1 ]; then
    key="$(printf '%s\n' "$key_lines" | sed -E 's/^[0-9]+:[[:space:]]*AUTH_MFA_ENCRYPTION_KEY[[:space:]]*=[[:space:]]*//')"
    if ! printf '%s' "$key" | grep -Eq '^[A-Za-z0-9_-]{32,}$'; then
        echo "AUTH_MFA_ENCRYPTION_KEY is malformed." >&2
        exit 1
    fi
    unset key
    chmod 600 "$env_file"
    exit 0
fi

chmod 600 "$env_file"
umask 077
command -v openssl >/dev/null 2>&1 || {
    echo "OpenSSL is required to generate the MFA encryption key." >&2
    exit 1
}
key="$(openssl rand -hex 32)" || {
    echo "Could not generate MFA encryption key." >&2
    exit 1
}
printf '\nAUTH_MFA_ENCRYPTION_KEY=%s\n' "$key" >> "$env_file"
unset key
chmod 600 "$env_file"
