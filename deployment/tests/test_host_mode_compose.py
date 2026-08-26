import copy
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


DEPLOYMENT_DIR = Path(__file__).resolve().parents[1]
COMPOSE_FILES = (
    DEPLOYMENT_DIR / "docker-compose-bootstrap.yml",
    DEPLOYMENT_DIR / "docker-compose-production.yml",
)


def render_compose(path: Path) -> dict:
    result = subprocess.run(
        ["docker", "compose", "-f", str(path), "config", "--format", "json"],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


class HostModeComposeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.configs = [render_compose(path) for path in COMPOSE_FILES]

    def test_ports_are_loopback_only(self):
        expected = {
            "auth-api": (8443, "8443"),
            "registry": (5000, "5000"),
        }
        for config in self.configs:
            for service_name, (target, published) in expected.items():
                ports = config["services"][service_name]["ports"]
                self.assertEqual(len(ports), 1)
                self.assertEqual(ports[0]["host_ip"], "127.0.0.1")
                self.assertEqual(ports[0]["target"], target)
                self.assertEqual(ports[0]["published"], published)

    def test_services_keep_internal_network_and_gain_host_access_bridge(self):
        for config in self.configs:
            self.assertTrue(config["networks"]["laymatched-internal"]["internal"])
            self.assertFalse(
                config["networks"]["laymatched-host-access"].get("internal", False)
            )
            for service_name in ("auth-api", "registry"):
                self.assertEqual(
                    set(config["services"][service_name]["networks"]),
                    {"laymatched-internal", "laymatched-host-access"},
                )

    def test_rendered_healthcheck_preserves_runtime_shell_variable(self):
        for config in self.configs:
            command = config["services"]["registry"]["healthcheck"]["test"][3]
            self.assertIn('echo "$$output"', command)
            self.assertNotIn('echo ""', command)

    def test_registry_healthcheck_accepts_401_without_headers_and_200(self):
        for config in self.configs:
            self.assertEqual(
                self.run_healthcheck(config, "HTTP/1.1 401 Unauthorized", 1), 0
            )
            self.assertEqual(self.run_healthcheck(config, "HTTP/1.1 200 OK", 0), 0)

    def test_registry_healthcheck_fails_when_unreachable(self):
        for config in self.configs:
            self.assertNotEqual(
                self.run_healthcheck(config, "wget: can't connect to remote host", 1),
                0,
            )

    def test_bootstrap_and_production_are_structurally_aligned(self):
        bootstrap, production = copy.deepcopy(self.configs)
        for config in (bootstrap, production):
            config["services"]["auth-api"]["image"] = "AUTH_IMAGE"
            config["services"]["registry"]["image"] = "REGISTRY_IMAGE"
        self.assertEqual(bootstrap, production)

    @staticmethod
    def run_healthcheck(config: dict, wget_output: str, wget_status: int) -> int:
        rendered = config["services"]["registry"]["healthcheck"]["test"][3]
        runtime_command = rendered.replace("$$", "$")
        with tempfile.TemporaryDirectory() as temp_dir:
            fake_wget = Path(temp_dir) / "wget"
            fake_wget.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$FAKE_WGET_OUTPUT" >&2\n'
                'exit "$FAKE_WGET_STATUS"\n'
            )
            fake_wget.chmod(0o755)
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{temp_dir}:{env['PATH']}",
                    "FAKE_WGET_OUTPUT": wget_output,
                    "FAKE_WGET_STATUS": str(wget_status),
                }
            )
            return subprocess.run(["sh", "-c", runtime_command], env=env).returncode


if __name__ == "__main__":
    unittest.main()
