import os
import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).parents[1]


def test_activation_contract_and_installer_use_the_central_app_hostname() -> None:
    contract = json.loads((ROOT / "contracts/activation/openapi.json").read_text())
    assert contract["servers"][0]["url"] == "https://matched.laysports.co.uk"
    for compose in (
        ROOT / "deployment/docker-compose.yml",
        ROOT / "deployment/docker-compose-bootstrap.yml",
        ROOT / "deployment/docker-compose-production.yml",
    ):
        assert "ACTIVATION_SERVICE_URL=https://matched.laysports.co.uk" in compose.read_text()


def test_nickname_normalization_and_protected_names() -> None:
    helper = ROOT / "tools/customer_hostname.py"
    valid = subprocess.run(["python3", str(helper), "  Winning-Way "], capture_output=True, text=True)
    assert valid.returncode == 0
    assert valid.stdout.strip() == "winning-way.matched.laysports.co.uk"

    for value in ("auth", "registry", "www", "bad name", "-invalid", "a"):
        result = subprocess.run(["python3", str(helper), value], capture_output=True, text=True)
        assert result.returncode != 0


def test_installer_delivers_hostname_and_https_helpers_without_dns_credentials() -> None:
    installer = (ROOT / "install.sh").read_text()
    assert 'customer_hostname.py" /opt/laymatched/customer_hostname.py' in installer
    assert 'configure-customer-https.sh" /opt/laymatched/configure-customer-https.sh' in installer
    assert "CLOUDFLARE" not in installer
    assert "CUSTOMER_HOSTNAME" in installer
    assert "ACTIVATION_SERVICE_URL" in installer
    assert "reserve-hostname" in installer
    assert "report-https" in installer
    assert "CLOUDFLARE_API_TOKEN" not in installer


def test_fresh_install_prepares_challenge_listener_before_central_network_update() -> None:
    installer = (ROOT / "install.sh").read_text()
    prepare = installer.index("--network-only")
    central_network = installer.index("reserve-hostname")
    assert prepare < central_network


def test_network_only_listener_exposes_only_the_bound_challenge_route(tmp_path: Path) -> None:
    nginx_root = tmp_path / "nginx"
    (nginx_root / "sites-available").mkdir(parents=True)
    (nginx_root / "sites-enabled").mkdir()
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "nginx").write_text("#!/bin/sh\nexit 0\n")
    (fake_bin / "systemctl").write_text("#!/bin/sh\nexit 0\n")
    for command in ("nginx", "systemctl"):
        (fake_bin / command).chmod(0o755)
    environment = {
        **os.environ,
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "LAYMATCHED_INSTALLER_DIR": str(ROOT),
        "LAYMATCHED_HOSTNAME_HELPER": str(ROOT / "tools" / "customer_hostname.py"),
        "LAYMATCHED_NGINX_ROOT": str(nginx_root),
        "LAYMATCHED_NGINX_SITE": str(nginx_root / "sites-available" / "laymatched"),
        "LAYMATCHED_CHALLENGE_ROOT": str(tmp_path / "challenge"),
        "ACTIVATION_STATE_DIR": str(tmp_path / "state"),
    }
    result = subprocess.run(
        ["bash", str(ROOT / "scripts/configure-customer-https.sh"), "--network-only", "winning-way.matched.laysports.co.uk"],
        env=environment, capture_output=True, text=True, check=False,
    )
    assert result.returncode == 0, result.stderr
    config = (nginx_root / "sites-available" / "laymatched").read_text()
    assert "location ^~ /.well-known/laymatched-network/" in config
    assert "try_files $uri =404;" in config
    assert "location / { return 404; }" in config
    assert "proxy_pass" not in config


def test_updater_refreshes_helpers_without_assigning_legacy_hostname() -> None:
    updater = (ROOT / "update.sh").read_text()
    assert "install_provisioning_helpers" in updater
    assert "base64 -d | tar -xzf" in updater
    assert "customer_hostname.py" in updater
    assert "configure-customer-https.sh" in updater
    assert "recognition_client.py" in updater
    assert "install_existing_https_renewal_hook" in updater
    assert "legacy installations" in updater.lower()


