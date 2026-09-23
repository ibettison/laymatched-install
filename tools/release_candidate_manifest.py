#!/usr/bin/env python3
"""Validate an immutable Release Candidate manifest for the customer installer."""

import json
import re
import sys
from pathlib import Path


VERSION = re.compile(r"v[0-9]+\.[0-9]+\.[0-9]+-rc\.[1-9][0-9]*\Z")
FINAL_VERSION = re.compile(r"v[0-9]+\.[0-9]+\.[0-9]+\Z")
SOURCE_SHA = re.compile(r"[0-9a-f]{40}\Z")
IMAGE_DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
REGISTRY = re.compile(r"[A-Za-z0-9.-]+(?::[0-9]+)?\Z")


def validate(path: Path, expected_registry: str) -> tuple[str, str, str, str]:
    item = json.loads(path.read_text())
    version = item.get("candidate_version", "")
    release_version = item.get("release_version", "")
    source_sha = item.get("source_sha", "")
    api_digest = item.get("api_image_digest", "")
    web_digest = item.get("web_image_digest", "")
    registry = item.get("registry_url", "")
    if not VERSION.fullmatch(version):
        raise ValueError("candidate_version must be vMAJOR.MINOR.PATCH-rc.N")
    if not FINAL_VERSION.fullmatch(release_version):
        raise ValueError("release_version must be vMAJOR.MINOR.PATCH")
    if version.rsplit("-rc.", 1)[0] != release_version:
        raise ValueError("candidate_version does not belong to release_version")
    if not SOURCE_SHA.fullmatch(source_sha):
        raise ValueError("source_sha must be a 40-character lowercase SHA")
    if not IMAGE_DIGEST.fullmatch(api_digest) or not IMAGE_DIGEST.fullmatch(web_digest):
        raise ValueError("API and web image digests must be sha256 digests")
    if not REGISTRY.fullmatch(expected_registry) or registry != expected_registry:
        raise ValueError("candidate registry does not match authorization service")
    expected_api = f"{registry}/laymatched-api-staging@{api_digest}"
    expected_web = f"{registry}/laymatched-web-staging@{web_digest}"
    if item.get("api_image") != expected_api or item.get("web_image") != expected_web:
        raise ValueError("candidate image references do not match the manifest digests")
    return version, source_sha, api_digest, web_digest


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: release_candidate_manifest.py MANIFEST REGISTRY", file=sys.stderr)
        return 2
    try:
        values = validate(Path(sys.argv[1]), sys.argv[2])
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"Invalid release candidate manifest: {exc}", file=sys.stderr)
        return 1
    print("\t".join(values))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
