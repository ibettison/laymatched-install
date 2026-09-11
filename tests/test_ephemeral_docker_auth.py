import subprocess
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = (REPOSITORY_ROOT / "install.sh", REPOSITORY_ROOT / "update.sh")


def auth_block(script: Path) -> str:
    content = script.read_text()
    start_marker = "# BEGIN EPHEMERAL DOCKER AUTH"
    end_marker = "# END EPHEMERAL DOCKER AUTH"
    start = content.index(start_marker)
    end = content.index(end_marker, start) + len(end_marker)
    return content[start:end]


class EphemeralDockerAuthTest(unittest.TestCase):
    def run_cleanup_case(self, script: Path, exit_mode: str) -> None:
        shell = (
            auth_block(script)
            + "\n"
            + "install_ephemeral_docker_auth_traps\n"
            + "setup_ephemeral_docker_auth\n"
            + "printf '%s\\n' \"$DOCKER_CONFIG\"\n"
            + "printf 'installer-token-must-not-survive' > \"$DOCKER_CONFIG/config.json\"\n"
            + exit_mode
            + "\n"
        )
        result = subprocess.run(
            ["bash", "-c", shell], capture_output=True, text=True, check=False
        )
        self.assertTrue(result.stdout.strip(), result.stderr)
        config_dir = Path(result.stdout.strip().splitlines()[0])
        expected_code = 0 if exit_mode == "exit 0" else 17 if exit_mode == "exit 17" else 143
        self.assertEqual(result.returncode, expected_code, result.stderr)
        self.assertFalse(config_dir.exists(), f"credential directory survived: {config_dir}")

    def test_success_failure_and_interrupt_remove_ephemeral_credentials(self):
        for script in SCRIPTS:
            with self.subTest(script=script.name, result="success"):
                self.run_cleanup_case(script, "exit 0")
            with self.subTest(script=script.name, result="failure"):
                self.run_cleanup_case(script, "exit 17")
            with self.subTest(script=script.name, result="interrupt"):
                self.run_cleanup_case(script, "kill -TERM $$")

    def test_scripts_use_restricted_temporary_docker_config(self):
        for script in SCRIPTS:
            block = auth_block(script)
            self.assertIn("mktemp -d /tmp/laymatched-docker-config.XXXXXX", block)
            self.assertIn('chmod 700 "$EPHEMERAL_DOCKER_CONFIG_DIR"', block)
            self.assertIn('export DOCKER_CONFIG="$EPHEMERAL_DOCKER_CONFIG_DIR"', block)
            self.assertIn("trap cleanup_ephemeral_docker_auth EXIT", block)
            self.assertIn("unset DOCKER_CONFIG", block)


if __name__ == "__main__":
    unittest.main()
