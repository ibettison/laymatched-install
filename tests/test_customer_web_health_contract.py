import os
import re
import unittest
from pathlib import Path


INSTALLER_ROOT = Path(__file__).parents[1]


class CustomerWebHealthContractTests(unittest.TestCase):
    def test_both_generated_customer_compose_files_probe_customer_health(self):
        installer = (INSTALLER_ROOT / "install.sh").read_text()
        compose_files = re.findall(
            r"(?ms)cat > /opt/laymatched/docker-compose\.yml <<'COMPOSE_EOF'\n(.*?)^COMPOSE_EOF$",
            installer,
        )
        self.assertEqual(len(compose_files), 2, "fresh and resume Compose definitions should both be present")
        for compose in compose_files:
            with self.subTest(compose_definition=compose[:40]):
                web = compose.split("  web:\n", 1)[1].split("\nvolumes:", 1)[0]
                healthcheck = web.split("    healthcheck:\n", 1)[1].split("    networks:", 1)[0]
                self.assertIn("http://127.0.0.1/health", healthcheck)
                self.assertNotIn("/app", healthcheck)

    def test_customer_and_owner_image_routing_contracts_remain_distinct(self):
        application = os.getenv("LAYMATCHED_APP_REPO")
        if not application:
            self.skipTest("set LAYMATCHED_APP_REPO to the exact application revision for cross-repository checks")
        application_root = Path(application)
        dockerfile = (application_root / "frontend/Dockerfile").read_text()
        customer = (application_root / "frontend/nginx.customer.conf").read_text()
        owner = (application_root / "frontend/nginx.conf").read_text()

        self.assertIn("FROM nginx:1.27-alpine AS customer", dockerfile)
        self.assertIn("COPY nginx.customer.conf /etc/nginx/conf.d/default.conf", dockerfile)
        self.assertIn("FROM nginx:1.27-alpine AS central", dockerfile)
        self.assertIn("COPY nginx.conf /etc/nginx/conf.d/default.conf", dockerfile)

        self.assertRegex(
            customer,
            r"(?s)location = /health\s*\{\s*proxy_pass http://api:8000/health;\s*\}",
        )
        self.assertRegex(customer, r"(?s)location = /app\s*\{\s*return 404;\s*\}")
        self.assertRegex(customer, r"(?s)location \^~ /app/\s*\{\s*return 404;\s*\}")
        self.assertRegex(owner, r"(?s)location = /app\s*\{\s*return 301 /app/;\s*\}")
        self.assertRegex(owner, r"(?s)location /app/\s*\{\s*try_files \$uri \$uri/ /app/index.html;\s*\}")


if __name__ == "__main__":
    unittest.main()
