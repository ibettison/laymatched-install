import json
import os
import re
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts/ensure-mfa-encryption-key.sh"


def key_from(env_file: Path) -> str:
    matches = re.findall(r"^AUTH_MFA_ENCRYPTION_KEY=(.*)$", env_file.read_text(), re.MULTILINE)
    if len(matches) != 1:
        raise AssertionError(f"expected one MFA key, found {len(matches)}")
    return matches[0]


def run_helper(env_file: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(HELPER), str(env_file)],
        capture_output=True,
        text=True,
        check=False,
    )


def update_function() -> str:
    script = (ROOT / "update.sh").read_text()
    match = re.search(
        r"(ensure_mfa_encryption_key\(\) \{.*?\n\})\n\n# BEGIN EPHEMERAL DOCKER AUTH",
        script,
        re.DOTALL,
    )
    if not match:
        raise AssertionError("update MFA helper function not found")
    return match.group(1)


class MfaEncryptionKeyTests(unittest.TestCase):
    def test_fresh_key_is_generated_once_with_private_permissions_and_no_secret_log(self):
        with tempfile.TemporaryDirectory() as directory:
            env_file = Path(directory) / ".env"
            env_file.write_text("APP_VERSION=v1.0.0\n")
            first = run_helper(env_file)
            self.assertEqual(first.returncode, 0, first.stderr)
            first_key = key_from(env_file)
            self.assertRegex(first_key, r"^[A-Za-z0-9_-]{32,}$")
            self.assertEqual(stat.S_IMODE(env_file.stat().st_mode), 0o600)
            self.assertNotIn(first_key, first.stdout + first.stderr)

            second = run_helper(env_file)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(key_from(env_file), first_key)
            self.assertNotIn(first_key, second.stdout + second.stderr)

    def test_existing_key_is_preserved_and_permissions_are_hardened(self):
        existing_key = "existing-mfa-key-0123456789-abcdefghijklmnopqrstuvwxyz"
        with tempfile.TemporaryDirectory() as directory:
            env_file = Path(directory) / ".env"
            env_file.write_text(f"APP_VERSION=v1.0.0\nAUTH_MFA_ENCRYPTION_KEY={existing_key}\n")
            env_file.chmod(0o644)
            result = run_helper(env_file)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(key_from(env_file), existing_key)
            self.assertEqual(stat.S_IMODE(env_file.stat().st_mode), 0o600)
            self.assertNotIn(existing_key, result.stdout + result.stderr)

    def test_malformed_and_duplicate_keys_fail_closed_without_replacement(self):
        cases = (
            "AUTH_MFA_ENCRYPTION_KEY=too-short",
            "AUTH_MFA_ENCRYPTION_KEY=first-valid-key-0123456789-abcdefghijklmnopqrstuvwxyz\n"
            "AUTH_MFA_ENCRYPTION_KEY=second-valid-key-0123456789-abcdefghijklmnopqrstuvwxyz",
            "AUTH_MFA_ENCRYPTION_KEY = too-short",
            "export AUTH_MFA_ENCRYPTION_KEY=exported-key-0123456789-abcdefghijklmnopqrstuvwxyz",
        )
        for contents in cases:
            with self.subTest(contents=contents), tempfile.TemporaryDirectory() as directory:
                env_file = Path(directory) / ".env"
                env_file.write_text(contents + "\n")
                before = env_file.read_text()
                result = run_helper(env_file)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(env_file.read_text(), before)
                self.assertNotIn("first-valid-key", result.stdout + result.stderr)
                self.assertNotIn("second-valid-key", result.stdout + result.stderr)

    def test_legacy_update_fallback_generates_and_preserves_key(self):
        function = update_function()
        with tempfile.TemporaryDirectory() as directory:
            env_file = Path(directory) / ".env"
            env_file.write_text("APP_VERSION=v1.0.0\n")
            shell = f"MFA_KEY_HELPER=/path/that-does-not-exist\n{function}\nensure_mfa_encryption_key \"$1\""
            first = subprocess.run(
                ["bash", "-s", str(env_file)],
                input=shell,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(first.returncode, 0, first.stderr)
            first_key = key_from(env_file)

            second = subprocess.run(
                ["bash", "-s", str(env_file)],
                input=shell,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(key_from(env_file), first_key)
            self.assertNotIn(first_key, first.stdout + first.stderr + second.stdout + second.stderr)

    def test_every_generated_customer_compose_path_passes_key_only_to_api(self):
        scripts = (ROOT / "install.sh", ROOT / "update.sh")
        documents = []
        for script in scripts:
            documents.extend(
                re.findall(
                    r"cat > /opt/laymatched/docker-compose\.yml <<'COMPOSE_EOF'\n(.*?)\nCOMPOSE_EOF",
                    script.read_text(),
                    re.DOTALL,
                )
            )
        self.assertEqual(len(documents), 3)
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            env_file = project / ".env"
            key = "compose-test-mfa-key-0123456789-abcdefghijklmnopqrstuvwxyz"
            env_file.write_text(
                "\n".join(
                    (
                        "REGISTRY_URL=registry.example",
                        "APP_VERSION=v1.0.0",
                        "POSTGRES_PASSWORD=postgres-test-password",
                        "AUTH_USERNAME=test-user",
                        "AUTH_PASSWORD_HASH=test-hash",
                        "AUTH_SESSION_SECRET=session-test-secret",
                        f"AUTH_MFA_ENCRYPTION_KEY={key}",
                        "COMMUNITY_INSTALLATION_KEY=installation-test-key",
                        "COMMUNITY_ATTRIBUTION_SECRET=attribution-test-secret",
                        "",
                    )
                )
            )
            for index, document in enumerate(documents):
                compose_file = project / f"docker-compose-{index}.yml"
                compose_file.write_text(document)
                result = subprocess.run(
                    [
                        "docker",
                        "compose",
                        "--project-directory",
                        str(project),
                        "-f",
                        str(compose_file),
                        "config",
                        "--format",
                        "json",
                    ],
                    env={key: value for key, value in os.environ.items() if key != "AUTH_MFA_ENCRYPTION_KEY"},
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                rendered = json.loads(result.stdout)
                api_env = rendered["services"]["api"]["environment"]
                self.assertEqual(api_env["AUTH_MFA_ENCRYPTION_KEY"], key)
                for service_name in ("db", "web"):
                    service_env = rendered["services"][service_name].get("environment", {})
                    self.assertNotIn("AUTH_MFA_ENCRYPTION_KEY", service_env)


if __name__ == "__main__":
    unittest.main()
