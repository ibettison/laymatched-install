import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VALID_MANIFEST = {
    "candidate_version": "v0.2.0-rc.1",
    "release_version": "v0.2.0",
    "source_sha": "a" * 40,
    "registry_url": "registry.example.test",
    "api_image_digest": "sha256:" + "b" * 64,
    "web_image_digest": "sha256:" + "c" * 64,
    "api_image": "registry.example.test/laymatched-api-staging@sha256:" + "b" * 64,
    "web_image": "registry.example.test/laymatched-web-staging@sha256:" + "c" * 64,
}


class ReleaseCandidateManifestTests(unittest.TestCase):
    def run_manifest(self, manifest, registry="registry.example.test"):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "release-candidate.json"
            path.write_text(json.dumps(manifest))
            return subprocess.run(
                ["python3", str(ROOT / "tools/release_candidate_manifest.py"), str(path), registry],
                text=True,
                capture_output=True,
            )

    def test_accepts_identity_bound_manifest(self):
        result = self.run_manifest(VALID_MANIFEST)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.strip().split("\t"),
            ["v0.2.0-rc.1", "a" * 40, "sha256:" + "b" * 64, "sha256:" + "c" * 64],
        )

    def test_rejects_final_version_mismatch(self):
        manifest = {**VALID_MANIFEST, "release_version": "v0.3.0"}
        result = self.run_manifest(manifest)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not belong", result.stderr)

    def test_rejects_image_ref_digest_mismatch(self):
        manifest = {**VALID_MANIFEST, "api_image": "registry.example.test/laymatched-api-staging@sha256:" + "d" * 64}
        result = self.run_manifest(manifest)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("references do not match", result.stderr)

    def test_rejects_other_registry(self):
        result = self.run_manifest(VALID_MANIFEST, registry="other.example.test")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("registry does not match", result.stderr)


if __name__ == "__main__":
    unittest.main()
