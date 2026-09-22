import base64
import io
import json
import os
import sys
import tempfile
import unittest
import time
import urllib.error
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

    def test_version_conflict_is_explicitly_retryable(self):
        error = recognition_client.RecognitionHTTPError(409)
        self.assertEqual(error.status, 409)
        self.assertIn("fetch current activation status", str(error))

    def test_transient_central_failure_is_retried_but_terminal_http_failure_is_not(self):
        calls = []
        with patch.object(recognition_client.time, "sleep") as sleep, \
             patch.object(recognition_client.time, "monotonic", side_effect=[0, 0]):
            result = recognition_client._call_with_retries(
                "central test", lambda: calls.append(1) or ({} if len(calls) == 2 else (_ for _ in ()).throw(OSError("offline"))),
                deadline=10,
            )
        self.assertEqual(result, {})
        self.assertEqual(len(calls), 2)
        sleep.assert_called_once()

        with self.assertRaises(recognition_client.RecognitionHTTPError):
            recognition_client._call_with_retries(
                "central test", lambda: (_ for _ in ()).throw(recognition_client.RecognitionHTTPError(422)),
                deadline=10,
            )

    def test_retry_exhaustion_reports_final_http_status(self):
        with self.assertRaisesRegex(RuntimeError, r"central test .*\(HTTP 503\)") as raised:
            recognition_client._call_with_retries(
                "central test", lambda: (_ for _ in ()).throw(recognition_client.RecognitionHTTPError(503)),
                deadline=0,
            )
        logged = io.StringIO()
        with patch("sys.stderr", logged):
            print(f"central recognition error: {raised.exception}", file=sys.stderr)
        self.assertIn("HTTP 503", logged.getvalue())

    def test_retry_exhaustion_reports_connection_category_without_exception_details(self):
        sensitive = "https://installer:secret@example.test/path assertion=installer-assertion headers={'Authorization': 'Bearer token'} body=response-secret"
        with self.assertRaisesRegex(RuntimeError, r"central test .*\(connection failure\)") as raised:
            recognition_client._call_with_retries(
                "central test", lambda: (_ for _ in ()).throw(urllib.error.URLError(sensitive)),
                deadline=0,
            )
        logged = io.StringIO()
        with patch("sys.stderr", logged):
            print(f"central recognition error: {raised.exception}", file=sys.stderr)
        self.assertIn("connection failure", logged.getvalue())
        self.assertNotIn("installer:secret", logged.getvalue())
        self.assertNotIn("installer-assertion", logged.getvalue())
        self.assertNotIn("Authorization", logged.getvalue())
        self.assertNotIn("response-secret", logged.getvalue())

    def test_dns_failed_status_is_retryable_only_with_central_retry_after(self):
        retryable = recognition_client._reservation_from_status({
            "reservation_id": "r", "nickname": "winning-way", "hostname": "winning-way.matched.laysports.co.uk",
            "dns": {"status": "failed", "retry_after": 5}, "reservation_expires_at": None,
        })
        terminal = recognition_client._reservation_from_status({
            "reservation_id": "r", "nickname": "winning-way", "hostname": "winning-way.matched.laysports.co.uk",
            "dns": {"status": "failed", "retry_after": None}, "reservation_expires_at": None,
        })
        self.assertEqual(retryable["status"], "dns_failed")
        self.assertEqual(retryable["retry_after"], 5)
        self.assertEqual(terminal["status"], "dns_failed")
        self.assertIsNone(terminal["retry_after"])

    def test_hostname_reservation_retry_reuses_existing_activation_reservation(self):
        (self.directory / "session.json").write_text(json.dumps({
            "activation_id": "22222222-2222-4222-8222-222222222222",
            "access_token": "central-session", "expires_at": int(time.time()) + 900,
        }))
        args = type("Args", (), {
            "state_dir": self.directory, "central_url": "https://central", "nickname": "winning-way",
            "public_ipv4": "203.0.113.10", "challenge_root": self.directory / "challenge", "wait_seconds": 1,
        })
        status = {
            "reservation_id": "33333333-3333-4333-8333-333333333333",
            "nickname": "winning-way", "hostname": "winning-way.matched.laysports.co.uk",
            "dns": {"status": "ready", "retry_after": None}, "reservation_expires_at": None,
            "network_challenge": None,
        }
        with patch.object(recognition_client, "_ensure_session", return_value=json.loads((self.directory / "session.json").read_text())), \
             patch.object(recognition_client, "_status", return_value=status), \
             patch.object(recognition_client, "_request_authenticated") as authenticated:
            self.assertEqual(recognition_client.reserve_hostname(args), 0)
        authenticated.assert_not_called()
        saved = json.loads((self.directory / "hostname.json").read_text())
        self.assertEqual(saved["reservation_id"], status["reservation_id"])
        self.assertEqual(saved["hostname"], status["hostname"])

    def test_hostname_reservation_retry_rejects_a_different_nickname(self):
        (self.directory / "session.json").write_text(json.dumps({
            "activation_id": "22222222-2222-4222-8222-222222222222",
            "access_token": "central-session", "expires_at": int(time.time()) + 900,
        }))
        args = type("Args", (), {
            "state_dir": self.directory, "central_url": "https://central", "nickname": "another-customer",
            "public_ipv4": "203.0.113.10", "challenge_root": self.directory / "challenge", "wait_seconds": 1,
        })
        status = {"reservation_id": "existing", "nickname": "winning-way", "hostname": "winning-way.matched.laysports.co.uk"}
        with patch.object(recognition_client, "_ensure_session", return_value=json.loads((self.directory / "session.json").read_text())), \
             patch.object(recognition_client, "_status", return_value=status), \
             patch.object(recognition_client, "_request_authenticated") as authenticated:
            with self.assertRaisesRegex(RuntimeError, "does not match"):
                recognition_client.reserve_hostname(args)
        authenticated.assert_not_called()

    def test_hostname_reservation_retry_rejects_hostname_inconsistent_with_nickname(self):
        (self.directory / "session.json").write_text(json.dumps({
            "activation_id": "22222222-2222-4222-8222-222222222222",
            "access_token": "central-session", "expires_at": int(time.time()) + 900,
        }))
        args = type("Args", (), {
            "state_dir": self.directory, "central_url": "https://central", "nickname": "winning-way",
            "public_ipv4": "203.0.113.10", "challenge_root": self.directory / "challenge", "wait_seconds": 1,
        })
        status = {
            "reservation_id": "existing", "nickname": "winning-way",
            "hostname": "different-customer.matched.laysports.co.uk",
        }
        with patch.object(recognition_client, "_ensure_session", return_value=json.loads((self.directory / "session.json").read_text())), \
             patch.object(recognition_client, "_status", return_value=status), \
             patch.object(recognition_client, "_request_authenticated") as authenticated:
            with self.assertRaisesRegex(RuntimeError, "does not match"):
                recognition_client.reserve_hostname(args)
        authenticated.assert_not_called()

    def test_mfa_report_reads_verified_state_from_customer_api_database(self):
        session = {"activation_id": "22222222-2222-4222-8222-222222222222", "access_token": "central-session", "version": 4}
        args = type("Args", (), {
            "state_dir": self.directory,
            "central_url": "https://central",
            "app_version": "v1.2.3",
            "compose_dir": str(self.directory),
        })
        local_status = {
            "source": "customer_mfa_database",
            "enabled": True,
            "verified_at": "2026-09-21T12:00:00+00:00",
            "recovery_codes_generated": True,
            "local_security_version": 7,
        }
        with patch.object(recognition_client, "_state_and_session", return_value=(
            {"installation_id": "11111111-1111-4111-8111-111111111111"}, session
        )), patch.object(recognition_client, "_status", return_value={"version": 4}), \
             patch.object(recognition_client.subprocess, "run", return_value=type("Completed", (), {"stdout": json.dumps(local_status)})()), \
             patch.object(recognition_client, "_request_authenticated", return_value=({}, session)) as request:
            self.assertEqual(recognition_client.report_mfa(args), 0)
        self.assertEqual(request.call_args.kwargs["body"], {
            "enabled": True,
            "method": "totp",
            "verified_at": local_status["verified_at"],
            "recovery_codes_generated": True,
            "local_security_version": 7,
        })

    def test_mfa_report_rejects_unverified_local_state(self):
        session = {"activation_id": "22222222-2222-4222-8222-222222222222", "access_token": "central-session", "version": 4}
        args = type("Args", (), {
            "state_dir": self.directory,
            "central_url": "https://central",
            "app_version": "v1.2.3",
            "compose_dir": str(self.directory),
        })
        with patch.object(recognition_client, "_state_and_session", return_value=(
            {"installation_id": "11111111-1111-4111-8111-111111111111"}, session
        )), patch.object(recognition_client, "_status", return_value={"version": 4}), \
             patch.object(recognition_client.subprocess, "run", return_value=type("Completed", (), {
                 "stdout": json.dumps({"source": "customer_mfa_database", "enabled": False})
             })()):
            with self.assertRaisesRegex(RuntimeError, "verified enrolment ceremony"):
                recognition_client.report_mfa(args)

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
