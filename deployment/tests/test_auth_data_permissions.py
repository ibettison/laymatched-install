import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


class AuthDataPermissionsTest(unittest.TestCase):
    def test_runtime_state_uses_reserved_non_root_identity(self):
        dockerfile = (REPOSITORY_ROOT / "auth-api" / "Dockerfile").read_text()
        setup_script = (
            REPOSITORY_ROOT / "deployment" / "scripts" / "laymatched-dir-setup"
        ).read_text()

        self.assertIn("chown 2001:2001 /data", dockerfile)
        self.assertIn("USER 2001:2001", dockerfile)
        self.assertIn("AUTH_SERVICE_UID=2001", setup_script)
        self.assertIn("AUTH_SERVICE_GID=2001", setup_script)
        self.assertIn('if [ "$d" = "${AUTH_DATA_DIR}" ]', setup_script)
        self.assertIn('chown "${AUTH_SERVICE_UID}:${AUTH_SERVICE_GID}" "$d"', setup_script)
        self.assertNotIn('chown -R "${AUTH_SERVICE_UID}:${AUTH_SERVICE_GID}" "$d"', setup_script)
        self.assertIn('chown root:root "$d"', setup_script)
        self.assertIn('getent passwd "$AUTH_SERVICE_UID"', setup_script)
        self.assertIn('getent group "$AUTH_SERVICE_GID"', setup_script)
        self.assertIn('id -u laymatched-deploy', setup_script)
        self.assertNotRegex(dockerfile, r"USER\s+0(?::0)?")

    def test_approval_metadata_is_outside_service_writable_state(self):
        setup_script = (
            REPOSITORY_ROOT / "deployment" / "scripts" / "laymatched-dir-setup"
        ).read_text()
        for compose_name in (
            "docker-compose.yml",
            "docker-compose-bootstrap.yml",
            "docker-compose-production.yml",
        ):
            compose = (REPOSITORY_ROOT / "deployment" / compose_name).read_text()
            self.assertIn("APPROVED_VERSION_PATH=/approval/approved_version.txt", compose)
            self.assertIn("approval-data:/approval:ro", compose)
            self.assertIn("device: /opt/laymatched-auth/approval", compose)

        self.assertIn('AUTH_APPROVAL_DIR="${AUTH_ROOT}/approval"', setup_script)
        self.assertIn('AUTH_APPROVAL_FILE="${AUTH_APPROVAL_DIR}/approved_version.txt"', setup_script)
        self.assertIn('chown root:root "${AUTH_APPROVAL_FILE}"', setup_script)
        self.assertIn('chmod 644 "${AUTH_APPROVAL_FILE}"', setup_script)
        self.assertIn('chmod 755 "${AUTH_APPROVAL_DIR}"', setup_script)
        self.assertIn('mv "${AUTH_DATA_DIR}/approved_version.txt" "${AUTH_APPROVAL_FILE}"', setup_script)
        self.assertIn('Refusing to migrate conflicting approved release records', setup_script)

    def test_runtime_file_modes_are_explicit(self):
        setup_script = (
            REPOSITORY_ROOT / "deployment" / "scripts" / "laymatched-dir-setup"
        ).read_text()
        self.assertIn("auth-tokens.db auth-tokens.db-wal auth-tokens.db-shm private.pem", setup_script)
        self.assertIn('chmod 600 "$path"', setup_script)
        self.assertIn("public.pem auth-public.pem auth-cert.pem", setup_script)
        self.assertIn('chmod 644 "$path"', setup_script)


if __name__ == "__main__":
    unittest.main()
