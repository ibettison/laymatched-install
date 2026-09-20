import base64
import json
import os
import tempfile
import unittest
import time
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
        (self.directory / "session.json").write_text(json.dumps({"activation_id": "22222222-2222-4222-8222-222222222222", "access_token": "central-session", "expires_at": int(time.time()) + 900}))
        args = type("Args", (), {"state_dir": self.directory, "central_url": "https://central", "app_version": "v1.2.3", "service_status": "healthy"})
        with patch.object(recognition_client, "_post", side_effect=OSError("offline")):
            self.assertEqual(recognition_client.heartbeat(args), 75)
        queued = json.loads((self.directory / "heartbeat-outbox.json").read_text())
        self.assertEqual(queued[0]["body"]["installation_id"], "11111111-1111-4111-8111-111111111111")
        self.assertNotIn("central-session", (self.directory / "heartbeat-outbox.json").read_text())

    def test_heartbeat_retries_queued_and_current_request_idempotently(self):
        (self.directory / "session.json").write_text(json.dumps({"activation_id": "22222222-2222-4222-8222-222222222222", "access_token": "central-session", "expires_at": int(time.time()) + 900}))
        (self.directory / "heartbeat-outbox.json").write_text(json.dumps([{"body": {"installation_id": "11111111-1111-4111-8111-111111111111", "app_version": "v1.2.2", "service_status": "degraded"}, "idempotency_key": "old-key"}]))
        args = type("Args", (), {"state_dir": self.directory, "central_url": "https://central", "app_version": "v1.2.3", "service_status": "healthy"})
        with patch.object(recognition_client, "_post", return_value={}) as post:
            self.assertEqual(recognition_client.heartbeat(args), 0)
        self.assertEqual(post.call_count, 2)
        self.assertFalse((self.directory / "heartbeat-outbox.json").exists())

    def test_expired_session_resumes_before_heartbeat_and_uses_new_token(self):
        (self.directory / "session.json").write_text(json.dumps({"activation_id": "22222222-2222-4222-8222-222222222222", "access_token": "expired-session", "expires_at": int(time.time()) - 1}))
        args = type("Args", (), {"state_dir": self.directory, "central_url": "https://central", "app_version": "v1.2.3", "service_status": "healthy"})
        responses = [{"activation_id": "22222222-2222-4222-8222-222222222222", "access_token": "refreshed-session", "expires_in": 900}, {}]
        with patch.object(recognition_client, "_post", side_effect=responses) as post:
            self.assertEqual(recognition_client.heartbeat(args), 0)
        self.assertEqual(post.call_args_list[0].args[0], "https://central/v1/activation-sessions")
        self.assertEqual(post.call_args_list[1].args[2]["Authorization"], "Bearer refreshed-session")

    def test_expired_token_response_resumes_and_retries_same_idempotency_key(self):
        (self.directory / "session.json").write_text(json.dumps({"activation_id": "22222222-2222-4222-8222-222222222222", "access_token": "expired-session", "expires_at": int(time.time()) + 900}))
        args = type("Args", (), {"state_dir": self.directory, "central_url": "https://central", "app_version": "v1.2.3", "service_status": "healthy"})
        with patch.object(recognition_client, "_post", side_effect=[recognition_client.RecognitionHTTPError(401), {"activation_id": "22222222-2222-4222-8222-222222222222", "access_token": "refreshed-session", "expires_in": 900}, {}]) as post:
            self.assertEqual(recognition_client.heartbeat(args), 0)
        self.assertEqual(post.call_args_list[0].args[2]["Authorization"], "Bearer expired-session")
        self.assertEqual(post.call_args_list[2].args[2]["Authorization"], "Bearer refreshed-session")
        self.assertEqual(post.call_args_list[0].args[2]["Idempotency-Key"], post.call_args_list[2].args[2]["Idempotency-Key"])

    def test_partial_delivery_persists_only_unsent_entries_with_stable_keys(self):
        (self.directory / "session.json").write_text(json.dumps({"activation_id": "22222222-2222-4222-8222-222222222222", "access_token": "central-session", "expires_at": int(time.time()) + 900}))
        (self.directory / "heartbeat-outbox.json").write_text(json.dumps([
            {"body": {"installation_id": "11111111-1111-4111-8111-111111111111", "app_version": "v1.2.2", "service_status": "degraded"}, "idempotency_key": "first-key"},
            {"body": {"installation_id": "11111111-1111-4111-8111-111111111111", "app_version": "v1.2.1", "service_status": "unknown"}, "idempotency_key": "second-key"},
        ]))
        args = type("Args", (), {"state_dir": self.directory, "central_url": "https://central", "app_version": "v1.2.3", "service_status": "healthy"})
        with patch.object(recognition_client, "_post", side_effect=[{}, OSError("interrupted")]) as post:
            self.assertEqual(recognition_client.heartbeat(args), 75)
        remaining = json.loads((self.directory / "heartbeat-outbox.json").read_text())
        self.assertEqual(remaining[0]["idempotency_key"], "second-key")
        self.assertNotEqual(remaining[1]["idempotency_key"], "second-key")

    def test_acknowledgement_interruption_leaves_same_entry_for_duplicate_retry(self):
        (self.directory / "session.json").write_text(json.dumps({"activation_id": "22222222-2222-4222-8222-222222222222", "access_token": "central-session", "expires_at": int(time.time()) + 900}))
        args = type("Args", (), {"state_dir": self.directory, "central_url": "https://central", "app_version": "v1.2.3", "service_status": "healthy"})
        original_unlink = os.unlink
        def interrupt_after_ack(path, *args, **kwargs):
            if str(path).endswith("heartbeat-outbox.json"):
                raise OSError("interrupted after acknowledgement")
            return original_unlink(path, *args, **kwargs)
        with patch.object(os, "unlink", side_effect=interrupt_after_ack), patch.object(recognition_client, "_post", return_value={}) as post:
            with self.assertRaises(OSError):
                recognition_client.heartbeat(args)
        first_key = post.call_args.args[2]["Idempotency-Key"]
        with patch.object(recognition_client, "_post", return_value={}) as retry:
            self.assertEqual(recognition_client.heartbeat(args), 0)
        self.assertEqual(retry.call_args_list[0].args[2]["Idempotency-Key"], first_key)


if __name__ == "__main__":
    unittest.main()
