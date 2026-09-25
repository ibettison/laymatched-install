import re
import shlex
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
RECOGNITION_COMMANDS = {
    "bootstrap",
    "heartbeat",
    "reserve-hostname",
    "report-https",
    "report-profile",
    "report-mfa",
    "status",
    "complete",
}
GLOBAL_OPTIONS = ("--central-url", "--state-dir", "--app-version")


def _recognition_invocations(source: str):
    # Normalize shell continuations, including the escaped continuations in
    # the updater's generated renewal hook.
    source = re.sub(r"\\+\n[ \t]*", " ", source)
    pattern = re.compile(
        r"(?:python3|/usr/bin/python3)\s+[^\s;|]+/recognition_client\.py"
        r"(?P<args>.*?)(?=\n|;|\|\||&&|\)|$)"
    )
    for match in pattern.finditer(source):
        yield shlex.split(match.group("args"))


class RecognitionCLIOrderTests(unittest.TestCase):
    def test_all_repository_recognition_invocations_put_global_options_first(self):
        expected = {
            "install.sh": {"status", "report-profile", "report-mfa", "complete", "heartbeat", "bootstrap", "reserve-hostname", "report-https"},
            "update.sh": {"heartbeat", "report-https"},
            "scripts/configure-customer-https.sh": {"report-https"},
            "docs/recognition-acceptance-runbook.md": {"heartbeat"},
        }

        for relative_path, expected_commands in expected.items():
            with self.subTest(relative_path=relative_path):
                invocations = list(_recognition_invocations((ROOT / relative_path).read_text()))
                commands = {args[next(i for i, value in enumerate(args) if value in RECOGNITION_COMMANDS)] for args in invocations}
                self.assertEqual(commands, expected_commands)
                expected_invocations = len(expected_commands) + (2 if relative_path == "install.sh" else 0)
                self.assertEqual(len(invocations), expected_invocations)
                for args in invocations:
                    command_index = next(i for i, value in enumerate(args) if value in RECOGNITION_COMMANDS)
                    self.assertEqual(args[:6:2], list(GLOBAL_OPTIONS))
                    self.assertGreater(command_index, max(args.index(option) for option in GLOBAL_OPTIONS))
