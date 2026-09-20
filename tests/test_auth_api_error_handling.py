import os
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
TEST_TOKEN = "lm_inst_test_only_redaction_check"


def extract_bash_function(script_path: Path, function_name: str) -> str:
    source = script_path.read_text()
    start = source.index(f"{function_name}() {{")
    end = source.index("\n}\n", start) + 2
    return source[start:end]


class AuthAPIErrorHandlingTests(unittest.TestCase):
    @staticmethod
    def response_directories():
        return {
            path
            for path in Path("/tmp").glob("laymatched-auth-response.*")
            if path.is_dir()
        }

    @staticmethod
    def response_files():
        return {
            path
            for path in Path("/tmp").glob("laymatched-auth-response.*/response.json")
            if path.is_file()
        }

    def assert_no_new_response_paths(self, before_dirs, before_files):
        leaked_dirs = self.response_directories() - before_dirs
        leaked_files = self.response_files() - before_files
        if leaked_dirs or leaked_files:
            for path in leaked_dirs:
                shutil.rmtree(path, ignore_errors=True)
            for path in leaked_files:
                path.unlink(missing_ok=True)
            self.fail("authorization response file survived cleanup")

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
if [ "${FAKE_CURL_MODE:-}" = "interrupt" ]; then
    printf '{"installer_token":"%s"}' "$FAKE_TOKEN" > "$output_file"
    trap 'exit 143' HUP INT TERM
    while :; do sleep 1; done
fi
printf '{"installer_token":"%s"}' "$FAKE_TOKEN" > "$output_file"
printf '%s' "${FAKE_CURL_STATUS}"
"""
            )
            fake_curl.chmod(0o755)

            harness = temp_path / "harness.sh"
            script_path = REPOSITORY_ROOT / script_name
            function_text = "\n\n".join(
                extract_bash_function(script_path, function_name)
                for function_name in (
                    "cleanup_auth_response",
                    "auth_response_signal_exit",
                    "call_auth_api",
                )
            )
            harness.write_text(
                """#!/usr/bin/env bash
set -euo pipefail
RED=''; GREEN=''; YELLOW=''; NC=''
AUTH_RESPONSE_DIR=''
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
            environment["FAKE_TOKEN"] = TEST_TOKEN
            response_dirs_before = self.response_directories()
            response_files_before = self.response_files()

            if mode == "interrupt":
                process = subprocess.Popen(
                    ["bash", str(harness)],
                    start_new_session=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    env=environment,
                )
                try:
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        if self.response_files() - response_files_before:
                            break
                        if process.poll() is not None:
                            break
                        time.sleep(0.01)
                    os.killpg(process.pid, signal.SIGTERM)
                    stdout, stderr = process.communicate(timeout=10)
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.communicate(timeout=10)
                result_code = process.returncode
                combined_output = stdout + stderr
            else:
                result = subprocess.run(
                    ["bash", str(harness)],
                    capture_output=True,
                    text=True,
                    env=environment,
                    timeout=30,
                    check=False,
                )
                result_code = result.returncode
                combined_output = result.stdout + result.stderr

            self.assert_no_new_response_paths(
                response_dirs_before, response_files_before
            )
            self.assertNotEqual(result_code, 0)
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

    def test_installer_and_updater_clean_invalid_success_response(self):
        for script_name in ("install.sh", "update.sh"):
            with self.subTest(script=script_name):
                output = self.run_case(script_name, "http", "200")
                self.assertIn("Invalid response from authorization service", output)

    def test_installer_and_updater_report_connection_failure_without_token_disclosure(self):
        for script_name in ("install.sh", "update.sh"):
            with self.subTest(script=script_name):
                output = self.run_case(script_name, "connection")
                self.assertIn("Failed to contact LayMatched authorization service", output)

    def test_installer_and_updater_clean_response_file_on_interruption(self):
        for script_name in ("install.sh", "update.sh"):
            with self.subTest(script=script_name):
                self.run_case(script_name, "interrupt")


if __name__ == "__main__":
    unittest.main()
