import base64
import email.message
import hashlib
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

    def test_dns_spinner_uses_braille_frame_and_elapsed_mm_ss(self):
        self.assertEqual(
            recognition_client.DNSWaitSpinner.render_frame(0, 154),
            "⠋ Setting up your LayMatched address... 02:34 elapsed",
        )
        self.assertEqual(recognition_client.DNS_SPINNER_FRAMES, "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

    def test_dns_spinner_is_interactive_only_and_clears_on_success_or_error(self):
        class InteractiveOutput(io.StringIO):
            encoding = "utf-8"

            def isatty(self):
                return True

        noninteractive = io.StringIO()
        with recognition_client.DNSWaitSpinner(noninteractive, started_at=time.monotonic()) as spinner:
            spinner.print_permanent("[WAIT] Still waiting for DNS... 30 seconds elapsed")
        self.assertNotRegex(noninteractive.getvalue(), r"[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]|\\x1b")
        self.assertIn("[WAIT] Still waiting for DNS... 30 seconds elapsed", noninteractive.getvalue())

        for fail in (False, True):
            output = InteractiveOutput()
            with self.subTest(fail=fail):
                if fail:
                    with self.assertRaisesRegex(RuntimeError, "simulated terminal error"):
                        with recognition_client.DNSWaitSpinner(output, started_at=time.monotonic(), interval=0.01) as spinner:
                            spinner.print_permanent("[WAIT] Still waiting for DNS... 30 seconds elapsed")
                            time.sleep(0.025)
                            raise RuntimeError("simulated terminal error")
                else:
                    with recognition_client.DNSWaitSpinner(output, started_at=time.monotonic(), interval=0.01) as spinner:
                        spinner.print_permanent("[WAIT] Still waiting for DNS... 30 seconds elapsed")
                        time.sleep(0.025)
                rendered = output.getvalue()
                self.assertIn("⠋ Setting up your LayMatched address... 00:00 elapsed", rendered)
                self.assertIn("[WAIT] Still waiting for DNS... 30 seconds elapsed", rendered)
                self.assertTrue(rendered.endswith("\r\x1b[2K"))

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

    def test_http_wrappers_retain_only_safe_activation_error_classification(self):
        body_secret = b"response-secret bearer-token signature nonce"
        methods = (recognition_client._get, recognition_client._post,
                   recognition_client._put, recognition_client._patch)
        for wrapper in methods:
            with self.subTest(wrapper=wrapper.__name__):
                headers = email.message.Message()
                headers["X-Activation-Error"] = "invalid_signature"
                response_body = io.BytesIO(body_secret)
                http_error = urllib.error.HTTPError(
                    "https://central.example.test/resource", 401, "rejected", headers, response_body
                )
                with patch.object(recognition_client.urllib.request, "urlopen", side_effect=http_error):
                    with self.assertRaises(recognition_client.RecognitionHTTPError) as raised:
                        if wrapper == recognition_client._get:
                            wrapper("https://central.example.test/resource", {"Authorization": "Bearer request-token"})
                        else:
                            wrapper("https://central.example.test/resource", {}, {"Authorization": "Bearer request-token"})
                error = raised.exception
                self.assertEqual(error.status, 401)
                self.assertEqual(error.activation_error, "invalid_signature")
                self.assertEqual(str(error), "central recognition request failed with HTTP 401 (invalid_signature)")
                self.assertIsNone(error.__cause__)
                self.assertEqual(response_body.tell(), 0)
                for secret in (body_secret.decode(), "Authorization", "Bearer", "request-token", "session-token", "nonce-value"):
                    self.assertNotIn(secret, str(error))

    def test_malformed_and_overlong_activation_error_classifications_are_discarded(self):
        for classification in ("Invalid Signature", "invalid/signature", "invalid_signature\nsecret", "a" * 65):
            with self.subTest(classification=classification):
                headers = email.message.Message()
                headers["X-Activation-Error"] = classification
                http_error = urllib.error.HTTPError(
                    "https://central.example.test/resource", 401, "rejected", headers, io.BytesIO(b"secret body")
                )
                with patch.object(recognition_client.urllib.request, "urlopen", side_effect=http_error):
                    with self.assertRaises(recognition_client.RecognitionHTTPError) as raised:
                        recognition_client._get("https://central.example.test/resource", {})
                self.assertIsNone(raised.exception.activation_error)
                self.assertEqual(str(raised.exception), "central recognition request failed with HTTP 401")
                self.assertNotIn(classification, str(raised.exception))

    def test_mfa_put_uses_expected_path_method_body_and_signing_inputs(self):
        activation_id = "22222222-2222-4222-8222-222222222222"
        session = {"activation_id": activation_id, "access_token": "session-token",
                   "expires_at": int(time.time()) + 900}
        path = f"/v1/activations/{activation_id}/mfa-status"
        body = {"enabled": True, "method": "totp", "verified_at": "2026-09-23T18:19:00Z",
                "recovery_codes_generated": True, "local_security_version": 7}
        encoded = json.dumps(body, separators=(",", ":"), sort_keys=True).encode()
        args = type("Args", (), {"central_url": "https://central"})
        with patch.object(recognition_client, "_put", return_value={}) as put, \
             patch.object(recognition_client, "_canonical_signature", wraps=recognition_client._canonical_signature) as signer:
            result, returned_session = recognition_client._request_authenticated(
                args, self.directory, session, method="PUT", path=path, body=body,
                operation="MFA status", retry_deadline=time.monotonic() + 10,
            )
        self.assertEqual(result, {})
        self.assertIs(returned_session, session)
        self.assertEqual(put.call_args.args[0], f"https://central{path}")
        self.assertEqual(put.call_args.args[1], body)
        request_headers = put.call_args.args[2]
        self.assertEqual(request_headers["Authorization"], "Bearer session-token")
        self.assertEqual(signer.call_args.args[:3], (self.directory, "PUT", path))
        self.assertEqual(signer.call_args.args[3], encoded)
        self.assertEqual(hashlib.sha256(signer.call_args.args[3]).hexdigest(), hashlib.sha256(encoded).hexdigest())

    def test_authenticated_401_still_renews_once_and_reports_final_classification(self):
        activation_id = "22222222-2222-4222-8222-222222222222"
        session = {"activation_id": activation_id, "access_token": "old-session",
                   "expires_at": int(time.time()) + 900}
        refreshed = {"activation_id": activation_id, "access_token": "new-session",
                     "expires_at": int(time.time()) + 900}
        args = type("Args", (), {"central_url": "https://central"})
        with patch.object(recognition_client, "_put", side_effect=[
                recognition_client.RecognitionHTTPError(401, "invalid_signature"),
                recognition_client.RecognitionHTTPError(401, "invalid_credential")]) as put, \
             patch.object(recognition_client, "_resume_session", return_value=refreshed) as resume:
            with self.assertRaises(recognition_client.RecognitionHTTPError) as raised:
                recognition_client._request_authenticated(
                    args, self.directory, session, method="PUT", path="/v1/activations/activation/mfa-status",
                    body={"enabled": True}, operation="MFA status", retry_deadline=time.monotonic() + 10,
                )
        self.assertEqual(put.call_count, 2)
        self.assertEqual(resume.call_count, 1)
        self.assertEqual(put.call_args_list[0].args[2]["Authorization"], "Bearer old-session")
        self.assertEqual(put.call_args_list[1].args[2]["Authorization"], "Bearer new-session")
        self.assertEqual(str(raised.exception), "central recognition request failed with HTTP 401 (invalid_credential)")

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

    def test_hostname_reservation_wait_reports_initial_message_and_elapsed_progress(self):
        (self.directory / "session.json").write_text(json.dumps({
            "activation_id": "22222222-2222-4222-8222-222222222222",
            "access_token": "central-session", "expires_at": int(time.time()) + 900,
        }))
        args = type("Args", (), {
            "state_dir": self.directory, "central_url": "https://central", "nickname": "aws-acceptance",
            "public_ipv4": "203.0.113.10", "challenge_root": self.directory / "challenge", "wait_seconds": 65,
        })
        status = {
            "reservation_id": "33333333-3333-4333-8333-333333333333",
            "nickname": "aws-acceptance", "hostname": "aws-acceptance.matched.laysports.co.uk",
            "dns": {"status": "pending", "retry_after": None}, "reservation_expires_at": None,
            "network_challenge": None,
        }
        clock = [0.0]

        def sleep(seconds):
            clock[0] += seconds

        output = io.StringIO()
        with patch.object(recognition_client, "_ensure_session", return_value=json.loads((self.directory / "session.json").read_text())), \
             patch.object(recognition_client, "_status", return_value=status), \
             patch.object(recognition_client.time, "monotonic", side_effect=lambda: clock[0]), \
             patch.object(recognition_client.time, "sleep", side_effect=sleep), \
             patch("sys.stderr", output):
            with self.assertRaisesRegex(RuntimeError, "initial wait limit"):
                recognition_client.reserve_hostname(args)
        messages = output.getvalue()
        self.assertIn("[INFO] Waiting for your LayMatched hostname/DNS to become ready...", messages)
        self.assertIn("[INFO] This can take several minutes. The installer is still running — please do not close this window.", messages)
        self.assertIn("[WAIT] Still waiting for DNS... 30 seconds elapsed", messages)
        self.assertIn("[WAIT] Still waiting for DNS... 60 seconds elapsed", messages)
        self.assertNotRegex(messages, r"[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]|\\x1b")

    def test_retry_after_extends_wait_beyond_original_300_second_deadline(self):
        (self.directory / "session.json").write_text(json.dumps({
            "activation_id": "22222222-2222-4222-8222-222222222222",
            "access_token": "central-session", "expires_at": int(time.time()) + 900,
        }))
        args = type("Args", (), {
            "state_dir": self.directory, "central_url": "https://central", "nickname": "aws-acceptance",
            "public_ipv4": "203.0.113.10", "challenge_root": self.directory / "challenge", "wait_seconds": 300,
        })
        expiry = (recognition_client.dt.datetime.now(recognition_client.dt.timezone.utc) + recognition_client.dt.timedelta(seconds=900)).isoformat()
        clock = [0.0]
        status_calls = []

        def status(*_args, **_kwargs):
            status_calls.append(clock[0])
            if clock[0] >= 350:
                dns = {"status": "ready", "retry_after": None}
            else:
                dns = {"status": "failed", "retry_after": max(1, int(350 - clock[0]))}
            return {
                "version": 7, "reservation_id": "reservation-1", "nickname": "aws-acceptance",
                "hostname": "aws-acceptance.matched.laysports.co.uk", "reservation_expires_at": expiry,
                "network_challenge": None, "dns": dns,
            }

        output = io.StringIO()
        with patch.object(recognition_client, "_ensure_session", return_value=json.loads((self.directory / "session.json").read_text())), \
             patch.object(recognition_client, "_status", side_effect=status), \
             patch.object(recognition_client.time, "monotonic", side_effect=lambda: clock[0]), \
             patch.object(recognition_client.time, "sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)), \
             patch("sys.stderr", output):
            self.assertEqual(recognition_client.reserve_hostname(args), 0)
        self.assertGreaterEqual(clock[0], 350)
        self.assertGreater(clock[0], 300)
        self.assertEqual(json.loads((self.directory / "hostname.json").read_text())["status"], "dns_ready")
        self.assertTrue(any(value >= 300 for value in status_calls))
        self.assertIn("Central has scheduled another DNS check", output.getvalue())

    def test_due_progress_is_emitted_before_a_slow_status_request(self):
        (self.directory / "session.json").write_text(json.dumps({
            "activation_id": "22222222-2222-4222-8222-222222222222",
            "access_token": "central-session", "expires_at": int(time.time()) + 900,
        }))
        args = type("Args", (), {
            "state_dir": self.directory, "central_url": "https://central", "nickname": "aws-acceptance",
            "public_ipv4": "203.0.113.10", "challenge_root": self.directory / "challenge", "wait_seconds": 120,
        })
        expiry = (recognition_client.dt.datetime.now(recognition_client.dt.timezone.utc) + recognition_client.dt.timedelta(seconds=900)).isoformat()
        clock = [0.0]
        output = io.StringIO()
        calls = [0]

        def status(*_args, **_kwargs):
            calls[0] += 1
            if calls[0] == 1:
                return {
                    "version": 2, "reservation_id": "reservation-1", "nickname": "aws-acceptance",
                    "hostname": "aws-acceptance.matched.laysports.co.uk", "reservation_expires_at": expiry,
                    "network_challenge": None, "dns": {"status": "failed", "retry_after": 30},
                }
            self.assertIn("[WAIT] Still waiting for DNS... 30 seconds elapsed", output.getvalue())
            clock[0] += 45  # model a slow status request after checking its pre-call output
            return {
                "version": 3, "reservation_id": "reservation-1", "nickname": "aws-acceptance",
                "hostname": "aws-acceptance.matched.laysports.co.uk", "reservation_expires_at": expiry,
                "network_challenge": None, "dns": {"status": "ready", "retry_after": None},
            }

        with patch.object(recognition_client, "_ensure_session", return_value=json.loads((self.directory / "session.json").read_text())), \
             patch.object(recognition_client, "_status", side_effect=status), \
             patch.object(recognition_client.time, "monotonic", side_effect=lambda: clock[0]), \
             patch.object(recognition_client.time, "sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)), \
             patch("sys.stderr", output):
            self.assertEqual(recognition_client.reserve_hostname(args), 0)

    def test_retry_beyond_lease_and_single_renewal_horizon_fails_cleanly(self):
        (self.directory / "session.json").write_text(json.dumps({
            "activation_id": "22222222-2222-4222-8222-222222222222",
            "access_token": "central-session", "expires_at": int(time.time()) + 900,
        }))
        args = type("Args", (), {
            "state_dir": self.directory, "central_url": "https://central", "nickname": "aws-acceptance",
            "public_ipv4": "203.0.113.10", "challenge_root": self.directory / "challenge", "wait_seconds": 300,
        })
        expiry = (recognition_client.dt.datetime.now(recognition_client.dt.timezone.utc) + recognition_client.dt.timedelta(seconds=900)).isoformat()
        status = {
            "version": 4, "reservation_id": "reservation-1", "nickname": "aws-acceptance",
            "hostname": "aws-acceptance.matched.laysports.co.uk", "reservation_expires_at": expiry,
            "network_challenge": None, "dns": {"status": "failed", "retry_after": 10000},
        }
        with patch.object(recognition_client, "_ensure_session", return_value=json.loads((self.directory / "session.json").read_text())), \
             patch.object(recognition_client, "_status", return_value=status), \
             patch.object(recognition_client, "_request_authenticated") as request:
            with self.assertRaisesRegex(RuntimeError, "next central retry cannot complete"):
                recognition_client.reserve_hostname(args)
        request.assert_not_called()

    def test_retry_wait_renews_reservation_safely_with_current_version(self):
        (self.directory / "session.json").write_text(json.dumps({
            "activation_id": "22222222-2222-4222-8222-222222222222",
            "access_token": "central-session", "expires_at": int(time.time()) + 900,
        }))
        args = type("Args", (), {
            "state_dir": self.directory, "central_url": "https://central", "nickname": "aws-acceptance",
            "public_ipv4": "203.0.113.10", "challenge_root": self.directory / "challenge", "wait_seconds": 300,
        })
        clock = [0.0]
        renewal_done = [False]

        def status(*_args, **_kwargs):
            ready = clock[0] >= 1000
            expiry_seconds = 900 if ready or not renewal_done[0] else 1800
            expiry = (recognition_client.dt.datetime.now(recognition_client.dt.timezone.utc) + recognition_client.dt.timedelta(seconds=expiry_seconds)).isoformat()
            return {
                "version": 8, "reservation_id": "reservation-1", "nickname": "aws-acceptance",
                "hostname": "aws-acceptance.matched.laysports.co.uk", "reservation_expires_at": expiry,
                "network_challenge": None,
                "dns": {"status": "ready", "retry_after": None} if ready else {"status": "failed", "retry_after": max(1, int(1000 - clock[0]))},
            }

        def renew(*_args, **kwargs):
            renewal_done[0] = True
            self.assertEqual(kwargs["method"], "POST")
            self.assertEqual(kwargs["body"], {"requested_extension_seconds": 1800})
            self.assertEqual(kwargs["extra_headers"]["If-Match"], '"8"')
            return ({"reservation_expires_at": (recognition_client.dt.datetime.now(recognition_client.dt.timezone.utc) + recognition_client.dt.timedelta(seconds=1800)).isoformat()}, json.loads((self.directory / "session.json").read_text()))

        with patch.object(recognition_client, "_ensure_session", return_value=json.loads((self.directory / "session.json").read_text())), \
             patch.object(recognition_client, "_status", side_effect=status), \
             patch.object(recognition_client, "_request_authenticated", side_effect=renew) as request, \
             patch.object(recognition_client.time, "monotonic", side_effect=lambda: clock[0]), \
             patch.object(recognition_client.time, "sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)), \
             patch("sys.stderr", io.StringIO()):
            self.assertEqual(recognition_client.reserve_hostname(args), 0)
        request.assert_called_once()
        self.assertGreaterEqual(clock[0], 1000)

    def test_terminal_dns_failure_has_distinct_actionable_message(self):
        (self.directory / "session.json").write_text(json.dumps({
            "activation_id": "22222222-2222-4222-8222-222222222222",
            "access_token": "central-session", "expires_at": int(time.time()) + 900,
        }))
        args = type("Args", (), {
            "state_dir": self.directory, "central_url": "https://central", "nickname": "aws-acceptance",
            "public_ipv4": "203.0.113.10", "challenge_root": self.directory / "challenge", "wait_seconds": 300,
        })
        status = {
            "version": 4, "reservation_id": "reservation-1", "nickname": "aws-acceptance",
            "hostname": "aws-acceptance.matched.laysports.co.uk", "reservation_expires_at": None,
            "network_challenge": None, "dns": {"status": "failed", "retry_after": None},
        }
        with patch.object(recognition_client, "_ensure_session", return_value=json.loads((self.directory / "session.json").read_text())), \
             patch.object(recognition_client, "_status", return_value=status):
            with self.assertRaisesRegex(RuntimeError, "terminally; central reports no retry") as raised:
                recognition_client.reserve_hostname(args)
        self.assertIn("contact LayMatched support", str(raised.exception))

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
