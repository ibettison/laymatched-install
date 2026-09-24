#!/usr/bin/env python3
"""Small, offline-safe client for the approved central recognition contract."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

try:
    from tools.local_activation import KeyService
except ModuleNotFoundError:
    from local_activation import KeyService


VERSION_CONFLICT_STATUS = 409
TRANSIENT_HTTP_STATUSES = frozenset({408, 425, 429, *range(500, 600)})
CENTRAL_RETRY_SECONDS = 60
# Stable error identifiers emitted by the central activation API's
# authenticated/signed routes. Keep this allowlist in step with that API;
# arbitrary response header text must never reach operator diagnostics.
ACTIVATION_ERROR_CODES = frozenset({
    "activation_deactivated",
    "activation_incomplete",
    "conflict",
    "dns_pending",
    "https_failed",
    "idempotency_conflict",
    "invalid_credential",
    "invalid_signature",
    "licence_inactive",
    "nickname_invalid",
    "nickname_reserved",
    "nickname_unavailable",
    "not_found",
    "replay_detected",
    "validation_failed",
    "version_conflict",
})
DNS_PROGRESS_INTERVAL_SECONDS = 30
DNS_RETRY_COMPLETION_GRACE_SECONDS = 30
DNS_RESERVATION_RENEWAL_SECONDS = 1800
DNS_RENEWAL_REQUEST_SAFETY_SECONDS = 30
DNS_SPINNER_FRAMES = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"


class RecognitionHTTPError(RuntimeError):
    def __init__(self, status: int, activation_error: str | None = None):
        detail = "; fetch current activation status before retrying" if status == VERSION_CONFLICT_STATUS else ""
        classification = f" ({activation_error})" if activation_error else ""
        super().__init__(f"central recognition request failed with HTTP {status}{classification}{detail}")
        self.status = status
        self.activation_error = activation_error


def _safe_activation_error(value: str | None) -> str | None:
    return value if value in ACTIVATION_ERROR_CODES else None


def _http_error(error: urllib.error.HTTPError) -> RecognitionHTTPError:
    # Keep only the server's bounded classification. Never inspect its body or
    # copy request details into an error shown to the installer operator.
    classification = _safe_activation_error(error.headers.get("X-Activation-Error") if error.headers else None)
    return RecognitionHTTPError(error.code, classification)


def _is_transient_error(error: BaseException) -> bool:
    return isinstance(error, (OSError, TimeoutError, urllib.error.URLError)) or (
        isinstance(error, RecognitionHTTPError) and error.status in TRANSIENT_HTTP_STATUSES
    )


def _call_with_retries(operation: str, call, *, deadline: float):
    attempt = 0
    while True:
        try:
            return call()
        except Exception as error:
            if not _is_transient_error(error):
                raise
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                category = f"HTTP {error.status}" if isinstance(error, RecognitionHTTPError) else "connection failure"
                if isinstance(error, RecognitionHTTPError) and error.activation_error:
                    category += f" ({error.activation_error})"
                raise RuntimeError(
                    f"{operation} remained unavailable during the bounded retry window ({category})"
                ) from error
            delay = min(2 ** min(attempt, 4), 15, remaining)
            time.sleep(max(0.1, delay))
            attempt += 1


def _b64(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def _post(url: str, body: dict, headers: dict[str, str], timeout: int = 15) -> dict:
    encoded = json.dumps(body, separators=(",", ":"), sort_keys=True).encode("utf-8")
    request = urllib.request.Request(url, data=encoded, headers={**headers, "Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            value = json.loads(response.read())
    except urllib.error.HTTPError as error:
        raise _http_error(error) from None
    if not isinstance(value, dict):
        raise RuntimeError("central recognition returned an invalid response")
    return value


def _get(url: str, headers: dict[str, str], timeout: int = 15) -> dict:
    request = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            value = json.loads(response.read())
    except urllib.error.HTTPError as error:
        raise _http_error(error) from None
    if not isinstance(value, dict):
        raise RuntimeError("central activation returned an invalid response")
    return value


def _put(url: str, body: dict, headers: dict[str, str], timeout: int = 15) -> dict:
    encoded = json.dumps(body, separators=(",", ":"), sort_keys=True).encode("utf-8")
    request = urllib.request.Request(url, data=encoded, headers={**headers, "Content-Type": "application/json"}, method="PUT")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            value = json.loads(response.read())
    except urllib.error.HTTPError as error:
        raise _http_error(error) from None
    if not isinstance(value, dict):
        raise RuntimeError("central recognition returned an invalid response")
    return value


def _patch(url: str, body: dict, headers: dict[str, str], timeout: int = 15) -> dict:
    encoded = json.dumps(body, separators=(",", ":"), sort_keys=True).encode("utf-8")
    request = urllib.request.Request(url, data=encoded, headers={**headers, "Content-Type": "application/json"}, method="PATCH")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            value = json.loads(response.read())
    except urllib.error.HTTPError as error:
        raise _http_error(error) from None
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
    deadline = time.monotonic() + CENTRAL_RETRY_SECONDS
    assertion = _call_with_retries(
        "activation authority",
        lambda: _post(args.auth_url, request, {"Authorization": f"Bearer {token}"}),
        deadline=deadline,
    )
    idempotency_key = str(uuid.uuid4())
    access = _call_with_retries(
        "central activation bootstrap",
        lambda: _post(f"{args.central_url.rstrip('/')}/v1/activations", request,
                      {"Authorization": f"Bearer {assertion['assertion']}", "Idempotency-Key": idempotency_key}),
        deadline=deadline,
    )
    _write_json(directory / "session.json", {"activation_id": access["activation_id"], "access_token": access["access_token"],
                                               "expires_at": int(time.time()) + int(access["expires_in"]),
                                               "version": int(access.get("version", 1))})
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
                            access_token: str | None = None, method: str = "POST") -> dict[str, str]:
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    nonce = uuid.uuid4().hex
    headers = {"X-Installation-Id": installation_id, "X-Signature-Timestamp": timestamp,
               "X-Signature-Nonce": nonce,
               "X-Installation-Signature": _canonical_signature(directory, method, path, body, timestamp, nonce),
               "Idempotency-Key": idempotency_key}
    if access_token:
        headers["Authorization"] = f"Bearer {access_token}"
    return headers


def _resume_session(args, directory: Path, session: dict, *, retry_deadline: float | None = None) -> dict:
    body = {"activation_id": session["activation_id"]}
    path = "/v1/activation-sessions"
    encoded = json.dumps(body, separators=(",", ":"), sort_keys=True).encode()
    idempotency_key = str(uuid.uuid4())
    deadline = retry_deadline or (time.monotonic() + CENTRAL_RETRY_SECONDS)
    response = _call_with_retries(
        "activation session renewal",
        lambda: _post(
            f"{args.central_url.rstrip('/')}{path}", body,
            _signed_request_headers(
                directory,
                installation_id=json.loads((directory / "state.json").read_text())["installation_id"],
                path=path,
                body=encoded,
                idempotency_key=idempotency_key,
            ),
        ),
        deadline=deadline,
    )
    refreshed = {"activation_id": response["activation_id"], "access_token": response["access_token"],
                 "expires_at": int(time.time()) + int(response["expires_in"]),
                 "version": int(response.get("version", session.get("version", 1)))}
    _write_json(directory / "session.json", refreshed)
    return refreshed


def _ensure_session(args, directory: Path, session: dict, *, retry_deadline: float | None = None) -> dict:
    try:
        expires_at = int(session.get("expires_at", 0))
    except (TypeError, ValueError):
        expires_at = 0
    if expires_at <= int(time.time()) + 60:
        return _resume_session(args, directory, session, retry_deadline=retry_deadline)
    return session


def _request_authenticated(args, directory: Path, session: dict, *, method: str, path: str,
                           body: dict | None, operation: str, retry_deadline: float,
                           extra_headers: dict[str, str] | None = None) -> tuple[dict, dict]:
    encoded = b"" if body is None else json.dumps(body, separators=(",", ":"), sort_keys=True).encode()
    idempotency_key = str(uuid.uuid4())
    resumed = False

    def issue() -> dict:
        fresh = _ensure_session(args, directory, session, retry_deadline=retry_deadline)
        if fresh is not session:
            session.clear()
            session.update(fresh)
        state = json.loads((directory / "state.json").read_text())
        headers = _signed_request_headers(
            directory,
            installation_id=state["installation_id"],
            path=path,
            body=encoded,
            idempotency_key=idempotency_key,
            access_token=session["access_token"],
            method=method,
        )
        if extra_headers:
            headers.update(extra_headers)
        url = f"{args.central_url.rstrip('/')}{path}"
        if method == "GET":
            return _get(url, headers)
        if method == "PUT":
            return _put(url, body or {}, headers)
        if method == "PATCH":
            return _patch(url, body or {}, headers)
        return _post(url, body or {}, headers)

    while True:
        try:
            return _call_with_retries(operation, issue, deadline=retry_deadline), session
        except RecognitionHTTPError as error:
            if error.status != 401 or resumed:
                raise
            renewed = _resume_session(args, directory, session, retry_deadline=retry_deadline)
            session.clear()
            session.update(renewed)
            resumed = True


def _write_hostname(directory: Path, response: dict) -> None:
    _write_json(directory / "hostname.json", {
        "reservation_id": response.get("reservation_id"),
        "nickname": response.get("nickname"),
        "hostname": response.get("hostname"),
        "status": response.get("status"),
    })


def _write_challenge(root: Path, kind: str, challenge: str) -> None:
    if not re.fullmatch(r"[A-Za-z0-9_-]{16,128}", challenge):
        raise RuntimeError("central recognition returned an invalid challenge")
    directory = root / ".well-known" / f"laymatched-{kind}"
    directory.mkdir(parents=True, exist_ok=True)
    os.chmod(root, 0o755)
    os.chmod(root / ".well-known", 0o755)
    os.chmod(directory, 0o755)
    target = directory / challenge
    target.write_text(challenge + "\n", encoding="ascii")
    os.chmod(target, 0o644)


def _status(args, directory: Path, session: dict, *, retry_deadline: float | None = None) -> dict:
    path = f"/v1/activations/{session['activation_id']}"
    response, _ = _request_authenticated(
        args,
        directory,
        session,
        method="GET",
        path=path,
        body=None,
        operation="activation status",
        retry_deadline=retry_deadline or (time.monotonic() + CENTRAL_RETRY_SECONDS),
    )
    if "version" in response:
        session["version"] = int(response["version"])
        _write_json(directory / "session.json", session)
    return response


def activation_status(args) -> int:
    directory = Path(args.state_dir)
    session = _ensure_session(args, directory, _session(directory))
    print(json.dumps(_status(args, directory, session), sort_keys=True))
    return 0


def _reservation_from_status(status: dict) -> dict:
    dns_status = (status.get("dns") or {}).get("status")
    return {
        "reservation_id": status.get("reservation_id"),
        "nickname": status.get("nickname"),
        "hostname": status.get("hostname"),
        "status": {"ready": "dns_ready", "failed": "dns_failed"}.get(dns_status, "dns_pending"),
        "reservation_expires_at": status.get("reservation_expires_at"),
        "retry_after": (status.get("dns") or {}).get("retry_after"),
        "version": status.get("version"),
        "network_challenge": status.get("network_challenge"),
    }


def _expiry_monotonic_deadline(value: str | None, *, monotonic_now: float, utc_now: dt.datetime | None = None) -> float | None:
    if not value:
        return None
    try:
        expiry = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if expiry.tzinfo is None:
            return None
        now_utc = utc_now or dt.datetime.now(dt.timezone.utc)
        return monotonic_now + max(0.0, (expiry.astimezone(dt.timezone.utc) - now_utc).total_seconds())
    except (TypeError, ValueError):
        return None


def _retry_after_seconds(reservation: dict) -> int | None:
    try:
        value = int(reservation.get("retry_after"))
    except (TypeError, ValueError):
        return None
    return value if value > 0 else None


class DNSWaitSpinner:
    """Small terminal-only heartbeat for the bounded customer DNS wait."""

    def __init__(self, stream, *, started_at: float, interval: float = 0.1):
        self.stream = stream
        self.started_at = started_at
        self.interval = interval
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread = None
        try:
            self.enabled = bool(stream.isatty()) and all(
                frame.encode(stream.encoding or "ascii") for frame in DNS_SPINNER_FRAMES
            )
        except (AttributeError, LookupError, UnicodeEncodeError, OSError):
            self.enabled = False

    @staticmethod
    def render_frame(index: int, elapsed_seconds: float) -> str:
        elapsed = max(0, int(elapsed_seconds))
        return f"{DNS_SPINNER_FRAMES[index % len(DNS_SPINNER_FRAMES)]} Setting up your LayMatched address... {elapsed // 60:02d}:{elapsed % 60:02d} elapsed"

    def _write_frame_locked(self, index: int | None = None):
        elapsed = time.monotonic() - self.started_at
        if index is None:
            index = int(elapsed / self.interval)
        self.stream.write("\r" + self.render_frame(index, elapsed))
        self.stream.flush()

    def _animate(self):
        index = 0
        while not self._stop.wait(self.interval):
            with self._lock:
                self._write_frame_locked(index)
            index += 1

    def start(self):
        if self.enabled and self._thread is None:
            self._thread = threading.Thread(target=self._animate, name="dns-wait-spinner", daemon=True)
            self._thread.start()

    def print_permanent(self, message: str):
        if not self.enabled:
            print(message, file=self.stream, flush=True)
            return
        with self._lock:
            self.stream.write("\r\x1b[2K")
            print(message, file=self.stream, flush=True)
            self._write_frame_locked()

    def stop(self):
        if self._thread is None:
            return
        self._stop.set()
        self._thread.join()
        with self._lock:
            self.stream.write("\r\x1b[2K")
            self.stream.flush()
        self._thread = None

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, _exception_type, _exception, _traceback):
        self.stop()


def _emit_dns_wait_progress(started_at: float, next_progress_at: float, reservation: dict,
                            spinner: DNSWaitSpinner | None = None) -> float:
    current = time.monotonic()
    if current < next_progress_at:
        return next_progress_at
    elapsed = int(current - started_at)
    message = f"[WAIT] Still waiting for DNS... {elapsed} seconds elapsed"
    retry_after = _retry_after_seconds(reservation)
    if reservation.get("status") == "dns_failed" and retry_after is not None:
        message += f". Central has scheduled another DNS check in about {retry_after} seconds."
    (spinner.print_permanent(message) if spinner else print(message, file=sys.stderr, flush=True))
    intervals = (elapsed // DNS_PROGRESS_INTERVAL_SECONDS) + 1
    return started_at + intervals * DNS_PROGRESS_INTERVAL_SECONDS


def _dns_wait_timeout(reservation: dict, *, hard_bound: bool = False) -> RuntimeError:
    if reservation.get("status") == "dns_failed" and _retry_after_seconds(reservation) is None:
        return RuntimeError(
            "customer DNS failed terminally; central reports no retry is scheduled. "
            "The activation is preserved; contact LayMatched support with the hostname before retrying."
        )
    if hard_bound:
        return RuntimeError(
            "customer DNS is still being provisioned, but the next central retry cannot complete "
            "within the safe reservation wait limit. The activation is preserved; rerun install.sh "
            "later to resume safely."
        )
    return RuntimeError(
        "customer DNS is still pending and central has not reported a retry that can complete "
        "within the initial wait limit. The activation is preserved; rerun install.sh later to resume safely."
    )


def reserve_hostname(args) -> int:
    directory = Path(args.state_dir)
    state = json.loads((directory / "state.json").read_text())
    started_at = time.monotonic()
    soft_deadline = started_at + max(1, args.wait_seconds)
    next_progress_at = started_at + DNS_PROGRESS_INTERVAL_SECONDS
    print("[INFO] Waiting for your LayMatched hostname/DNS to become ready...", file=sys.stderr, flush=True)
    print("[INFO] This can take several minutes. The installer is still running — please do not close this window.", file=sys.stderr, flush=True)

    session = _ensure_session(args, directory, _session(directory), retry_deadline=soft_deadline)
    activation_status = _status(args, directory, session, retry_deadline=soft_deadline)
    resuming_reservation = bool(activation_status.get("reservation_id"))
    if resuming_reservation:
        if activation_status.get("nickname") != args.nickname or activation_status.get("hostname") != f"{args.nickname}.matched.laysports.co.uk":
            raise RuntimeError("existing activation reservation does not match the requested nickname")
        reservation = _reservation_from_status(activation_status)
        reservation["network_challenge"] = activation_status.get("network_challenge")
    else:
        availability_body = {"nickname": args.nickname}
        availability_path = f"/v1/activations/{session['activation_id']}/nickname-availability"
        availability, session = _request_authenticated(
            args, directory, session, method="POST", path=availability_path, body=availability_body,
            operation="nickname availability", retry_deadline=soft_deadline,
        )
        if not availability.get("available"):
            raise RuntimeError("nickname is unavailable")
        reservation_body = {"nickname": args.nickname, "public_ipv4": args.public_ipv4}
        reservation_path = f"/v1/activations/{session['activation_id']}/nickname-reservations"
        reservation, session = _request_authenticated(
            args, directory, session, method="POST", path=reservation_path, body=reservation_body,
            operation="nickname reservation", retry_deadline=soft_deadline,
        )
    if reservation.get("nickname") != args.nickname or reservation.get("hostname") != f"{args.nickname}.matched.laysports.co.uk":
        raise RuntimeError("central recognition returned a hostname reservation that does not match the requested nickname")
    challenge = reservation.get("network_challenge")
    if not challenge and not resuming_reservation:
        raise RuntimeError("central recognition did not issue a network challenge")
    if challenge:
        _write_challenge(Path(args.challenge_root), "network", challenge)
        network_body = {"public_ipv4": args.public_ipv4, "public_ipv6": None, "challenge_response": challenge}
        network_path = f"/v1/activations/{session['activation_id']}/network"
        current_status = activation_status if resuming_reservation else _status(
            args, directory, session, retry_deadline=soft_deadline
        )
        _, session = _request_authenticated(
            args, directory, session, method="PUT", path=network_path, body=network_body,
            operation="public-IP challenge verification", retry_deadline=soft_deadline,
            extra_headers={"If-Match": f'"{current_status.get("version", session.get("version", 1))}"'},
        )
        activation_status = _status(args, directory, session, retry_deadline=soft_deadline)

    if activation_status.get("reservation_id"):
        reservation = _reservation_from_status(activation_status)
    _write_hostname(directory, reservation)
    if reservation.get("status") == "dns_ready":
        print(json.dumps(reservation, sort_keys=True))
        return 0

    now = time.monotonic()
    lease_deadline = _expiry_monotonic_deadline(
        reservation.get("reservation_expires_at"), monotonic_now=now
    )
    # The central API grants a 15-minute lease; renewal replaces expiry with
    # request-time + up to 30 minutes. Allow one renewal horizon, reserving
    # 30 seconds for the renewal request and 30 seconds for worker completion.
    hard_deadline = soft_deadline if lease_deadline is None else (
        lease_deadline + DNS_RESERVATION_RENEWAL_SECONDS
        - DNS_RETRY_COMPLETION_GRACE_SECONDS - DNS_RENEWAL_REQUEST_SAFETY_SECONDS
    )
    effective_deadline = soft_deadline
    retry_extended_wait = False

    with DNSWaitSpinner(sys.stderr, started_at=started_at) as spinner:
        while True:
            if reservation.get("status") == "dns_ready":
                print(json.dumps(reservation, sort_keys=True))
                return 0
            if reservation.get("status") == "dns_failed" and _retry_after_seconds(reservation) is None:
                raise _dns_wait_timeout(reservation)

            now = time.monotonic()
            retry_after = _retry_after_seconds(reservation)
            retry_due = now + retry_after if retry_after is not None else None
            renewal_at = None
            if retry_due is not None:
                retry_completion_deadline = retry_due + DNS_RETRY_COMPLETION_GRACE_SECONDS
                if retry_completion_deadline > hard_deadline:
                    raise _dns_wait_timeout(reservation, hard_bound=True)
                effective_deadline = max(effective_deadline, retry_completion_deadline)
                retry_extended_wait = retry_extended_wait or retry_completion_deadline > soft_deadline

                lease_deadline = _expiry_monotonic_deadline(
                    reservation.get("reservation_expires_at"), monotonic_now=now
                )
                if lease_deadline is None:
                    effective_deadline = min(effective_deadline, soft_deadline)
                elif retry_completion_deadline > lease_deadline:
                    renewal_at = max(
                        now,
                        retry_completion_deadline - DNS_RESERVATION_RENEWAL_SECONDS
                        - DNS_RENEWAL_REQUEST_SAFETY_SECONDS,
                    )
                    if renewal_at + DNS_RENEWAL_REQUEST_SAFETY_SECONDS >= lease_deadline:
                        raise _dns_wait_timeout(reservation, hard_bound=True)

            if now >= effective_deadline:
                raise _dns_wait_timeout(reservation, hard_bound=retry_extended_wait)

            next_progress_at = _emit_dns_wait_progress(started_at, next_progress_at, reservation, spinner)

            if renewal_at is not None and now >= renewal_at:
                renew_path = (
                    f"/v1/activations/{session['activation_id']}/nickname-reservations/"
                    f"{reservation['reservation_id']}/renew"
                )
                requested_extension = min(
                    DNS_RESERVATION_RENEWAL_SECONDS,
                    max(300, int(hard_deadline - now)),
                )
                renewed, session = _request_authenticated(
                    args, directory, session, method="POST", path=renew_path,
                    body={"requested_extension_seconds": requested_extension},
                    operation="nickname reservation renewal", retry_deadline=effective_deadline,
                    extra_headers={"If-Match": f'"{activation_status.get("version", session.get("version", 1))}"'},
                )
                renewed_expiry = _expiry_monotonic_deadline(
                    renewed.get("reservation_expires_at"), monotonic_now=time.monotonic()
                )
                if renewed_expiry is None or renewed_expiry <= retry_completion_deadline:
                    raise RuntimeError(
                        "central could not safely renew the hostname reservation through its scheduled DNS retry. "
                        "The activation is preserved; rerun install.sh later to resume safely."
                    )
                reservation["reservation_expires_at"] = renewed["reservation_expires_at"]
                activation_status = _status(args, directory, session, retry_deadline=effective_deadline)
                reservation = _reservation_from_status(activation_status)
                _write_hostname(directory, reservation)
                continue

            remaining = effective_deadline - now
            if remaining <= 0:
                raise _dns_wait_timeout(reservation, hard_bound=retry_extended_wait)
            wait_for = min(DNS_PROGRESS_INTERVAL_SECONDS, remaining)
            if retry_after is not None:
                wait_for = min(wait_for, max(1, retry_after))
            if renewal_at is not None:
                wait_for = min(wait_for, max(0.1, renewal_at - now))
            time.sleep(max(0.1, wait_for))

            # Emit any due heartbeat before the potentially slow/retrying HTTP call.
            next_progress_at = _emit_dns_wait_progress(started_at, next_progress_at, reservation, spinner)
            activation_status = _status(args, directory, session, retry_deadline=effective_deadline)
            reservation = _reservation_from_status(activation_status)
            _write_hostname(directory, reservation)


def report_https(args) -> int:
    directory = Path(args.state_dir)
    session = _ensure_session(args, directory, _session(directory))
    status = _status(args, directory, session)
    challenge = (status.get("https") or {}).get("challenge_nonce")
    hostname = status.get("hostname")
    if not challenge or hostname != args.hostname:
        raise RuntimeError("central HTTPS challenge is not ready for this hostname")
    _write_challenge(Path(args.challenge_root), "https", challenge)
    fingerprint = subprocess.run(
        ["openssl", "x509", "-in", args.certificate, "-noout", "-fingerprint", "-sha256"],
        check=True, capture_output=True, text=True,
    ).stdout.strip().split("=", 1)[-1].replace(":", "").lower()
    end_date = subprocess.run(
        ["openssl", "x509", "-in", args.certificate, "-noout", "-enddate"],
        check=True, capture_output=True, text=True,
    ).stdout.strip().split("=", 1)[-1]
    expires = dt.datetime.strptime(end_date, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=dt.timezone.utc)
    body = {
        "hostname": hostname, "certificate_fingerprint_sha256": fingerprint,
        "certificate_not_after": expires.isoformat().replace("+00:00", "Z"),
        "challenge_nonce": challenge, "observed_at": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    path = f"/v1/activations/{session['activation_id']}/https-proof"
    response, _ = _request_authenticated(
        args, directory, session, method="POST", path=path, body=body,
        operation="HTTPS proof", retry_deadline=time.monotonic() + CENTRAL_RETRY_SECONDS,
    )
    print(json.dumps(response, sort_keys=True))
    return 0


def _state_and_session(args, directory: Path) -> tuple[dict, dict]:
    session = _ensure_session(args, directory, _session(directory))
    return json.loads((directory / "state.json").read_text()), session


def report_profile(args) -> int:
    directory = Path(args.state_dir)
    _, session = _state_and_session(args, directory)
    status = _status(args, directory, session)
    body = {"full_name": args.full_name, "town_city": args.town_city, "country_code": args.country_code}
    path = f"/v1/activations/{session['activation_id']}/profile"
    response, _ = _request_authenticated(
        args, directory, session, method="PATCH", path=path, body=body,
        operation="profile update", retry_deadline=time.monotonic() + CENTRAL_RETRY_SECONDS,
        extra_headers={"If-Match": f'"{status.get("version", session.get("version", 1))}"'},
    )
    print(json.dumps(response, sort_keys=True))
    return 0


def report_mfa(args) -> int:
    directory = Path(args.state_dir)
    _, session = _state_and_session(args, directory)
    status = _status(args, directory, session)
    completed = subprocess.run(
        ["docker", "compose", "exec", "-T", "api", "python3", "-m", "app.customer_activation_status"],
        cwd=args.compose_dir, check=True, capture_output=True, text=True,
    )
    local_status = json.loads(completed.stdout.strip().splitlines()[-1])
    if local_status.get("source") != "customer_mfa_database" or not all(
        (local_status.get("enabled"), local_status.get("verified_at"), local_status.get("recovery_codes_generated"))
    ):
        raise RuntimeError("local customer MFA has not completed its verified enrolment ceremony")
    body = {"enabled": True, "method": "totp", "verified_at": local_status["verified_at"],
            "recovery_codes_generated": True, "local_security_version": int(local_status["local_security_version"])}
    path = f"/v1/activations/{session['activation_id']}/mfa-status"
    response, _ = _request_authenticated(
        args, directory, session, method="PUT", path=path, body=body,
        operation="MFA status", retry_deadline=time.monotonic() + CENTRAL_RETRY_SECONDS,
        extra_headers={"If-Match": f'"{status.get("version", session.get("version", 1))}"'},
    )
    print(json.dumps(response, sort_keys=True))
    return 0


def complete_activation(args) -> int:
    directory = Path(args.state_dir)
    _, session = _state_and_session(args, directory)
    status = _status(args, directory, session)
    body = {"acknowledge_terms": True}
    path = f"/v1/activations/{session['activation_id']}/complete"
    response, _ = _request_authenticated(
        args, directory, session, method="POST", path=path, body=body,
        operation="activation completion", retry_deadline=time.monotonic() + CENTRAL_RETRY_SECONDS,
        extra_headers={"If-Match": f'"{status.get("version", session.get("version", 1))}"'},
    )
    print(json.dumps(response, sort_keys=True))
    return 0


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
    reserve_parser = sub.add_parser("reserve-hostname")
    reserve_parser.add_argument("--nickname", required=True)
    reserve_parser.add_argument("--public-ip", dest="public_ipv4", required=True)
    reserve_parser.add_argument("--challenge-root", default="/var/www/letsencrypt")
    reserve_parser.add_argument("--wait-seconds", type=int, default=300)
    https_parser = sub.add_parser("report-https")
    https_parser.add_argument("--hostname", required=True)
    https_parser.add_argument("--certificate", required=True)
    https_parser.add_argument("--challenge-root", default="/var/www/letsencrypt")
    profile_parser = sub.add_parser("report-profile")
    profile_parser.add_argument("--full-name", required=True)
    profile_parser.add_argument("--town-city", required=True)
    profile_parser.add_argument("--country-code", required=True)
    mfa_parser = sub.add_parser("report-mfa")
    mfa_parser.add_argument("--compose-dir", default="/opt/laymatched")
    status_parser = sub.add_parser("status")
    sub.add_parser("complete")
    args = parser.parse_args()
    if args.command == "bootstrap":
        return bootstrap(args)
    if args.command == "heartbeat":
        return heartbeat(args)
    if args.command == "report-https":
        return report_https(args)
    if args.command == "report-profile":
        return report_profile(args)
    if args.command == "report-mfa":
        return report_mfa(args)
    if args.command == "status":
        return activation_status(args)
    if args.command == "complete":
        return complete_activation(args)
    return reserve_hostname(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"central recognition error: {error}", file=sys.stderr)
        raise SystemExit(1)
