import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


class AuthDataPermissionsTest(unittest.TestCase):
    def test_auth_image_and_host_setup_share_non_root_data_owner(self):
        dockerfile = (REPOSITORY_ROOT / "auth-api" / "Dockerfile").read_text()
        setup_script = (
            REPOSITORY_ROOT / "deployment" / "scripts" / "laymatched-dir-setup"
        ).read_text()

        self.assertIn("chown 2001:2001 /data", dockerfile)
        self.assertIn("USER 2001:2001", dockerfile)
        self.assertIn("AUTH_SERVICE_UID=2001", setup_script)
        self.assertIn("AUTH_SERVICE_GID=2001", setup_script)
        self.assertIn('if [ "$d" = "/opt/laymatched-auth/data" ]', setup_script)
        self.assertIn('chown -R "${AUTH_SERVICE_UID}:${AUTH_SERVICE_GID}" "$d"', setup_script)
        self.assertIn('chown root:root "$d"', setup_script)
        self.assertIn('getent passwd "$AUTH_SERVICE_UID"', setup_script)
        self.assertIn('getent group "$AUTH_SERVICE_GID"', setup_script)
        self.assertIn('id -u laymatched-deploy', setup_script)
        self.assertNotRegex(dockerfile, r"USER\s+0(?::0)?")


if __name__ == "__main__":
    unittest.main()
