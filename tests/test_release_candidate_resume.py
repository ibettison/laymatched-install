import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "tools/release_candidate_resume.py"
REGISTRY = "registry.example"
SHA = "a" * 40
API = "sha256:" + "b" * 64
WEB = "sha256:" + "c" * 64


def manifest(version="v0.2.0-rc.1", api=API):
    return {
        "candidate_version": version,
        "release_version": "v0.2.0",
        "source_sha": SHA,
        "api_image_digest": api,
        "web_image_digest": WEB,
        "registry_url": REGISTRY,
        "api_image": f"{REGISTRY}/laymatched-api-staging@{api}",
        "web_image": f"{REGISTRY}/laymatched-web-staging@{WEB}",
    }


def setup(tmp_path, stage="profile_pending"):
    selected = tmp_path / "selected.json"
    saved = tmp_path / "saved.json"
    selected.write_text(json.dumps(manifest()))
    saved.write_text(json.dumps(manifest()))
    env = tmp_path / ".env"
    env.write_text("\n".join([
        "APP_VERSION=v0.2.0-rc.1", f"REGISTRY_URL={REGISTRY}",
        f"API_IMAGE_REF={REGISTRY}/laymatched-api-staging@{API}",
        f"WEB_IMAGE_REF={REGISTRY}/laymatched-web-staging@{WEB}", f"RELEASE_SOURCE_SHA={SHA}",
        "ACTIVATION_SERVICE_URL=https://activation.example", "CUSTOMER_NICKNAME=customer-one",
        "CUSTOMER_HOSTNAME=customer-one.matched.laysports.co.uk", "",
    ]))
    installation_id = tmp_path / "installation-id"
    installation_id.write_text("12345678-1234-1234-1234-123456789abc\n")
    state = tmp_path / "state.json"
    state.write_text(json.dumps({"schema_version": 1, "installation_id": installation_id.read_text().strip(),
                                "stage": stage, "revision": 8, "updated_at": "now", "last_error": None}))
    session = tmp_path / "session.json"
    session.write_text(json.dumps({"activation_id": "activation-1", "access_token": "opaque"}))
    return [sys.executable, str(HELPER), str(selected), str(saved), str(env), str(installation_id), str(state), str(session)]


def test_same_rc_and_provable_mfa_handoff_can_resume(tmp_path):
    assert subprocess.run(setup(tmp_path), capture_output=True).returncode == 0


def test_different_candidate_or_mismatched_state_is_rejected(tmp_path):
    args = setup(tmp_path)
    Path(args[2]).write_text(json.dumps(manifest(api="sha256:" + "d" * 64)))
    assert subprocess.run(args, capture_output=True).returncode != 0
    args = setup(tmp_path)
    Path(args[5]).write_text(Path(args[5]).read_text().replace("12345678-1234-1234-1234-123456789abc", "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
    assert subprocess.run(args, capture_output=True).returncode != 0


def test_completed_or_unrelated_installation_remains_rejected(tmp_path):
    args = setup(tmp_path, stage="active")
    assert subprocess.run(args, capture_output=True).returncode != 0
    args = setup(tmp_path, stage="profile_pending")
    Path(args[3]).write_text(Path(args[3]).read_text().replace("v0.2.0-rc.1", "v0.2.0"))
    assert subprocess.run(args, capture_output=True).returncode != 0
