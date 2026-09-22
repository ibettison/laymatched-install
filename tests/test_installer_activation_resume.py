import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.local_activation import Journal


ROOT = Path(__file__).parents[1]


class InstallerActivationResumeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.state_dir = Path(self.temporary.name) / "activation"

    def tearDown(self):
        self.temporary.cleanup()

    def _advance_function(self):
        installer = (ROOT / "install.sh").read_text()
        match = re.search(r"(?ms)^advance_activation_to\(\) \{\n.*?^\}", installer)
        self.assertIsNotNone(match, "installer's monotonic activation helper is missing")
        return match.group()

    def _run_transitions(self, stages):
        script = (
            f'ACTIVATION_STATE_DIR={self.state_dir!s}\n'
            f'LOCAL_ACTIVATION_HELPER={ROOT / "tools/local_activation.py"}\n'
            f'{self._advance_function()}\n'
            + "\n".join(f"advance_activation_to {stage}" for stage in stages)
        )
        return subprocess.run(
            ["bash", "-c", script], capture_output=True, text=True,
            env={**os.environ, "LAYMATCHED_ALLOW_NON_ROOT_TEST": "1"}, check=False,
        )

    def test_fresh_install_advances_through_reservation_stages(self):
        Journal(self.state_dir).init("installation-1")
        result = self._run_transitions(("authorized", "nickname_reserved", "dns_pending"))
        self.assertEqual(result.returncode, 0, result.stderr)
        state = Journal(self.state_dir).read()
        self.assertEqual(state["stage"], "dns_pending")
        self.assertEqual(state["revision"], 4)

    def test_dns_pending_resume_skips_completed_transitions_and_advances_forward(self):
        journal = Journal(self.state_dir)
        journal.init("installation-1")
        journal.advance("authorized")
        journal.advance("nickname_reserved")
        journal.advance("dns_pending")
        revision = journal.read()["revision"]

        result = self._run_transitions(("authorized", "nickname_reserved", "dns_pending", "dns_ready"))
        self.assertEqual(result.returncode, 0, result.stderr)
        state = journal.read()
        self.assertEqual(state["stage"], "dns_ready")
        self.assertEqual(state["revision"], revision + 1)

    def test_later_stage_retry_does_not_move_activation_backwards(self):
        journal = Journal(self.state_dir)
        journal.init("installation-1")
        for stage in ("authorized", "nickname_reserved", "dns_pending", "dns_ready", "https_pending", "profile_pending", "mfa_pending", "active"):
            journal.advance(stage)

        result = self._run_transitions(("authorized", "nickname_reserved", "dns_pending", "dns_ready", "https_pending", "profile_pending", "mfa_pending", "active"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(journal.read()["stage"], "active")

    def test_retry_reuses_existing_activation_session_instead_of_bootstrapping_again(self):
        installer = (ROOT / "install.sh").read_text()
        resume_guard = installer.index('if [ -f "$ACTIVATION_STATE_DIR/session.json" ]; then')
        bootstrap_call = installer.index("run_central_activation_bootstrap", resume_guard)
        missing_session_guard = installer.index('if [ "$current_stage" != "installed" ]; then', resume_guard)
        self.assertLess(resume_guard, missing_session_guard)
        self.assertLess(missing_session_guard, bootstrap_call)
        self.assertIn("refusing to create another activation", installer[missing_session_guard:bootstrap_call])


if __name__ == "__main__":
    unittest.main()