def test_old_updater_embedded_helper_bundle_is_reproducible_and_atomic(tmp_path: Path) -> None:
    updater = (ROOT / "update.sh").read_text()
    match = __import__("re").search(
        r"(install_provisioning_helpers\(\) \{.*?\n\})\n\nCANDIDATE_ENV_FILE",
        updater,
        flags=__import__("re").DOTALL,
    )
    assert match, "embedded helper installer function is missing"
    install_root = tmp_path / "opt"
    install_root.mkdir()
    script = f"{match.group(1)}\nSCRIPT_DIR={tmp_path / 'no-sidecars'}\nLAYMATCHED_INSTALL_ROOT={install_root}\ninstall_provisioning_helpers"
    result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stderr
    current = install_root / "provisioning-current"
    assert current.is_symlink()
    assert (current / "customer_hostname.py").is_file()
    assert (current / "configure-customer-https.sh").is_file()
    assert (current / "recognition_client.py").is_file()
    assert "renewal-hooks" in (current / "configure-customer-https.sh").read_text()
    assert (current / "customer_hostname.py").read_bytes() == (ROOT / "tools/customer_hostname.py").read_bytes()
    assert (current / "configure-customer-https.sh").read_bytes() == (ROOT / "scripts/configure-customer-https.sh").read_bytes()
    assert (current / "recognition_client.py").read_bytes() == (ROOT / "tools/recognition_client.py").read_bytes()
    assert "CLOUDFLARE_API_TOKEN" not in updater


def test_helper_bundle_pointer_exposes_one_complete_generation(tmp_path: Path) -> None:
    updater = (ROOT / "update.sh").read_text()
    assert "provisioning-current" in updater
    assert "mv -Tf" in updater
    assert "mixture of generations" in updater


def test_mock_https_configuration_renders_customer_only_http_proxy(tmp_path: Path) -> None:
    nginx_root = tmp_path / "nginx"
    (nginx_root / "sites-available").mkdir(parents=True)
    (nginx_root / "sites-enabled").mkdir()
    challenge_root = tmp_path / "challenge"
    state_dir = tmp_path / "state"
    renewal_hook = tmp_path / "renewal-hooks" / "laymatched-https-report.sh"
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "nginx").write_text("#!/bin/sh\nexit 0\n")
    (fake_bin / "systemctl").write_text("#!/bin/sh\nexit 0\n")
    for command in ("nginx", "systemctl"):
        (fake_bin / command).chmod(0o755)
    environment = {
        **os.environ,
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "LAYMATCHED_INSTALLER_DIR": str(ROOT),
        "LAYMATCHED_HOSTNAME_HELPER": str(ROOT / "tools" / "customer_hostname.py"),
        "LAYMATCHED_NGINX_ROOT": str(nginx_root),
        "LAYMATCHED_NGINX_SITE": str(nginx_root / "sites-available" / "laymatched"),
        "LAYMATCHED_CHALLENGE_ROOT": str(challenge_root),
        "LAYMATCHED_ACME_MODE": "mock",
        "ACTIVATION_STATE_DIR": str(state_dir),
        "LAYMATCHED_RENEWAL_HOOK": str(renewal_hook),
    }
    result = subprocess.run(
        ["bash", str(ROOT / "scripts/configure-customer-https.sh"), "winning-way.matched.laysports.co.uk"],
        env=environment, capture_output=True, text=True, check=False,
    )
    assert result.returncode == 0, result.stderr
    config = (nginx_root / "sites-available" / "laymatched").read_text()
    assert "server_name winning-way.matched.laysports.co.uk;" in config
    assert "proxy_pass http://127.0.0.1:8080;" in config
    assert "laymatched-network" in config
    assert "laymatched-https" in config
    assert "CLOUDFLARE" not in config
    hook = renewal_hook.read_text()
    assert "report-https" in hook
    assert "certificate_not_after" not in hook


