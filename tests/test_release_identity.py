import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "tools/release_identity.sh"
REGISTRY = "registry.matched.laysports.co.uk"
OLD_SHA = "1" * 40
NEW_SHA = "2" * 40
OLD_API = f"{REGISTRY}/laymatched-api@sha256:{'a' * 64}"
OLD_WEB = f"{REGISTRY}/laymatched-web@sha256:{'b' * 64}"
NEW_API = f"{REGISTRY}/laymatched-api@sha256:{'c' * 64}"
NEW_WEB = f"{REGISTRY}/laymatched-web@sha256:{'d' * 64}"


def _run_shell(script: str, *, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-c", script], cwd=ROOT, env={**os.environ, **(env or {})},
        capture_output=True, text=True, check=False,
    )


class ReleaseIdentityTests(unittest.TestCase):
    def test_approved_identity_rejects_partial_metadata_and_clears_old_refs(self) -> None:
        result = _run_shell(f"""
source '{HELPER}'
REGISTRY_URL='{REGISTRY}'
API_IMAGE_REF='{OLD_API}'
WEB_IMAGE_REF='{OLD_WEB}'
RELEASE_SOURCE_SHA='{OLD_SHA}'
APPROVED_SOURCE_SHA='{NEW_SHA}'
API_IMAGE_DIGEST='sha256:{'c' * 64}'
WEB_IMAGE_DIGEST=''
if set_approved_release_image_refs; then exit 10; fi
test -z "$API_IMAGE_REF" && test -z "$WEB_IMAGE_REF" && test -z "$RELEASE_SOURCE_SHA"
APPROVED_SOURCE_SHA=''
API_IMAGE_DIGEST=''
WEB_IMAGE_DIGEST=''
set_approved_release_image_refs
test -z "$API_IMAGE_REF" && test -z "$WEB_IMAGE_REF" && test -z "$RELEASE_SOURCE_SHA"
"""
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_release_candidate_staging_digests_remain_valid(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            env_file = Path(temporary) / ".env"
            env_file.write_text("APP_VERSION=v0.1.1\nREGISTRY_URL=" + REGISTRY + "\n")
            candidate_api = NEW_API.replace("laymatched-api@", "laymatched-api-staging@")
            candidate_web = NEW_WEB.replace("laymatched-web@", "laymatched-web-staging@")
            result = _run_shell(
                f"source '{HELPER}'; write_release_identity_env '{env_file}' v0.2.0-rc.1 "
                f"{REGISTRY} {candidate_api} {candidate_web} {NEW_SHA}"
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            values = dict(line.split("=", 1) for line in env_file.read_text().splitlines())
            self.assertEqual(values["APP_VERSION"], "v0.2.0-rc.1")
            self.assertEqual(values["API_IMAGE_REF"], candidate_api)
            self.assertEqual(values["WEB_IMAGE_REF"], candidate_web)
            self.assertEqual(values["RELEASE_SOURCE_SHA"], NEW_SHA)


    def test_rerun_persists_and_resumes_the_exact_new_release_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            tmp_path = Path(temporary)
            install_root = tmp_path / "install"
            bin_dir = tmp_path / "bin"
            install_root.mkdir()
            bin_dir.mkdir()
            env_file = install_root / ".env"
            candidate_file = install_root / ".env.candidate"
            compose_file = install_root / "docker-compose.yml"
            compose_file.write_text("services: {}\n")
            env_file.write_text(
                f"APP_VERSION=v0.1.1\nREGISTRY_URL={REGISTRY}\n"
                f"API_IMAGE_REF={OLD_API}\nWEB_IMAGE_REF={OLD_WEB}\nRELEASE_SOURCE_SHA={OLD_SHA}\n"
            )
            candidate_file.write_text(env_file.read_text())
            calls_file = tmp_path / "compose-calls.txt"
            docker = bin_dir / "docker"
            docker.write_text(
        """#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = image ] && [ "$2" = inspect ]; then
  case "${@: -1}" in
    *laymatched-api@*|*laymatched-web@*) printf '%s\\n' "$EXPECTED_SOURCE_SHA" ;;
    *) exit 4 ;;
  esac
  exit 0
fi
if [ "$1" = compose ]; then
  env_file=""
  action=""
  for ((i=1; i<=$#; i++)); do
    arg="${!i}"
    if [ "$arg" = --env-file ]; then j=$((i+1)); env_file="${!j}"; fi
    if [ "$arg" = pull ] || [ "$arg" = up ]; then action="$arg"; fi
  done
  value() { sed -n "s/^$1=//p" "$env_file"; }
  printf '%s|%s|%s|%s|%s|%s\\n' "$action" "$(value APP_VERSION)" \\
    "$(value API_IMAGE_REF)" "$(value WEB_IMAGE_REF)" "$(value RELEASE_SOURCE_SHA)" \\
    "$(value REGISTRY_URL)" >> "$DOCKER_CALL_LOG"
  exit 0
fi
exit 9
"""
            )
            docker.chmod(0o755)
            script = f"""
source '{HELPER}'
REGISTRY_URL='{REGISTRY}'
APPROVED_VERSION=v0.2.0
APPROVED_SOURCE_SHA='{NEW_SHA}'
API_IMAGE_DIGEST="sha256:{'c' * 64}"
WEB_IMAGE_DIGEST="sha256:{'d' * 64}"
set_approved_release_image_refs
APP_VERSION="$APPROVED_VERSION"
write_release_identity_env '{candidate_file}' "$APP_VERSION" "$REGISTRY_URL" "$API_IMAGE_REF" "$WEB_IMAGE_REF" "$RELEASE_SOURCE_SHA"
deploy_release_compose '{candidate_file}' '{compose_file}'
write_release_identity_env '{env_file}' "$APP_VERSION" "$REGISTRY_URL" "$API_IMAGE_REF" "$WEB_IMAGE_REF" "$RELEASE_SOURCE_SHA"

# Simulate a later updater process resuming from its persisted environment.
APP_VERSION=$(sed -n 's/^APP_VERSION=//p' '{env_file}')
REGISTRY_URL=$(sed -n 's/^REGISTRY_URL=//p' '{env_file}')
API_IMAGE_REF=$(sed -n 's/^API_IMAGE_REF=//p' '{env_file}')
WEB_IMAGE_REF=$(sed -n 's/^WEB_IMAGE_REF=//p' '{env_file}')
RELEASE_SOURCE_SHA=$(sed -n 's/^RELEASE_SOURCE_SHA=//p' '{env_file}')
APPROVED_SOURCE_SHA='{NEW_SHA}'
API_IMAGE_DIGEST="sha256:{'c' * 64}"
WEB_IMAGE_DIGEST="sha256:{'d' * 64}"
set_approved_release_image_refs
test "$API_IMAGE_REF" = "{NEW_API}"
test "$WEB_IMAGE_REF" = "{NEW_WEB}"
test "$RELEASE_SOURCE_SHA" = '{NEW_SHA}'
write_release_identity_env '{candidate_file}' "$APP_VERSION" "$REGISTRY_URL" "$API_IMAGE_REF" "$WEB_IMAGE_REF" "$RELEASE_SOURCE_SHA"
deploy_release_compose '{candidate_file}' '{compose_file}'
"""
            result = _run_shell(
                script,
                env={
                    "PATH": f"{bin_dir}:{os.environ['PATH']}",
                    "DOCKER_CALL_LOG": str(calls_file),
                    "EXPECTED_SOURCE_SHA": NEW_SHA,
                },
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            persisted = dict(line.split("=", 1) for line in env_file.read_text().splitlines())
            self.assertEqual(persisted, {
                "APP_VERSION": "v0.2.0",
                "REGISTRY_URL": REGISTRY,
                "API_IMAGE_REF": NEW_API,
                "WEB_IMAGE_REF": NEW_WEB,
                "RELEASE_SOURCE_SHA": NEW_SHA,
            })
            self.assertEqual(calls_file.read_text().splitlines(), [
                f"pull|v0.2.0|{NEW_API}|{NEW_WEB}|{NEW_SHA}|{REGISTRY}",
                f"up|v0.2.0|{NEW_API}|{NEW_WEB}|{NEW_SHA}|{REGISTRY}",
            ] * 2)


    def test_installer_and_updater_use_shared_identity_deploy_path(self) -> None:
        installer = (ROOT / "install.sh").read_text()
        updater = (ROOT / "update.sh").read_text()
        self.assertIn('source "$SCRIPT_DIR/tools/release_identity.sh"', installer)
        self.assertIn('source "$SCRIPT_DIR/release_identity.sh"', updater)
        for script in (installer, updater):
            self.assertIn("set_approved_release_image_refs", script)
            self.assertIn('write_release_identity_env "$CANDIDATE_ENV_FILE"', script)
            self.assertIn("write_release_identity_env /opt/laymatched/.env", script)
        self.assertIn('deploy_release_compose "$CANDIDATE_ENV_FILE" "$CANDIDATE_COMPOSE_FILE"', installer)
        self.assertIn('prepare_release_compose "$CANDIDATE_ENV_FILE" "$CANDIDATE_COMPOSE_FILE"', updater)
        self.assertIn('start_release_compose "$CANDIDATE_ENV_FILE" "$CANDIDATE_COMPOSE_FILE"', updater)
        self.assertIn('read_release_candidate_manifest "$RELEASE_CANDIDATE_MANIFEST"', installer)
        self.assertIn('Release candidate installation requires a clean customer installation.', installer)
