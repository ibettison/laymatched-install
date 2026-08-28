import json, os, stat, subprocess, tempfile, unittest
from pathlib import Path
from tools.local_activation import Journal, KeyService, StateError

class LocalActivationTests(unittest.TestCase):
    def setUp(self): self.temporary = tempfile.TemporaryDirectory(); self.directory = Path(self.temporary.name) / "activation"
    def tearDown(self): self.temporary.cleanup()
    def test_permissions_idempotent_init_and_reboot_resume(self):
        journal = Journal(self.directory); first = journal.init("installation-1"); self.assertEqual(journal.init("installation-1"), first)
        Journal(self.directory).advance("authorized"); self.assertEqual(Journal(self.directory).read()["stage"], "authorized")
        self.assertEqual(stat.S_IMODE(self.directory.stat().st_mode), 0o700); self.assertEqual(stat.S_IMODE(journal.current.stat().st_mode), 0o600)
    def test_atomic_recovery_uses_previous_complete_revision(self):
        journal = Journal(self.directory); journal.init("installation-1"); journal.advance("authorized"); journal.current.write_text("{power-loss")
        self.assertEqual(journal.read()["stage"], "installed")
    def test_corrupt_state_without_backup_fails_closed(self):
        journal = Journal(self.directory); journal.ensure_directory(); journal.current.write_text("{}")
        with self.assertRaises(StateError): journal.read()
    def test_state_rejects_secrets_and_backwards_progress(self):
        journal = Journal(self.directory); state = journal.init("installation-1")
        with self.assertRaises(StateError): journal.write({**state, "registry_token": "forbidden"})
        journal.advance("authorized")
        with self.assertRaises(StateError): journal.advance("installed")
    def test_ed25519_key_is_stable_private_and_verifiable(self):
        service = KeyService(self.directory); public = service.ensure(); self.assertEqual(service.ensure(), public); self.assertEqual(stat.S_IMODE(service.private.stat().st_mode), 0o600)
        signature = service.sign(b"resume"); signature_path = self.directory / "signature"; signature_path.write_bytes(signature)
        message_path = self.directory / "message"; message_path.write_bytes(b"resume")
        subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", str(service.public), "-rawin", "-in", str(message_path), "-sigfile", str(signature_path)], check=True, capture_output=True)
    def test_key_service_recovers_public_half_of_interrupted_creation(self):
        service = KeyService(self.directory); expected = service.ensure(); service.public.unlink()
        self.assertEqual(KeyService(self.directory).ensure(), expected)
    def test_cli_json_contains_no_secret_material(self):
        env = {**os.environ, "LAYMATCHED_ALLOW_NON_ROOT_TEST": "1"}
        output = subprocess.check_output(["python3", "tools/local_activation.py", "--state-dir", str(self.directory), "init", "installation-1"], cwd=Path(__file__).parents[1], env=env, text=True)
        self.assertEqual(json.loads(output)["stage"], "installed"); self.assertFalse(any(term in output.lower() for term in ("token", "secret", "private", "credential")))

if __name__ == "__main__": unittest.main()
