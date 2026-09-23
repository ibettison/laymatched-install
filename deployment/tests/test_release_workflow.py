import re
import subprocess
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
CANDIDATE = ROOT / ".github/workflows/create-release-candidate.yml"
PROMOTE = ROOT / ".github/workflows/promote-accepted-release-candidate.yml"


class ReleaseCandidateFlowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.candidate_text = CANDIDATE.read_text()
        cls.promote_text = PROMOTE.read_text()
        cls.candidate = yaml.load(cls.candidate_text, Loader=yaml.BaseLoader)
        cls.promote = yaml.load(cls.promote_text, Loader=yaml.BaseLoader)
        cls.candidate_steps = cls.candidate["jobs"]["build_candidate"]["steps"]
        cls.promote_steps = cls.promote["jobs"]["promote_accepted_candidate"]["steps"]
        cls.candidate_by_name = {step["name"]: step for step in cls.candidate_steps}
        cls.promote_by_name = {step["name"]: step for step in cls.promote_steps}

    def test_candidate_requires_exact_sha_and_rc_version(self):
        inputs = self.candidate["on"]["workflow_dispatch"]["inputs"]
        self.assertEqual(inputs["sha"]["required"], "true")
        self.assertEqual(inputs["candidate_version"]["required"], "true")
        checkout = self.candidate_by_name["Checkout exact application revision"]["with"]
        self.assertEqual(checkout["repository"], "ibettisson/layMatchedBetting")
        self.assertEqual(checkout["ref"], "${{ inputs.sha }}")
        self.assertEqual(checkout["persist-credentials"], "false")
        validate = self.candidate_by_name["Validate immutable candidate inputs"]["run"]
        self.assertIn("[0-9a-f]{40}", validate)
        self.assertIn("-rc\\.", validate)

    def test_canonical_and_deployment_workflow_copies_match(self):
        self.assertEqual(
            self.candidate_text,
            (ROOT / "deployment/workflows/create-release-candidate.yml").read_text(),
        )
        self.assertEqual(
            self.promote_text,
            (ROOT / "deployment/workflows/promote-accepted-release-candidate.yml").read_text(),
        )

    def test_exact_source_sha_passes_all_automated_gates_before_build(self):
        names = [step["name"] for step in self.candidate_steps]
        build_index = names.index("Build API from exact application SHA")
        for gate in (
            "Run complete backend suite",
            "Run frontend lint",
            "Run frontend suites",
            "Build customer frontend",
            "Build standard frontend",
        ):
            self.assertLess(names.index(gate), build_index)
        self.assertIn("application/backend", self.candidate_by_name["Run complete backend suite"]["working-directory"])

    def test_candidate_images_are_revision_checked_and_immutable(self):
        for label in ("Build API from exact application SHA", "Build Web from exact application SHA"):
            self.assertIn("org.opencontainers.image.revision=$SOURCE_SHA", self.candidate_by_name[label]["run"])
        names = [step["name"] for step in self.candidate_steps]
        self.assertLess(names.index("Refuse to overwrite an existing candidate tag"), names.index("Push immutable candidate tags to owner-only repositories"))
        manifest = self.candidate_by_name["Pull back and verify the exact candidate artifacts"]["run"]
        for field in ("candidate_version", "release_version", "source_sha", "api_image_digest", "web_image_digest"):
            self.assertIn(field, manifest)
        self.assertIn("laymatched-api-staging@$api_digest", manifest)
        self.assertIn("laymatched-web-staging@$web_digest", manifest)

    def test_clean_customer_installer_supports_digest_pinned_rc_manifest(self):
        installer = (ROOT / "install.sh").read_text()
        self.assertIn('"--release-candidate"', installer)
        self.assertIn("tools/release_candidate_manifest.py", installer)
        self.assertIn("laymatched-api-staging@${RELEASE_CANDIDATE_API_DIGEST}", installer)
        self.assertIn("laymatched-web-staging@${RELEASE_CANDIDATE_WEB_DIGEST}", installer)
        self.assertIn("Release candidate installation requires a clean customer installation", installer)
        self.assertIn("RELEASE_SOURCE_SHA", installer)

    def test_auth_returns_digests_only_for_manifest_matching_approved_version(self):
        auth = (ROOT / "auth-api/main.go").read_text()
        self.assertIn("loadApprovedRelease(approved)", auth)
        self.assertIn("release.Version != version", auth)
        self.assertIn("resp.APIImageDigest = release.APIImageDigest", auth)
        self.assertIn("APPROVED_RELEASE_PATH", auth)

    def test_aws_acceptance_and_owner_approval_gate_promotion(self):
        job = self.promote["jobs"]["promote_accepted_candidate"]
        self.assertEqual(job["environment"], "production")
        names = [step["name"] for step in self.promote_steps]
        promotion = names.index("Promote the exact candidate digests without rebuilding")
        installer_check = names.index("Verify installer pulls return the same accepted digests")
        approval_record = names.index("Record production approval after AWS owner acceptance")
        self.assertLess(promotion, installer_check)
        self.assertLess(installer_check, approval_record)
        record = self.promote_by_name["Record production approval after AWS owner acceptance"]["with"]["script"]
        self.assertIn("approved_release.json", record)
        self.assertIn("approved_version.txt", record)
        self.assertLess(record.index("approved_release.json"), record.index("approved_version.txt"))

    def test_promotion_uses_accepted_digests_without_application_rebuild(self):
        promotion = self.promote_by_name["Promote the exact candidate digests without rebuilding"]["run"]
        self.assertIn("skopeo copy --all --preserve-digests", promotion)
        self.assertIn("@$API_DIGEST", promotion)
        self.assertIn("@$WEB_DIGEST", promotion)
        self.assertNotIn("docker build", self.promote_text)
        self.assertIn("laymatched-live-promotion-", self.promote_text)
        self.assertIn("laymatched-candidate-", self.candidate_text)
        self.assertIn("test \"$api_promoted_digest\" =", promotion)
        self.assertIn("test \"$web_promoted_digest\" =", promotion)

    def test_production_approval_waits_for_installer_digest_verification(self):
        names = [step["name"] for step in self.promote_steps]
        self.assertLess(names.index("Verify installer pulls return the same accepted digests"), names.index("Record production approval after AWS owner acceptance"))
        approval = self.promote_by_name["Record production approval after AWS owner acceptance"]["with"]["script"]
        self.assertIn("mv -f", approval)
        self.assertIn("approved_version.txt", approval)
        for image in ("api_digest", "web_digest", "source_sha"):
            self.assertIn(image, self.promote_by_name["Verify live authorization reports exact approved image digests"]["run"])

    def test_all_workflow_shell_steps_parse(self):
        for workflow_name, steps in (("candidate", self.candidate_steps), ("promotion", self.promote_steps)):
            for step in steps:
                if "run" not in step:
                    continue
                script = re.sub(r"\$\{\{.*?\}\}", "workflow_value", step["run"])
                result = subprocess.run(["bash", "-n"], input=script, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, f"{workflow_name}/{step['name']}: {result.stderr}")


if __name__ == "__main__":
    unittest.main()
