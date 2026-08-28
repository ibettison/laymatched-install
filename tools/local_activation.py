#!/usr/bin/env python3
"""Root-owned local activation journal and Ed25519 key command service."""
from __future__ import annotations
import argparse, base64, json, os, subprocess, sys, tempfile
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

STAGES = ("installed", "authorized", "nickname_reserved", "dns_pending", "dns_ready", "https_pending", "profile_pending", "mfa_pending", "active")
SECRET_FRAGMENTS = ("token", "secret", "private", "password", "credential", "recovery")

class StateError(RuntimeError): pass
def now(): return datetime.now(UTC).isoformat().replace("+00:00", "Z")

def validate(value: Any) -> dict[str, Any]:
    expected = {"schema_version", "installation_id", "stage", "revision", "updated_at", "last_error"}
    if not isinstance(value, dict) or set(value) != expected or value.get("schema_version") != 1:
        raise StateError("activation state does not match schema version 1")
    if not isinstance(value["installation_id"], str) or not value["installation_id"] or value["stage"] not in STAGES:
        raise StateError("invalid installation identity or stage")
    if not isinstance(value["revision"], int) or isinstance(value["revision"], bool) or value["revision"] < 1:
        raise StateError("invalid revision")
    if not isinstance(value["updated_at"], str) or not value["updated_at"]:
        raise StateError("invalid update timestamp")
    if value["last_error"] is not None:
        error = value["last_error"]
        if not isinstance(error, dict) or set(error) != {"code", "retryable"}:
            raise StateError("invalid error state")
        if not isinstance(error["code"], str) or not error["code"] or not isinstance(error["retryable"], bool):
            raise StateError("invalid error state")
    serialized = json.dumps(value, sort_keys=True).lower()
    if any(f'"{fragment}' in serialized for fragment in SECRET_FRAGMENTS):
        raise StateError("secret-bearing fields are forbidden from local state")
    return value

class Journal:
    def __init__(self, directory: Path):
        self.directory, self.current, self.previous = directory, directory / "state.json", directory / "state.previous.json"
    def ensure_directory(self):
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700); os.chmod(self.directory, 0o700)
    def _load(self, path):
        try:
            with path.open(encoding="utf-8") as handle: return validate(json.load(handle))
        except (OSError, json.JSONDecodeError, StateError) as error: raise StateError(f"invalid activation journal {path.name}") from error
    def read(self, recover=True):
        try: return self._load(self.current)
        except StateError:
            if not recover or not self.previous.exists(): raise
            restored = self._load(self.previous); self.write(restored, preserve=False); return restored
    def write(self, state, preserve=True):
        state = validate(state); self.ensure_directory(); fd, temporary = tempfile.mkstemp(prefix=".state.", dir=self.directory); path = Path(temporary)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(state, handle, sort_keys=True, separators=(",", ":")); handle.write("\n"); handle.flush(); os.fsync(handle.fileno())
            if preserve and self.current.exists(): os.replace(self.current, self.previous); os.chmod(self.previous, 0o600)
            os.replace(path, self.current); os.chmod(self.current, 0o600)
            directory_fd = os.open(self.directory, os.O_RDONLY)
            try: os.fsync(directory_fd)
            finally: os.close(directory_fd)
        finally: path.unlink(missing_ok=True)
    def init(self, installation_id):
        if self.current.exists():
            state = self.read()
            if state["installation_id"] != installation_id: raise StateError("journal belongs to a different installation")
            return state
        state = {"schema_version": 1, "installation_id": installation_id, "stage": "installed", "revision": 1, "updated_at": now(), "last_error": None}
        self.write(state); return state
    def advance(self, stage):
        current = self.read()
        if stage not in STAGES or STAGES.index(stage) < STAGES.index(current["stage"]): raise StateError("invalid backward or unknown stage transition")
        if stage == current["stage"]: return current
        updated = {**current, "stage": stage, "revision": current["revision"] + 1, "updated_at": now(), "last_error": None}; self.write(updated); return updated

class KeyService:
    def __init__(self, directory):
        self.directory, self.private, self.public = directory, directory / "installation-key.pem", directory / "installation-key.pub.pem"
    def ensure(self):
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700); os.chmod(self.directory, 0o700)
        if self.private.exists():
            if self.private.stat().st_mode & 0o077: raise StateError("installation private key permissions are unsafe")
            if not self.public.exists():
                public_tmp = self.directory / ".installation-key.pub.pem.new"
                try:
                    subprocess.run(["openssl", "pkey", "-in", str(self.private), "-pubout", "-out", str(public_tmp)], check=True, capture_output=True)
                    os.chmod(public_tmp, 0o644); os.replace(public_tmp, self.public)
                except (OSError, subprocess.CalledProcessError) as error: raise StateError("failed to recover installation public key") from error
                finally: public_tmp.unlink(missing_ok=True)
            return self.public.read_bytes()
        private_tmp, public_tmp = self.directory / ".installation-key.pem.new", self.directory / ".installation-key.pub.pem.new"
        try:
            subprocess.run(["openssl", "genpkey", "-algorithm", "ED25519", "-out", str(private_tmp)], check=True, capture_output=True); os.chmod(private_tmp, 0o600)
            subprocess.run(["openssl", "pkey", "-in", str(private_tmp), "-pubout", "-out", str(public_tmp)], check=True, capture_output=True); os.chmod(public_tmp, 0o644)
            os.replace(private_tmp, self.private); os.replace(public_tmp, self.public); return self.public.read_bytes()
        except (OSError, subprocess.CalledProcessError) as error: raise StateError("failed to create Ed25519 installation key") from error
        finally: private_tmp.unlink(missing_ok=True); public_tmp.unlink(missing_ok=True)
    def sign(self, message):
        self.ensure()
        fd, message_name = tempfile.mkstemp(prefix=".signing-input.", dir=self.directory)
        message_path = Path(message_name)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "wb") as handle: handle.write(message)
            return subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", str(self.private), "-in", str(message_path)], check=True, capture_output=True).stdout
        except (OSError, subprocess.CalledProcessError) as error:
            raise StateError("failed to sign with installation key") from error
        finally: message_path.unlink(missing_ok=True)

def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--state-dir", type=Path, default=Path("/var/lib/laymatched/activation")); commands = parser.add_subparsers(dest="command", required=True)
    init = commands.add_parser("init"); init.add_argument("installation_id")
    advance = commands.add_parser("advance"); advance.add_argument("stage", choices=STAGES)
    commands.add_parser("status"); sign = commands.add_parser("sign"); sign.add_argument("message"); args = parser.parse_args()
    if os.geteuid() != 0 and not os.getenv("LAYMATCHED_ALLOW_NON_ROOT_TEST"): raise StateError("local activation administration must run as root")
    journal, keys = Journal(args.state_dir), KeyService(args.state_dir)
    if args.command == "init": result = journal.init(args.installation_id); keys.ensure(); print(json.dumps(result, sort_keys=True))
    elif args.command == "advance": print(json.dumps(journal.advance(args.stage), sort_keys=True))
    elif args.command == "status": print(json.dumps(journal.read(), sort_keys=True))
    else: print(base64.b64encode(keys.sign(args.message.encode())).decode())
    return 0

if __name__ == "__main__":
    try: raise SystemExit(main())
    except StateError as error: print(f"local activation error: {error}", file=sys.stderr); raise SystemExit(1)
