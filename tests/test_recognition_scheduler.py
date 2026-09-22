import fcntl
import os
import shutil
import subprocess
import tempfile
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
            self.assertNotIn("SuccessExitStatus=0 75", source)
            self.assertIn("flock -n -E 76", source)
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

    def test_acceptance_runbook_uses_pr_head_and_distinguishes_failures(self):
        runbook = (ROOT / "docs/recognition-acceptance-runbook.md").read_text()
        self.assertIn("git fetch origin pull/29/head", runbook)
        self.assertNotIn("git checkout a7498984ab65e83f16bf4ed37f843662e036dc3c", runbook)
        self.assertIn("ExecMainStatus=75", runbook)
        self.assertIn("ExecMainStatus=76", runbook)
        self.assertIn("ACTIVATION_STALE_AFTER_SECONDS", runbook)

    def test_runtime_exit_codes_distinguish_delivery_lock_and_recovery(self):
        source = self._source("install.sh")
        runner = self._runner_block(source)
        with tempfile.TemporaryDirectory(prefix="laymatched-scheduler-") as directory_name:
            directory = Path(directory_name)
            config = directory / "recognition.env"
            config.write_text("ACTIVATION_SERVICE_URL=http://central.test\n")
            app_env = directory / "app.env"
            app_env.write_text("APP_VERSION=v1.2.3\n")
            state_dir = directory / "activation"
            state_dir.mkdir()
            lock = directory / "heartbeat.lock"
            fake_client = directory / "fake_client.py"
            fake_client.write_text(
                "import os\n"
                "raise SystemExit(int(os.environ['FAKE_RESULT']))\n"
            )
            fake_docker = directory / "docker"
            fake_docker.write_text("#!/bin/sh\nexit 0\n")
            fake_docker.chmod(0o755)
            runner_path = directory / "runner.sh"
            runner_path.write_text(
                runner
                .replace("/etc/laymatched/recognition.env", str(config))
                .replace("/opt/laymatched/.env", str(app_env))
                .replace("/var/lib/laymatched/activation", str(state_dir))
                .replace("/run/laymatched-recognition-heartbeat.lock", str(lock))
                .replace(
                    "/usr/bin/python3 /opt/laymatched/provisioning-current/recognition_client.py",
                    f"/usr/bin/python3 {fake_client}",
                )
            )
            runner_path.chmod(0o755)
            environment = {
                **os.environ,
                "PATH": f"{directory}:{os.environ['PATH']}",
            }

            def run(result):
                return subprocess.run(
                    [str(runner_path)],
                    env={**environment, "FAKE_RESULT": str(result)},
                    capture_output=True,
                    text=True,
                    check=False,
                )

            self.assertEqual(run(0).returncode, 0)
            self.assertEqual(run(75).returncode, 75)
            with lock.open("w") as handle:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.assertEqual(run(0).returncode, 76)
                fcntl.flock(handle, fcntl.LOCK_UN)
            self.assertEqual(run(0).returncode, 0)

    @unittest.skipUnless(shutil.which("systemd-analyze"), "systemd-analyze is unavailable")
    def test_unit_files_parse_with_systemd_analyze(self):
        source = self._source("install.sh")
        service_start = source.index("cat > /etc/systemd/system/laymatched-recognition-heartbeat.service")
        service_body_start = source.index("\n", source.index("HEARTBEAT_SERVICE_EOF", service_start)) + 1
        service_end = source.index("HEARTBEAT_SERVICE_EOF\n", service_body_start)
        timer_start = source.index("cat > /etc/systemd/system/laymatched-recognition-heartbeat.timer")
        timer_body_start = source.index("\n", source.index("HEARTBEAT_TIMER_EOF", timer_start)) + 1
        timer_end = source.index("HEARTBEAT_TIMER_EOF\n", timer_body_start)
        with tempfile.TemporaryDirectory(prefix="laymatched-systemd-") as directory_name:
            directory = Path(directory_name)
            service = directory / "laymatched-recognition-heartbeat.service"
            timer = directory / "laymatched-recognition-heartbeat.timer"
            service.write_text(source[service_body_start:service_end].replace(
                "ExecStart=/opt/laymatched/recognition-heartbeat.sh",
                "ExecStart=/usr/bin/true",
            ))
            timer.write_text(source[timer_body_start:timer_end])
            result = subprocess.run(
                ["systemd-analyze", "verify", str(service), str(timer)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
