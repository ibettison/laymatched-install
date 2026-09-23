import os
import re
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).parents[1]


def test_fresh_install_uses_authorization_approved_images() -> None:
    installer = (ROOT / "install.sh").read_text()
    auth = installer.index('call_auth_api "$INSTALLER_TOKEN"')
    approved_assignment = installer.index('APP_VERSION="${APPROVED_VERSION}"', auth)
    environment_write = installer.index("APP_VERSION=${APP_VERSION}", approved_assignment)
    fresh_pull = installer.index("docker compose pull", environment_write)
    fresh_start = installer.index("docker compose up -d", fresh_pull)

    assert auth < approved_assignment < environment_write < fresh_pull < fresh_start
    assert "image: ${REGISTRY_URL}/laymatched-api:${APP_VERSION}" in installer
    assert "image: ${REGISTRY_URL}/laymatched-web:${APP_VERSION}" in installer


def test_resume_replaces_stale_version_with_approved_images_before_start() -> None:
    installer = (ROOT / "install.sh").read_text()
    resume = installer.index('log_info "Existing installation detected - re-authorizing for image pull."')
    auth = installer.index('call_auth_api "$INSTALLER_TOKEN"', resume)
    approved_assignment = installer.index('APP_VERSION="${APPROVED_VERSION}"', auth)
    candidate_update = installer.index('sed -i "s/^APP_VERSION=.*/APP_VERSION=${APP_VERSION}/" .env.candidate', approved_assignment)
    pull = installer.index("docker compose --env-file .env.candidate pull", candidate_update)
    recreate = installer.index("docker compose --env-file .env.candidate up -d", pull)

    assert resume < auth < approved_assignment < candidate_update < pull < recreate
    assert "APP_VERSION=v0.1.1" not in installer


def _login_route_function() -> str:
    installer = (ROOT / "install.sh").read_text()
    match = re.search(r"(?ms)^verify_customer_login_route\(\) \{\n.*?^\}", installer)
    assert match, "customer login route check is missing"
    return match.group()


def _run_route_check(tmp_path: Path, response: str, curl_status: int = 0) -> subprocess.CompletedProcess[str]:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    fake_curl = fake_bin / "curl"
    fake_curl.write_text(f"#!/bin/sh\nprintf '%s' '{response}'\nexit {curl_status}\n")
    fake_curl.chmod(0o755)
    script = (
        'CUSTOMER_HOSTNAME="customer.example.invalid"\n'
        'log_info() { :; }\n'
        'log_error() { echo "$1" >&2; exit 1; }\n'
        f"{_login_route_function()}\n"
        "verify_customer_login_route\n"
    )
    return subprocess.run(
        ["bash", "-c", script], env={**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}"},
        capture_output=True, text=True, check=False,
    )


def test_login_route_requires_customer_root_spa_shell(tmp_path: Path) -> None:
    result = _run_route_check(tmp_path, '<html><div id="root"></div></html>')
    assert result.returncode == 0, result.stderr


def test_login_route_rejects_old_image_root_404_without_exposing_response(tmp_path: Path) -> None:
    result = _run_route_check(tmp_path, "old application response", curl_status=22)
    assert result.returncode != 0
    assert "activation remains pending" in result.stderr
    assert "old application response" not in result.stdout + result.stderr


def test_root_route_is_verified_before_profile_or_mfa_onboarding() -> None:
    installer = (ROOT / "install.sh").read_text()
    report_https = installer.index("report-https", installer.index("if [ -n \"${CUSTOMER_HOSTNAME:-}\" ]"))
    route_check = installer.index("verify_customer_login_route", report_https)
    completion = installer.index("complete_central_activation", route_check)
    assert report_https < route_check < completion
    assert 'Open https://${CUSTOMER_HOSTNAME}/, sign in, and complete Authenticator protection.' in installer
    function = _login_route_function()
    assert 'https://${CUSTOMER_HOSTNAME}/' in function
    assert "--resolve \"${CUSTOMER_HOSTNAME}:443:127.0.0.1\"" in function
    assert "<div id=\"root\"></div>" in function
    # The check only reads the route; it cannot rewrite activation state or certs.
    assert not any(command in function for command in ("rm ", "mv ", "sed ", "certbot ", "advance_activation_to"))


def test_failed_root_check_preserves_activation_session_and_existing_certificate(tmp_path: Path) -> None:
    activation_dir = tmp_path / "activation"
    certificate_dir = tmp_path / "letsencrypt" / "live" / "customer.example.invalid"
    activation_dir.mkdir()
    certificate_dir.mkdir(parents=True)
    session = activation_dir / "session.json"
    certificate = certificate_dir / "fullchain.pem"
    session.write_text('{"session_id":"existing-session","stage":"https_pending"}\n')
    certificate.write_text("existing certificate bytes\n")
    original_session = session.read_bytes()
    original_certificate = certificate.read_bytes()

    with tempfile.TemporaryDirectory() as directory:
        result = _run_route_check(Path(directory), "old image response", curl_status=22)

    assert result.returncode != 0
    assert session.read_bytes() == original_session
    assert certificate.read_bytes() == original_certificate
