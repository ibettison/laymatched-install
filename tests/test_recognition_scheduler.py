import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]


class RecognitionSchedulerTests(unittest.TestCase):
    def _source(self, name):
        return (ROOT / name).read_text()

    def _runner_block(self, source):
        start_marker = "cat > /opt/laymatched/recognition-heartbeat.sh <<'HEARTBEAT_RUNNER_EOF'\n"
        start = source.index(start_marker) + len(start_marker)
        end = source.index("HEARTBEAT_RUNNER_EOF\n", start)
        return source[start:end]

    def test_install_and_update_maintain_the_same_timer_contract(self):
        install = self._source("install.sh")
        update = self._source("update.sh")
        for source in (install, update):
            self.assertIn("install_recognition_scheduler", source)
            self.assertIn("systemctl daemon-reload", source)
            self.assertIn("systemctl enable --now laymatched-recognition-heartbeat.timer", source)
            self.assertIn("chmod 600 \"$config_file\"", source)
            self.assertIn("OnBootSec=2min", source)
            self.assertIn("OnUnitActiveSec=5min", source)
            self.assertIn("Persistent=true", source)
            self.assertIn("RandomizedDelaySec=30s", source)
            self.assertIn("SuccessExitStatus=0 75", source)
            self.assertIn("flock -n -E 75", source)
        self.assertLess(
            update.index('log_info "docker-compose.yml regenerated'),
            update.rindex("\ninstall_recognition_scheduler\n"),
        )

    def test_runner_uses_only_local_status_and_approved_client_arguments(self):
        for name in ("install.sh", "update.sh"):
            runner = self._runner_block(self._source(name))
            self.assertIn("/etc/laymatched/recognition.env", runner)
            self.assertIn("/opt/laymatched/.env", runner)
            self.assertIn("docker inspect", runner)
            self.assertIn("http://*|https://*", runner)
            self.assertIn("grep -q '[[:space:]]'", runner)
            self.assertIn("--state-dir \"$STATE_DIR\"", runner)
            self.assertIn("--central-url \"$central_url\"", runner)
            self.assertIn("--app-version \"$app_version\"", runner)
            self.assertIn("--service-status \"$service_status\"", runner)
            self.assertNotIn("INSTALLER_TOKEN", runner)
            self.assertNotIn("AUTH_SESSION_SECRET", runner)
            self.assertNotIn("password", runner.lower())

    def test_central_url_is_preserved_and_rejected_when_unsafe(self):
        for name in ("install.sh", "update.sh"):
            source = self._source(name)
            self.assertIn('central_url="${ACTIVATION_SERVICE_URL:-}"', source)
            self.assertIn('central_url="$existing_url"', source)
            self.assertIn("http://*|https://*", source)
            self.assertIn("grep -q '[[:space:]]'", source)


if __name__ == "__main__":
    unittest.main()