def test_failed_acme_restores_existing_http_placeholder(tmp_path: Path) -> None:
    nginx_root = tmp_path / "nginx"
    (nginx_root / "sites-available").mkdir(parents=True)
    (nginx_root / "sites-enabled").mkdir()
    site = nginx_root / "sites-available" / "laymatched"
    existing = "existing-https-config\n"
    site.write_text(existing)
    challenge_root = tmp_path / "challenge"
    state_dir = tmp_path / "state"
    renewal_hook = tmp_path / "renewal-hooks" / "laymatched-https-report.sh"
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "nginx").write_text("#!/bin/sh\nexit 0\n")
    (fake_bin / "systemctl").write_text("#!/bin/sh\nexit 0\n")
    (fake_bin / "certbot").write_text("#!/bin/sh\nexit 42\n")
    for command in ("nginx", "systemctl", "certbot"):
        (fake_bin / command).chmod(0o755)
    environment = {
        **os.environ,
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "LAYMATCHED_INSTALLER_DIR": str(ROOT),
        "LAYMATCHED_HOSTNAME_HELPER": str(ROOT / "tools" / "customer_hostname.py"),
        "LAYMATCHED_NGINX_ROOT": str(nginx_root),
        "LAYMATCHED_NGINX_SITE": str(site),
        "LAYMATCHED_CHALLENGE_ROOT": str(challenge_root),
        "LAYMATCHED_ACME_MODE": "real",
        "ACTIVATION_STATE_DIR": str(state_dir),
        "LAYMATCHED_RENEWAL_HOOK": str(renewal_hook),
    }
    result = subprocess.run(
        ["bash", str(ROOT / "scripts/configure-customer-https.sh"), "winning-way.matched.laysports.co.uk"],
        env=environment, capture_output=True, text=True, check=False,
    )
    assert result.returncode != 0
    assert site.read_text() == existing


def test_failed_acme_preserves_existing_https_configuration(tmp_path: Path) -> None:
    nginx_root = tmp_path / "nginx"
    (nginx_root / "sites-available").mkdir(parents=True)
    (nginx_root / "sites-enabled").mkdir()
    site = nginx_root / "sites-available" / "laymatched"
    existing = "server {\n    listen 443 ssl;\n    ssl_certificate /existing/fullchain.pem;\n}\n"
    site.write_text(existing)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "nginx").write_text("#!/bin/sh\nexit 0\n")
    (fake_bin / "systemctl").write_text("#!/bin/sh\nexit 0\n")
    (fake_bin / "certbot").write_text("#!/bin/sh\nexit 42\n")
    for command in ("nginx", "systemctl", "certbot"):
        (fake_bin / command).chmod(0o755)
    environment = {
        **os.environ,
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "LAYMATCHED_INSTALLER_DIR": str(ROOT),
        "LAYMATCHED_HOSTNAME_HELPER": str(ROOT / "tools" / "customer_hostname.py"),
        "LAYMATCHED_NGINX_ROOT": str(nginx_root),
        "LAYMATCHED_NGINX_SITE": str(site),
        "LAYMATCHED_CHALLENGE_ROOT": str(tmp_path / "challenge"),
        "LAYMATCHED_ACME_MODE": "real",
        "ACTIVATION_STATE_DIR": str(tmp_path / "state"),
        "LAYMATCHED_RENEWAL_HOOK": str(tmp_path / "hook"),
    }
    result = subprocess.run(
        ["bash", str(ROOT / "scripts/configure-customer-https.sh"), "winning-way.matched.laysports.co.uk"],
        env=environment, capture_output=True, text=True, check=False,
    )
    assert result.returncode != 0
    assert site.read_text() == existing


