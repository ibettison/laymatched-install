#!/usr/bin/env python3
"""Fail-closed proof that an RC install is paused at the MFA handoff."""
import json
import re
import sys
from pathlib import Path

from release_candidate_manifest import validate


def env_values(path):
    values = {}
    for line in path.read_text().splitlines():
        key, sep, value = line.partition("=")
        if sep:
            if key in values:
                raise ValueError(f"duplicate {key}")
            values[key] = value
    return values


def prove(candidate, saved_candidate, env_path, installation_id_path, state_path, session_path):
    env = env_values(env_path)
    registry = env.get("REGISTRY_URL", "")
    selected = validate(candidate, registry)
    saved = validate(saved_candidate, registry)
    if selected != saved:
        raise ValueError("candidate differs from the interrupted installation")
    version, source, api_digest, web_digest = selected
    expected = {
        "APP_VERSION": version,
        "RELEASE_SOURCE_SHA": source,
        "API_IMAGE_REF": f"{registry}/laymatched-api-staging@{api_digest}",
        "WEB_IMAGE_REF": f"{registry}/laymatched-web-staging@{web_digest}",
    }
    if any(env.get(key) != value for key, value in expected.items()):
        raise ValueError("stored release identity does not match candidate")
    if not env.get("ACTIVATION_SERVICE_URL", "").startswith("https://"):
        raise ValueError("activation service identity is missing")
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{1,30}[a-z0-9])?", env.get("CUSTOMER_NICKNAME", "")):
        raise ValueError("customer nickname is missing")
    hostname = env.get("CUSTOMER_HOSTNAME", "")
    if hostname != env["CUSTOMER_NICKNAME"] + ".matched.laysports.co.uk":
        raise ValueError("customer hostname does not match installation configuration")
    installation_id = installation_id_path.read_text().strip()
    if not re.fullmatch(r"[0-9a-fA-F-]{36}", installation_id):
        raise ValueError("installation ID is invalid")
    state = json.loads(state_path.read_text())
    required = {"schema_version", "installation_id", "stage", "revision", "updated_at", "last_error"}
    if set(state) != required or state["schema_version"] != 1:
        raise ValueError("activation journal schema is invalid")
    if state["installation_id"] != installation_id:
        raise ValueError("activation journal belongs to a different installation")
    if state["stage"] != "profile_pending" or not isinstance(state["revision"], int):
        raise ValueError("installation is not paused at the MFA handoff")
    if not session_path.is_file():
        raise ValueError("central activation session is missing")
    session = json.loads(session_path.read_text())
    if not isinstance(session.get("activation_id"), str) or not session["activation_id"]:
        raise ValueError("central activation session is invalid")


def main():
    if len(sys.argv) != 7:
        return 2
    try:
        prove(*(Path(value) for value in sys.argv[1:]))
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        print(f"RC resume rejected: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
