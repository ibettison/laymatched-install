import os
import subprocess
import unittest
from pathlib import Path


class CrossRepositoryContractTests(unittest.TestCase):
    def test_application_pins_and_reads_authoritative_installer_fixture(self):
        installer = Path(__file__).parents[1]
        application = Path(os.getenv("LAYMATCHED_APP_REPO", installer.parent / "laymatched-betting"))
        if not application.is_dir():
            self.skipTest("layMatchedBetting sibling checkout is not available")
        authoritative = installer / "contracts/local-activation/fixtures/state-v1-installed.json"
        pinned = application / "backend/tests/fixtures/installer-state-v1.json"
        self.assertEqual(pinned.read_bytes(), authoritative.read_bytes())
        authoritative_schema = installer / "contracts/local-activation/state-v1.schema.json"
        pinned_schema = application / "backend/app/contracts/local_activation_state_v1.schema.json"
        self.assertEqual(pinned_schema.read_bytes(), authoritative_schema.read_bytes())
        script = (
            "from pathlib import Path; "
            "from app.activation_state import read_activation_status; "
            "value=read_activation_status(Path(__import__('sys').argv[1])); "
            "assert value['schema_version']==1 and value['stage']=='installed'"
        )
        temporary = installer / ".cross-repo-state.json"
        try:
            temporary.write_bytes(authoritative.read_bytes())
            temporary.chmod(0o600)
            subprocess.run(
                [str(application / "backend/.venv/bin/python"), "-c", script, str(temporary)],
                cwd=application / "backend",
                env={**os.environ, "PYTHONPATH": str(application / "backend")},
                check=True,
            )
        finally:
            temporary.unlink(missing_ok=True)
