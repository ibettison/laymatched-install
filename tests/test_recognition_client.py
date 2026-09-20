import base64
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tools import recognition_client
from tools.local_activation import Journal, KeyService


class RecognitionClientTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name) / "activation"
        Journal(self.directory).init("11111111-1111-4111-8111-111111111111")
        KeyService(self.directory).ensure()

    def tearDown(self):
        self.temp.cleanup()

    def test_bootstrap_sends_assertion_to_central_and_persists_only_session_state(self):
        responses = [
            {"assertion": "signed-assertion", "expires_in": 600},
            {"activation_id": "22222222-2222-4222-8222-222222222222", "access_token": "central-session", "expires_in": 900},
        ]
        with patch.object(recognition_client, "_post", side_effect=responses) as post, patch("sys.stdin.read", return_value="installer-secret"):
            args = type("Args", (), {"state_dir": self.directory, "auth_url": "https://auth/activation/assertions", "central_url": "https://central", "app_version": "v1.2.3"})
            self.assertEqual(recognition_client.bootstrap(args), 0)
        self.assertEqual(post.call_args_list[0].args[1]["installation_id"], "11111111-1111-4111-8111-111111111111")
        self.assertEqual(post.call_args_list[1].args[2]["Authorization"], "Bearer signed-assertion")
        saved = json.loads((self.directory / "session.json").read_text())
        self.assertEqual(saved["access_token"], "central-session")
        self.assertNotIn("installer-secret", (self.directory / "session.json").read_text())

    def test_offline_heartbeat_is_queued_without_secret_logging_or_data_loss(self):
        (self.directory / "session.json").write_text(json.dumps({"activation_id": "22222222-2222-4222-8222-222222222222", "access_token": "central-session"}))
        args = type("Args", (), {"state_dir": self.directory, "central_url": "https://central", "app_version": "v1.2.3", "service_status": "healthy"})
        with patch.object(recognition_client, "_post", side_effect=OSError("offline")):
            self.assertEqual(recognition_client.heartbeat(args), 75)
        queued = json.loads((self.directory / "heartbeat-outbox.json").read_text())
        self.assertEqual(queued[0]["body"]["installation_id"], "11111111-1111-4111-8111-111111111111")
        self.assertNotIn("central-session", (self.directory / "heartbeat-outbox.json").read_text())

    def test_heartbeat_retries_queued_and_current_request_idempotently(self):
        (self.directory / "session.json").write_text(json.dumps({"activation_id": "22222222-2222-4222-8222-222222222222", "access_token": "central-session"}))
        (self.directory / "heartbeat-outbox.json").write_text(json.dumps([{"body": {"installation_id": "11111111-1111-4111-8111-111111111111", "app_version": "v1.2.2", "service_status": "degraded"}, "idempotency_key": "old-key"}]))
        args = type("Args", (), {"state_dir": self.directory, "central_url": "https://central", "app_version": "v1.2.3", "service_status": "healthy"})
        with patch.object(recognition_client, "_post", return_value={}) as post:
            self.assertEqual(recognition_client.heartbeat(args), 0)
        self.assertEqual(post.call_count, 2)
        self.assertFalse((self.directory / "heartbeat-outbox.json").exists())


if __name__ == "__main__":
    unittest.main()
