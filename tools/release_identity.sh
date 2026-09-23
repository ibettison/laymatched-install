#!/usr/bin/env bash

# Set an approved digest pin only when the authorization response contains the
# complete release identity. Legacy releases with no manifest use version tags;
# partial identity data is rejected rather than mixed with an older pin.
set_approved_release_image_refs() {
    API_IMAGE_REF=""
    WEB_IMAGE_REF=""
    RELEASE_SOURCE_SHA=""

    if [ -z "${APPROVED_SOURCE_SHA:-}" ] \
        && [ -z "${API_IMAGE_DIGEST:-}" ] \
        && [ -z "${WEB_IMAGE_DIGEST:-}" ]; then
        return 0
    fi
    [[ "${APPROVED_SOURCE_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || return 1
    [[ "${API_IMAGE_DIGEST:-}" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
    [[ "${WEB_IMAGE_DIGEST:-}" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
    [ -n "${REGISTRY_URL:-}" ] || return 1

    API_IMAGE_REF="${REGISTRY_URL}/laymatched-api@${API_IMAGE_DIGEST}"
    WEB_IMAGE_REF="${REGISTRY_URL}/laymatched-web@${WEB_IMAGE_DIGEST}"
    RELEASE_SOURCE_SHA="$APPROVED_SOURCE_SHA"
}

# Atomically replace the release identity fields together so APP_VERSION can
# never be persisted with stale API/web refs or a stale source SHA.
write_release_identity_env() {
    local env_file="$1" version="$2" registry="$3" api_ref="$4" web_ref="$5" source_sha="$6"
    python3 - "$env_file" "$version" "$registry" "$api_ref" "$web_ref" "$source_sha" <<'PY'
import os
import re
import stat
import sys
import tempfile

path, version, registry, api_ref, web_ref, source_sha = sys.argv[1:]
if not re.fullmatch(r"v\d+\.\d+\.\d+(?:-rc\.\d+)?", version):
    raise SystemExit("invalid release version")
if not re.fullmatch(r"[A-Za-z0-9.-]+(?::[0-9]+)?", registry):
    raise SystemExit("invalid release registry")
if source_sha and not re.fullmatch(r"[0-9a-f]{40}", source_sha):
    raise SystemExit("invalid release source SHA")
if api_ref or web_ref or source_sha:
    if not source_sha or not re.fullmatch(r"sha256:[0-9a-f]{64}", api_ref.rsplit("@", 1)[-1]):
        raise SystemExit("incomplete API release identity")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", web_ref.rsplit("@", 1)[-1]):
        raise SystemExit("incomplete web release identity")
    if not re.fullmatch(re.escape(registry) + r"/laymatched-api(?:-staging)?@sha256:[0-9a-f]{64}", api_ref):
        raise SystemExit("API release ref does not match registry")
    if not re.fullmatch(re.escape(registry) + r"/laymatched-web(?:-staging)?@sha256:[0-9a-f]{64}", web_ref):
        raise SystemExit("web release ref does not match registry")

keys = {
    "APP_VERSION": version,
    "REGISTRY_URL": registry,
    "API_IMAGE_REF": api_ref,
    "WEB_IMAGE_REF": web_ref,
    "RELEASE_SOURCE_SHA": source_sha,
}
with open(path, "r", encoding="utf-8") as handle:
    lines = handle.readlines()
seen = set()
for line in lines:
    key = line.partition("=")[0]
    if key in keys:
        if key in seen:
            raise SystemExit(f"duplicate release identity field: {key}")
        seen.add(key)
for key in keys.keys() - seen:
    lines.append(f"{key}={keys[key]}\n")
lines = [f"{line.partition('=')[0]}={keys[line.partition('=')[0]]}\n"
         if line.partition("=")[0] in keys else line for line in lines]

metadata = os.stat(path)
fd, temporary = tempfile.mkstemp(prefix=".release-identity.", dir=os.path.dirname(path) or ".")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.writelines(lines)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, stat.S_IMODE(metadata.st_mode))
    try:
        os.chown(temporary, metadata.st_uid, metadata.st_gid)
    except PermissionError:
        pass
    os.replace(temporary, path)
    directory = os.open(os.path.dirname(path) or ".", os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

verify_release_image_identity() {
    if [ -z "${RELEASE_SOURCE_SHA:-}" ]; then
        [ -z "${API_IMAGE_REF:-}" ] && [ -z "${WEB_IMAGE_REF:-}" ]
        return
    fi
    [[ "${RELEASE_SOURCE_SHA}" =~ ^[0-9a-f]{40}$ ]] || return 1
    [[ "${API_IMAGE_REF:-}" =~ ^[^[:space:]]+/laymatched-api(-staging)?@sha256:[0-9a-f]{64}$ ]] || return 1
    [[ "${WEB_IMAGE_REF:-}" =~ ^[^[:space:]]+/laymatched-web(-staging)?@sha256:[0-9a-f]{64}$ ]] || return 1
    local api_source_sha web_source_sha
    api_source_sha=$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$API_IMAGE_REF") || return 1
    web_source_sha=$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$WEB_IMAGE_REF") || return 1
    [ "$api_source_sha" = "$RELEASE_SOURCE_SHA" ] && [ "$web_source_sha" = "$RELEASE_SOURCE_SHA" ]
}

prepare_release_compose() {
    local env_file="$1" compose_file="$2"
    python3 - "$env_file" "${APP_VERSION:-}" "${REGISTRY_URL:-}" \
        "${API_IMAGE_REF:-}" "${WEB_IMAGE_REF:-}" "${RELEASE_SOURCE_SHA:-}" <<'PY' || return 1
import sys
path, *expected = sys.argv[1:]
keys = ("APP_VERSION", "REGISTRY_URL", "API_IMAGE_REF", "WEB_IMAGE_REF", "RELEASE_SOURCE_SHA")
values = {}
with open(path, encoding="utf-8") as handle:
    for line in handle:
        key, sep, value = line.rstrip("\n").partition("=")
        if sep and key in keys:
            if key in values:
                raise SystemExit(f"duplicate release identity field: {key}")
            values[key] = value
if [values.get(key, "") for key in keys] != expected:
    raise SystemExit("Compose environment does not match the selected release identity")
PY
    docker compose --env-file "$env_file" -f "$compose_file" pull || return 1
    verify_release_image_identity || return 1
}

start_release_compose() {
    local env_file="$1" compose_file="$2"
    docker compose --env-file "$env_file" -f "$compose_file" up -d
}

deploy_release_compose() {
    local env_file="$1" compose_file="$2"
    prepare_release_compose "$env_file" "$compose_file" || return 1
    start_release_compose "$env_file" "$compose_file"
}
