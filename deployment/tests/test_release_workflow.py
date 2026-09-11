import re
import subprocess
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
ACTIVE_WORKFLOW = ROOT / ".github/workflows/release-to-private-registry.yml"
DEPLOYMENT_WORKFLOW = ROOT / "deployment/workflows/release-to-private-registry.yml"


class ExactShaReleaseWorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = ACTIVE_WORKFLOW.read_text()
        cls.workflow = yaml.load(cls.text, Loader=yaml.BaseLoader)
        cls.steps = cls.workflow["jobs"]["publish"]["steps"]
        cls.steps_by_name = {step["name"]: step for step in cls.steps}
        cls.step_names = [step["name"] for step in cls.steps]

    def test_canonical_workflow_copies_are_identical(self):
        self.assertEqual(self.text, DEPLOYMENT_WORKFLOW.read_text())

    def test_sha_is_required_and_used_for_exact_application_checkout(self):
        inputs = self.workflow["on"]["workflow_dispatch"]["inputs"]
        self.assertEqual(inputs["sha"]["required"], "true")
        self.assertNotIn("default", inputs["sha"])

        checkout = self.steps_by_name["Checkout exact LayMatched application revision"]
        self.assertEqual(checkout["with"]["repository"], "ibettison/layMatchedBetting")
        self.assertEqual(
            checkout["with"]["token"], "${{ secrets.APPLICATION_REPO_TOKEN }}"
        )
        self.assertEqual(checkout["with"]["ref"], "${{ inputs.sha }}")
        self.assertEqual(checkout["with"]["path"], "application")
        self.assertEqual(checkout["with"]["persist-credentials"], "false")

        validation = self.steps_by_name["Validate immutable release inputs"]["run"]
        self.assertIn("^[0-9a-f]{40}$", validation)
        self.assertIn('test -n "$APPLICATION_REPO_TOKEN"', validation)

    def test_checked_out_head_must_equal_requested_sha(self):
        verification = self.steps_by_name["Verify exact application HEAD"]["run"]
        self.assertIn("git -C application rev-parse HEAD", verification)
        self.assertIn('test "$actual_sha" = "$requested_sha"', verification)
        self.assertIn('cat-file -e "${requested_sha}^{commit}"', verification)

    def test_api_and_web_build_from_same_verified_checkout(self):
        api = self.steps_by_name["Build API from exact application SHA"]["run"]
        web = self.steps_by_name["Build Web from exact application SHA"]["run"]
        for command in (api, web):
            self.assertIn("org.opencontainers.image.revision=${{ inputs.sha }}", command)
        self.assertIn("application/backend", api)
        self.assertIn("application/frontend", web)
        self.assertIn("laymatched-api-staging", api)
        self.assertIn("laymatched-web-staging", web)

        local_verification = self.steps_by_name[
            "Verify both local images have the requested revision"
        ]["run"]
        self.assertIn('test "$api_sha" = "$requested_sha"', local_verification)
        self.assertIn('test "$web_sha" = "$requested_sha"', local_verification)
        self.assertIn('test "$api_sha" = "$web_sha"', local_verification)

    def test_candidate_is_owner_verified_before_approval_and_customer_pull_after_promotion(self):
        remove_index = self.step_names.index(
            "Remove local staging tags before owner verification"
        )
        verify_index = self.step_names.index("Pull and verify both private staging images as Owner")
        self.assertLess(remove_index, verify_index)
        approval_index = self.step_names.index("Update approved version on VPS")
        promote_index = self.step_names.index("Promote approved release images to customer repositories")
        installer_index = self.step_names.index("Pull and verify both promoted images with Installer Token")
        self.assertLess(verify_index, approval_index)
        self.assertLess(approval_index, promote_index)
        self.assertLess(promote_index, installer_index)

        verification = self.steps_by_name["Pull and verify both private staging images as Owner"]["run"]
        self.assertIn('docker pull "$api_ref"', verification)
        self.assertIn('docker pull "$web_ref"', verification)
        self.assertIn('test "$api_sha" = "$requested_sha"', verification)
        self.assertIn('test "$web_sha" = "$requested_sha"', verification)
        self.assertIn('test "$api_sha" = "$web_sha"', verification)

        promotion = self.steps_by_name["Promote approved release images to customer repositories"]["run"]
        self.assertIn("laymatched-api-staging", promotion)
        self.assertIn("laymatched-web-staging", promotion)
        self.assertIn("laymatched-api:${{ inputs.version }}", promotion)
        self.assertIn("laymatched-web:${{ inputs.version }}", promotion)
        self.assertIn('docker push "$customer_api"', promotion)
        self.assertIn('docker push "$customer_web"', promotion)

        installer_verification = self.steps_by_name[
            "Pull and verify both promoted images with Installer Token"
        ]["run"]
        self.assertIn("laymatched-api:${{ inputs.version }}", installer_verification)
        self.assertIn("laymatched-web:${{ inputs.version }}", installer_verification)
        self.assertIn('docker pull "$api_ref"', installer_verification)
        self.assertIn('docker pull "$web_ref"', installer_verification)

    def test_candidate_is_not_pushed_to_customer_repositories_before_approval(self):
        approval_index = self.step_names.index("Update approved version on VPS")
        candidate_pushes = [
            (index, step["run"])
            for index, step in enumerate(self.steps)
            if "Push" in step["name"]
        ]
        self.assertTrue(candidate_pushes)
        for index, command in candidate_pushes:
            if index < approval_index:
                self.assertIn("-staging", command)
                self.assertNotIn("laymatched-api:${{ inputs.version }}", command)
                self.assertNotIn("laymatched-web:${{ inputs.version }}", command)

    def test_either_image_failure_prevents_approval(self):
        approval_index = self.step_names.index("Update approved version on VPS")
        required_steps = (
            "Build API from exact application SHA",
            "Build Web from exact application SHA",
            "Push API candidate to owner-only staging",
            "Push Web candidate to owner-only staging",
            "Pull and verify both private staging images as Owner",
        )
        for name in required_steps:
            step = self.steps_by_name[name]
            self.assertLess(self.step_names.index(name), approval_index)
            self.assertNotIn("continue-on-error", step)

        approval = self.steps_by_name["Update approved version on VPS"]
        self.assertIn("success()", approval["if"])
        self.assertNotIn("always()", approval["if"])
        self.assertNotIn("secrets.", approval["if"])
        approval_script = approval["with"]["script"]
        self.assertNotIn("docker exec", approval_script)
        self.assertIn("sudo env APPROVED_VERSION=", approval_script)
        self.assertIn("/opt/laymatched-auth/approval", approval_script)
        self.assertIn("chown root:root", approval_script)
        self.assertIn("chmod 0644", approval_script)
        self.assertIn("mv -f", approval_script)
        self.assertNotIn("/data/approved_version.txt", approval_script)

    def test_workflow_does_not_use_mutable_or_prebuilt_source_images(self):
        self.assertNotIn("ref: main", self.text)
        self.assertNotIn("ghcr.io/", self.text)
        self.assertNotIn("Verify source API image exists", self.text)

    def test_all_shell_steps_parse(self):
        for step in self.steps:
            if "run" not in step:
                continue
            script = re.sub(r"\$\{\{.*?\}\}", "workflow_value", step["run"])
            result = subprocess.run(
                ["bash", "-n"], input=script, text=True, capture_output=True
            )
            self.assertEqual(result.returncode, 0, f"{step['name']}: {result.stderr}")


if __name__ == "__main__":
    unittest.main()
