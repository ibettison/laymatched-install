import re
import unittest
from pathlib import Path


DEPLOYMENT_DIR = Path(__file__).resolve().parents[1]
NGINX_DIR = DEPLOYMENT_DIR / "nginx"


def location_body(config: str, modifier: str, path: str) -> str:
    pattern = rf"location\s+{re.escape(modifier + ' ') if modifier else ''}{re.escape(path)}\s*\{{([^{{}}]*)\}}"
    match = re.search(pattern, config, re.MULTILINE)
    if match is None:
        raise AssertionError(f"location {modifier} {path} not found")
    return match.group(1)


def location_bodies(config: str, modifier: str, path: str) -> list[str]:
    pattern = rf"location\s+{re.escape(modifier + ' ') if modifier else ''}{re.escape(path)}\s*\{{([^{{}}]*)\}}"
    return re.findall(pattern, config, re.MULTILINE)


class HostNginxConfigTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.auth = (NGINX_DIR / "laymatched-auth-final.conf").read_text()
        cls.registry = (NGINX_DIR / "laymatched-registry-final.conf").read_text()
        cls.bootstrap_auth = (NGINX_DIR / "laymatched-auth-bootstrap.conf").read_text()
        cls.bootstrap_registry = (NGINX_DIR / "laymatched-registry-bootstrap.conf").read_text()

    def test_no_invalid_limit_req_off_directives(self):
        for config in (self.auth, self.registry):
            self.assertNotIn("limit_req off", config)

    def test_auth_exemptions_are_exact_and_catch_all_is_rate_limited(self):
        health = location_body(self.auth, "=", "/health")
        jwks = location_body(self.auth, "=", "/.well-known/jwks.json")
        catch_all_locations = location_bodies(self.auth, "", "/")

        self.assertNotIn("limit_req", health)
        self.assertNotIn("limit_req", jwks)
        self.assertTrue(
            any("limit_req zone=auth_limit" in body for body in catch_all_locations)
        )
        self.assertNotRegex(self.auth, r"location\s+/health\s*\{")
        self.assertNotRegex(self.auth, r"location\s+/\.well-known/jwks\.json\s*\{")

    def test_registry_root_is_exact_and_catch_all_is_rate_limited(self):
        registry_root = location_body(self.registry, "=", "/v2/")
        catch_all_locations = location_bodies(self.registry, "", "/")

        self.assertNotIn("limit_req", registry_root)
        self.assertTrue(
            any("limit_req zone=registry_limit" in body for body in catch_all_locations)
        )
        self.assertNotRegex(self.registry, r"location\s+/v2/\s*\{")

    def test_all_proxy_destinations_are_loopback_and_not_duplicated(self):
        expected = {
            self.auth: ("http://127.0.0.1:8443", 3),
            self.registry: ("http://127.0.0.1:5000", 2),
            self.bootstrap_auth: ("http://127.0.0.1:8443", 1),
            self.bootstrap_registry: ("http://127.0.0.1:5000", 1),
        }
        for config, (upstream, count) in expected.items():
            proxy_passes = re.findall(r"proxy_pass\s+([^;]+);", config)
            self.assertEqual(proxy_passes, [upstream] * count)

    def test_final_configs_use_shared_certbot_san_certificate(self):
        certificate_lineage = "/etc/letsencrypt/live/auth.matched.laysports.co.uk"
        for config in (self.auth, self.registry):
            self.assertIn(f"ssl_certificate {certificate_lineage}/fullchain.pem;", config)
            self.assertIn(f"ssl_certificate_key {certificate_lineage}/privkey.pem;", config)


if __name__ == "__main__":
    unittest.main()
