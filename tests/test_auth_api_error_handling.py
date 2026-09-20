import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
TEST_TOKEN = "lm_inst_test_only_redaction_check"


def extract_call_auth_api(script_path: Path) -> str:
    source = script_path.read_text()
    start = source.index("call_auth_api() {")
    end = source.index("\n}\n\n#", start) + 2
    return source[start:end]


class AuthAPIErrorHandlingTests(unittest.TestCase):
    def run_case(self, script_name: str, mode: str, status: str = "") -> str:
        with tempfile.TemporaryDirectory(prefix="laymatched-auth-errors-") as temp_dir:
            temp_path = Path(temp_dir)
            fake_bin = temp_path / "bin"
            fake_bin.mkdir()
            fake_curl = fake_bin / "curl"
            fake_curl.write_text(
                """#!/bin/sh
output_file=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) output_file="$2"; shift 2 ;;
        *) shift ;;
    esac
done
if [ "${FAKE_CURL_MODE:-}" = "connection" ]; then
    exit 7
fi
printf '%s' '{"error":"invalid credentials"}' > "$output_file"
printf '%s' "${FAKE_CURL_STATUS}"
"""
            )
            fake_curl.chmod(0o755)

            harness = temp_path / "harness.sh"
            function_text = extract_call_auth_api(REPOSITORY_ROOT / script_name)
            harness.write_text(
                """#!/usr/bin/env bash
set -euo pipefail
RED=''; GREEN=''; YELLOW=''; NC=''
log_info() { printf '%s\\n' "$1"; }
log_error() { printf '%s\\n' "$1"; exit 1; }
validate_version() {
    case "$1" in *[![:alnum:]._-]*|"") return 1 ;; *) return 0 ;; esac
}
validate_registry_url() {
    case "$1" in *[![:alnum:].:-]*|"") return 1 ;; *) return 0 ;; esac
}
AUTH_API_URL='http://auth.test.invalid/installer/authorize'
"""
                + function_text
                + f"\ncall_auth_api '{TEST_TOKEN}'\n"
            )
            harness.chmod(0o755)

            environment = os.environ.copy()
            environment["PATH"] = str(fake_bin) + os.pathsep + environment["PATH"]
            environment["FAKE_CURL_MODE"] = mode
            environment["FAKE_CURL_STATUS"] = status
            result = subprocess.run(
                ["bash", str(harness)],
                capture_output=True,
                text=True,
                env=environment,
                timeout=30,
                check=False,
            )

            combined_output = result.stdout + result.stderr
            self.assertNotEqual(result.returncode, 0)
            if TEST_TOKEN in combined_output:
                self.fail("authorization error output disclosed the token")
            return combined_output

    def test_installer_and_updater_reject_401_without_token_disclosure(self):
        for script_name in ("install.sh", "update.sh"):
            with self.subTest(script=script_name):
                output = self.run_case(script_name, "http", "401")
                self.assertIn("HTTP 401", output)

    def test_installer_and_updater_report_5xx_without_token_disclosure(self):
        for script_name in ("install.sh", "update.sh"):
            with self.subTest(script=script_name):
                output = self.run_case(script_name, "http", "503")
                self.assertIn("HTTP 503", output)

    def test_installer_and_updater_report_connection_failure_without_token_disclosure(self):
        for script_name in ("install.sh", "update.sh"):
            with self.subTest(script=script_name):
                output = self.run_case(script_name, "connection")
                self.assertIn("Failed to contact LayMatched authorization service", output)


if __name__ == "__main__":
    unittest.main()
