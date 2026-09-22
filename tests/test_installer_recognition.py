import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TEST_TOKEN = "installer-test-token-not-for-output"


def extract_bash_function(script: str, function_name: str) -> str:
    start = script.index(f"{function_name}() {{")
    end = script.index("\n}\n", start) + 2
    return script[start:end]


class InstallerRecognitionTests(unittest.TestCase):
    def run_case(self, fake_status: int):
        with tempfile.TemporaryDirectory(prefix="laymatched-recognition-") as temporary:
            directory = Path(temporary)
            fake_bin = directory / "bin"
            fake_bin.mkdir()
            fake_python = fake_bin / "python3"
            fake_python.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' \"$@\" > \"$FAKE_ARGV_FILE\"\n"
                "exit \"$FAKE_STATUS\"\n"
            )
            fake_python.chmod(0o755)
            argv_file = directory / "argv"
            harness = directory / "harness.sh"
            function = extract_bash_function(
                (ROOT / "install.sh").read_text(), "run_central_activation_bootstrap"
            )
            harness.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "RED=''; GREEN=''; YELLOW=''; NC=''\n"
                "log_warn() { printf '%s\\n' \"$1\"; }\n"
                "log_error() { printf '%s\\n' \"$1\"; exit 1; }\n"
                "ACTIVATION_SERVICE_URL='https://central.example.test'\n"
                "INSTALLER_TOKEN='installer-test-token-not-for-output'\n"
                "AUTH_API_URL='https://auth.example.test/installer/authorize'\n"
                "ACTIVATION_STATE_DIR='/var/lib/laymatched/activation'\n"
                "APP_VERSION='v0.1.1'\n"
                + function
                + "\nrun_central_activation_bootstrap\n"
            )
            harness.chmod(0o755)
            environment = os.environ.copy()
            environment.update(
                {
                    "PATH": f"{fake_bin}{os.pathsep}{environment['PATH']}",
                    "FAKE_ARGV_FILE": str(argv_file),
                    "FAKE_STATUS": str(fake_status),
                }
            )
            result = subprocess.run(
                ["bash", str(harness)],
                capture_output=True,
                text=True,
                env=environment,
                check=False,
            )
            return result, argv_file.read_text().splitlines()

    def test_global_options_precede_bootstrap_and_local_argument_failure_is_distinct(self):
        result, argv = self.run_case(2)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(
            argv,
            [
                "/opt/laymatched/provisioning-current/recognition_client.py",
                "--central-url",
                "https://central.example.test",
                "--state-dir",
                "/var/lib/laymatched/activation",
                "--app-version",
                "v0.1.1",
                "bootstrap",
                "--auth-url",
                "https://auth.example.test/activation/assertions",
            ],
        )
        self.assertIn("failed locally", result.stdout)
        self.assertIn("central authentication was not attempted", result.stdout)
        self.assertNotIn("Central recognition unavailable", result.stdout)
        self.assertNotIn(TEST_TOKEN, result.stdout + result.stderr)

    def test_non_argument_failure_keeps_central_unavailable_message(self):
        result, _ = self.run_case(1)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Central activation could not authenticate", result.stdout)
        self.assertNotIn("central authentication was not attempted", result.stdout)
        self.assertNotIn(TEST_TOKEN, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