def test_https_retry_repairs_missing_tls_support_and_preserves_existing_certificate(tmp_path: Path) -> None:
    nginx_root = tmp_path / "nginx"
    (nginx_root / "sites-available").mkdir(parents=True)
    (nginx_root / "sites-enabled").mkdir()
    site = nginx_root / "sites-available" / "laymatched"
    letsencrypt_root = tmp_path / "letsencrypt"
    certificate_dir = letsencrypt_root / "live" / "winning-way.matched.laysports.co.uk"
    certificate_dir.mkdir(parents=True)
    (certificate_dir / "cert.pem").write_text("existing certificate\n")
    (certificate_dir / "fullchain.pem").write_text("existing full chain\n")
    (certificate_dir / "privkey.pem").write_text("existing private key\n")
    original_certificates = {
        name: (certificate_dir / name).read_bytes()
        for name in ("cert.pem", "fullchain.pem", "privkey.pem")
    }
    challenge_root = tmp_path / "challenge"
    state_dir = tmp_path / "state"
    renewal_hook = tmp_path / "renewal-hooks" / "laymatched-https-report.sh"
    certbot_args = tmp_path / "certbot-args"
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "nginx").write_text(
        "#!/bin/sh\n"
        f"site='{site}'\n"
        f"tls='{letsencrypt_root}/options-ssl-nginx.conf'\n"
        f"dhparams='{letsencrypt_root}/ssl-dhparams.pem'\n"
        "if grep -q 'listen 443' \"$site\"; then\n"
        "  test -s \"$tls\" || exit 71\n"
        "  test -s \"$dhparams\" || exit 75\n"
        "  grep -q 'ssl_certificate ' \"$site\" || exit 72\n"
        "  test -s \"$(dirname \"$tls\")/live/winning-way.matched.laysports.co.uk/fullchain.pem\" || exit 73\n"
        "  grep -q 'ssl_dhparam ' \"$site\" || exit 74\n"
        "fi\n"
        "exit 0\n"
    )
    (fake_bin / "systemctl").write_text("#!/bin/sh\nexit 0\n")
    (fake_bin / "certbot").write_text(
        "#!/bin/sh\n"
        f"printf '%s\\n' \"$@\" > '{certbot_args}'\n"
        f"test -s '{letsencrypt_root}/options-ssl-nginx.conf' || exit 81\n"
        f"test -s '{certificate_dir}/cert.pem' || exit 82\n"
        "exit 0\n"
    )
    for command in ("nginx", "systemctl", "certbot"):
        (fake_bin / command).chmod(0o755)
    environment = {
        **os.environ,
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "LAYMATCHED_INSTALLER_DIR": str(ROOT),
        "LAYMATCHED_HOSTNAME_HELPER": str(ROOT / "tools" / "customer_hostname.py"),
        "LAYMATCHED_NGINX_ROOT": str(nginx_root),
        "LAYMATCHED_NGINX_SITE": str(site),
        "LAYMATCHED_CHALLENGE_ROOT": str(challenge_root),
        "LAYMATCHED_LETSENCRYPT_DIR": str(letsencrypt_root),
        "LAYMATCHED_ACME_MODE": "real",
        "ACTIVATION_STATE_DIR": str(state_dir),
        "LAYMATCHED_RENEWAL_HOOK": str(renewal_hook),
    }
    result = subprocess.run(
        ["bash", str(ROOT / "scripts/configure-customer-https.sh"), "winning-way.matched.laysports.co.uk"],
        env=environment, capture_output=True, text=True, check=False,
    )
    assert result.returncode == 0, result.stderr
    options = letsencrypt_root / "options-ssl-nginx.conf"
    dhparams = letsencrypt_root / "ssl-dhparams.pem"
    assert options.is_file()
    assert "ssl_protocols TLSv1.2 TLSv1.3;" in options.read_text()
    assert dhparams.is_file() and dhparams.stat().st_size > 0
    assert str(options) in site.read_text()
    assert str(dhparams) in site.read_text()
    https_server = site.read_text().split("server {", 2)[2]
    challenge_location = https_server.split("location / {", 1)[0]
    assert "listen 443 ssl http2;" in https_server
    assert "location ^~ /.well-known/laymatched-https/ {" in challenge_location
    assert f"root {challenge_root};" in challenge_location
    assert "default_type text/plain;" in challenge_location
    assert "try_files $uri =404;" in challenge_location
    assert "proxy_pass" not in challenge_location
    assert "proxy_pass http://127.0.0.1:8080;" in https_server
    assert {name: (certificate_dir / name).read_bytes() for name in original_certificates} == original_certificates
    assert "--deploy-hook" not in certbot_args.read_text()
    hook = renewal_hook.read_text()
    assert "nginx -t && systemctl reload nginx" in hook
    assert "report-https" in hook
