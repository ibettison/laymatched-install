#!/usr/bin/env python3
"""Small, offline-safe client for the approved central recognition contract."""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

try:
    from tools.local_activation import KeyService
except ModuleNotFoundError:
    from local_activation import KeyService


class RecognitionHTTPError(RuntimeError):
    def __init__(self, status: int):
        super().__init__(f"central recognition request failed with HTTP {status}")
        self.status = status


def _b64(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def _post(url: str, body: dict, headers: dict[str, str], timeout: int = 15) -> dict:
    encoded = json.dumps(body, separators=(",", ":"), sort_keys=True).encode("utf-8")
    request = urllib.request.Request(url, data=encoded, headers={**headers, "Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            value = json.loads(response.read())
    except urllib.error.HTTPError as error:
        raise RecognitionHTTPError(error.code) from error
    if not isinstance(value, dict):
        raise RuntimeError("central recognition returned an invalid response")
    return value


def _public_key(directory: Path) -> str:
    service = KeyService(directory)
    service.ensure()
    completed = subprocess.run(["openssl", "pkey", "-pubin", "-in", str(service.public), "-pubout", "-outform", "DER"], check=True, capture_output=True)
    return _b64(completed.stdout)


def _read_json(path: Path, default):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return default


def _write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.new")
    temporary.write_text(json.dumps(value, separators=(",", ":"), sort_keys=True))
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
    os.chmod(path, 0o600)


def _session(directory: Path) -> dict:
    value = _read_json(directory / "session.json", None)
    if not isinstance(value, dict) or not value.get("activation_id") or not value.get("access_token"):
        raise RuntimeError("central recognition session is not configured")
    return value


def bootstrap(args) -> int:
    directory = Path(args.state_dir)
    installation_id = json.loads((directory / "state.json").read_text())["installation_id"]
    token = sys.stdin.read().strip()
    if not token:
        raise RuntimeError("installer credential is required on stdin")
    public_key = _public_key(directory)
    request = {"installation_id": installation_id, "installation_public_key": public_key, "app_version": args.app_version}
    assertion = _post(args.auth_url, request, {"Authorization": f"Bearer {token}"})
    access = _post(f"{args.central_url.rstrip('/')}/v1/activations", request,
                   {"Authorization": f"Bearer {assertion['assertion']}", "Idempotency-Key": str(uuid.uuid4())})
    _write_json(directory / "session.json", {"activation_id": access["activation_id"], "access_token": access["access_token"],
                                               "expires_at": int(time.time()) + int(access["expires_in"])})
    return 0


def _canonical_signature(directory: Path, method: str, path: str, body: bytes, timestamp: str, nonce: str) -> str:
    try:
        from tools.local_activation import KeyService
    except ModuleNotFoundError:
        from local_activation import KeyService
    import hashlib
    message = "\n".join((method, path, hashlib.sha256(body).hexdigest(), timestamp, nonce)).encode()
    return _b64(KeyService(directory).sign(message))


def _signed_request_headers(directory: Path, *, installation_id: str, path: str, body: bytes, idempotency_key: str,
                            access_token: str | None = None) -> dict[str, str]:
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    nonce = uuid.uuid4().hex
    headers = {"X-Installation-Id": installation_id, "X-Signature-Timestamp": timestamp,
               "X-Signature-Nonce": nonce,
               "X-Installation-Signature": _canonical_signature(directory, "POST", path, body, timestamp, nonce),
               "Idempotency-Key": idempotency_key}
    if access_token:
        headers["Authorization"] = f"Bearer {access_token}"
    return headers


def _resume_session(args, directory: Path, session: dict) -> dict:
    body = {"activation_id": session["activation_id"]}
    path = "/v1/activation-sessions"
    encoded = json.dumps(body, separators=(",", ":"), sort_keys=True).encode()
    response = _post(f"{args.central_url.rstrip('/')}{path}", body,
                     _signed_request_headers(directory, installation_id=json.loads((directory / "state.json").read_text())["installation_id"],
                                             path=path, body=encoded, idempotency_key=str(uuid.uuid4())))
    refreshed = {"activation_id": response["activation_id"], "access_token": response["access_token"],
                 "expires_at": int(time.time()) + int(response["expires_in"])}
    _write_json(directory / "session.json", refreshed)
    return refreshed


def _ensure_session(args, directory: Path, session: dict) -> dict:
    try:
        expires_at = int(session.get("expires_at", 0))
    except (TypeError, ValueError):
        expires_at = 0
    if expires_at <= int(time.time()) + 60:
        return _resume_session(args, directory, session)
    return session


def heartbeat(args) -> int:
    directory = Path(args.state_dir)
    state = json.loads((directory / "state.json").read_text())
    session = _session(directory)
    pending_path = directory / "heartbeat-outbox.json"
    queued = _read_json(pending_path, [])
    body = {"installation_id": state["installation_id"], "app_version": args.app_version, "service_status": args.service_status}
    queued.append({"body": body, "idempotency_key": str(uuid.uuid4())})
    # The new item is durable before any session renewal or network delivery.
    _write_json(pending_path, queued)
    while queued:
        item = queued[0]
        try:
            session = _ensure_session(args, directory, session)
        except (OSError, urllib.error.URLError, RecognitionHTTPError, RuntimeError, ValueError, KeyError):
            return 75
        encoded = json.dumps(item["body"], separators=(",", ":"), sort_keys=True).encode()
        path = f"/v1/activations/{session['activation_id']}/heartbeat"
        headers = _signed_request_headers(directory, installation_id=state["installation_id"], path=path,
                                          body=encoded, idempotency_key=item["idempotency_key"],
                                          access_token=session["access_token"])
        try:
            _post(f"{args.central_url.rstrip('/')}{path}", item["body"], headers)
        except RecognitionHTTPError as error:
            if error.status != 401:
                return 75
            try:
                session = _resume_session(args, directory, session)
                retry_headers = _signed_request_headers(
                    directory, installation_id=state["installation_id"], path=path, body=encoded,
                    idempotency_key=item["idempotency_key"], access_token=session["access_token"],
                )
                _post(f"{args.central_url.rstrip('/')}{path}", item["body"], retry_headers)
            except (OSError, urllib.error.URLError, RecognitionHTTPError, RuntimeError, ValueError, KeyError):
                return 75
        except (OSError, urllib.error.URLError, RuntimeError):
            print(f"central recognition unavailable; heartbeat retained for retry", file=sys.stderr)
            return 75
        queued.pop(0)
        if queued:
            _write_json(pending_path, queued)
        else:
            pending_path.unlink(missing_ok=True)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--central-url", required=True)
    parser.add_argument("--app-version", required=True)
    sub = parser.add_subparsers(dest="command", required=True)
    bootstrap_parser = sub.add_parser("bootstrap")
    bootstrap_parser.add_argument("--auth-url", required=True)
    heartbeat_parser = sub.add_parser("heartbeat")
    heartbeat_parser.add_argument("--service-status", choices=("healthy", "degraded", "unknown"), default="healthy")
    args = parser.parse_args()
    return bootstrap(args) if args.command == "bootstrap" else heartbeat(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"central recognition error: {error}", file=sys.stderr)
        raise SystemExit(1)
