import json
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread
from unittest.mock import patch

from tools import recognition_client
from tools.local_activation import Journal, KeyService


class DisposableRecognitionService:
    """Small loopback-only stand-in for the reviewed Auth/Central contract."""

    def __init__(self):
        self.requests = []
        self.fail_next_heartbeat = False
        self.session_count = 0

        service = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                return

            def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler API
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length)
                request = {
                    "path": self.path,
                    "authorization": self.headers.get("Authorization", ""),
                    "idempotency_key": self.headers.get("Idempotency-Key", ""),
                    "body": json.loads(body),
                }
                service.requests.append(request)

                if self.path == "/activation/assertions":
                    response = {"assertion": "auth-assertion", "expires_in": 600}
                elif self.path == "/v1/activations":
                    self._respond(
                        201,
                        {
                            "activation_id": "22222222-2222-4222-8222-222222222222",
                            "customer_id": "customer-42",
                            "access_token": "session-initial",
                            "expires_in": 900,
                        },
                    )
                    return
                elif self.path == "/v1/activation-sessions":
                    service.session_count += 1
                    self._respond(
                        200,
                        {
                            "activation_id": "22222222-2222-4222-8222-222222222222",
                            "access_token": f"session-refresh-{service.session_count}",
                            "expires_in": 900,
                        },
                    )
                    return
                elif self.path.startswith("/v1/activations/") and self.path.endswith("/heartbeat"):
                    if service.fail_next_heartbeat:
                        service.fail_next_heartbeat = False
                        self._respond(503, {"error": "disposable outage"})
                        return
                    self._respond(
                        200,
                        {
                            "activation_id": "22222222-2222-4222-8222-222222222222",
                            "installation_id": request["body"]["installation_id"],
                            "app_version": request["body"]["app_version"],
                            "service_status": request["body"]["service_status"],
                            "contact_state": "fresh",
                        },
                    )
                    return
                else:
                    self._respond(404, {"error": "not found"})
                    return

                self._respond(200, response)

            def _respond(self, status, value):
                encoded = json.dumps(value).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = Thread(target=self.server.serve_forever, daemon=True)

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server.server_port}"

    def start(self):
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


class RecognitionAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = self._temporary_directory()
        self.directory = self.temporary / "activation"
        Journal(self.directory).init("11111111-1111-4111-8111-111111111111")
        KeyService(self.directory).ensure()
        self.service = DisposableRecognitionService()
        self.service.start()

    def tearDown(self):
        self.service.close()
        self._remove_tree(self.temporary)

    @staticmethod
    def _temporary_directory():
        import tempfile

        return Path(tempfile.mkdtemp(prefix="laymatched-recognition-"))

    @staticmethod
    def _remove_tree(path):
        import shutil

        shutil.rmtree(path)

    def _args(self, **overrides):
        values = {
            "state_dir": self.directory,
            "auth_url": f"{self.service.url}/activation/assertions",
            "central_url": self.service.url,
            "app_version": "v1.2.3",
            "service_status": "healthy",
        }
        values.update(overrides)
        return type("Args", (), values)

    def test_clean_install_recognition_renews_and_recovers_without_secrets(self):
        installer_credential = "disposable-installer-credential"
        with patch("sys.stdin.read", return_value=installer_credential):
            self.assertEqual(recognition_client.bootstrap(self._args()), 0)

        self.assertEqual(self.service.requests[0]["path"], "/activation/assertions")
        self.assertEqual(self.service.requests[0]["authorization"], f"Bearer {installer_credential}")
        self.assertEqual(self.service.requests[1]["path"], "/v1/activations")
        self.assertEqual(self.service.requests[1]["authorization"], "Bearer auth-assertion")
        self.assertNotIn(installer_credential, json.dumps(self.service.requests[1]))
        self.assertEqual(self.service.requests[1]["body"]["installation_id"], "11111111-1111-4111-8111-111111111111")
        self.assertEqual(self.service.requests[1]["body"]["app_version"], "v1.2.3")

        session_path = self.directory / "session.json"
        session = json.loads(session_path.read_text())
        session["expires_at"] = int(time.time()) + 1
        session_path.write_text(json.dumps(session))

        self.assertEqual(recognition_client.heartbeat(self._args()), 0)
        paths = [request["path"] for request in self.service.requests]
        self.assertEqual(paths[2:4], ["/v1/activation-sessions", "/v1/activations/22222222-2222-4222-8222-222222222222/heartbeat"])
        self.assertEqual(self.service.requests[3]["body"], {
            "installation_id": "11111111-1111-4111-8111-111111111111",
            "app_version": "v1.2.3",
            "service_status": "healthy",
        })

        self.service.fail_next_heartbeat = True
        self.assertEqual(recognition_client.heartbeat(self._args(service_status="degraded")), 75)
        outbox = json.loads((self.directory / "heartbeat-outbox.json").read_text())
        queued_key = outbox[0]["idempotency_key"]

        self.assertEqual(recognition_client.heartbeat(self._args(service_status="unknown")), 0)
        self.assertFalse((self.directory / "heartbeat-outbox.json").exists())
        successful_heartbeats = [
            request for request in self.service.requests if request["path"].endswith("/heartbeat")
        ]
        self.assertEqual(successful_heartbeats[-2]["idempotency_key"], queued_key)
        self.assertEqual(successful_heartbeats[-2]["body"]["service_status"], "degraded")
        self.assertEqual(successful_heartbeats[-1]["body"]["service_status"], "unknown")
        central_requests = [
            request for request in self.service.requests if request["path"] != "/activation/assertions"
        ]
        self.assertTrue(all(installer_credential not in json.dumps(request) for request in central_requests))
        self.assertTrue(all(set(request["body"]) <= {"installation_id", "app_version", "service_status"} for request in successful_heartbeats))


if __name__ == "__main__":
    unittest.main()
