import ipaddress
import json
import re
import unittest
import uuid
from datetime import datetime
from pathlib import Path


CONTRACT_DIR = Path(__file__).resolve().parents[1]
OPENAPI_PATH = CONTRACT_DIR / "openapi.json"
STATE_MACHINE_PATH = CONTRACT_DIR / "state-machine.json"
HTTP_METHODS = {"get", "post", "put", "patch", "delete"}
MUTATING_METHODS = {"post", "put", "patch", "delete"}
FORBIDDEN_MFA_NAMES = {
    "totp_secret",
    "otp",
    "provisioning_uri",
    "qr_payload",
    "recovery_codes",
    "recovery_code_hashes",
}


def load_json(path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


class SchemaValidator:
    """Small Draft 2020-12/OpenAPI subset validator for contract examples."""

    def __init__(self, document):
        self.document = document

    def resolve(self, schema):
        while "$ref" in schema:
            ref = schema["$ref"]
            if not ref.startswith("#/"):
                raise AssertionError(f"external reference is not supported: {ref}")
            target = self.document
            for part in ref[2:].split("/"):
                target = target[part.replace("~1", "/").replace("~0", "~")]
            schema = target
        return schema

    def validate(self, value, schema, path="$"):
        schema = self.resolve(schema)

        if "const" in schema:
            if value != schema["const"]:
                raise AssertionError(f"{path}: expected const {schema['const']!r}")

        if "enum" in schema and value not in schema["enum"]:
            raise AssertionError(f"{path}: {value!r} not in enum")

        allowed_types = schema.get("type")
        if isinstance(allowed_types, str):
            allowed_types = [allowed_types]
        if allowed_types and not any(self._matches_type(value, item) for item in allowed_types):
            raise AssertionError(f"{path}: {type(value).__name__} is not {allowed_types}")
        if value is None:
            return

        if isinstance(value, dict):
            required = set(schema.get("required", []))
            missing = required - value.keys()
            if missing:
                raise AssertionError(f"{path}: missing required {sorted(missing)}")
            properties = schema.get("properties", {})
            if schema.get("additionalProperties") is False:
                extra = value.keys() - properties.keys()
                if extra:
                    raise AssertionError(f"{path}: unexpected properties {sorted(extra)}")
            for name, item in value.items():
                if name in properties:
                    self.validate(item, properties[name], f"{path}.{name}")

        if isinstance(value, list):
            if "maxItems" in schema and len(value) > schema["maxItems"]:
                raise AssertionError(f"{path}: too many items")
            if "minItems" in schema and len(value) < schema["minItems"]:
                raise AssertionError(f"{path}: too few items")
            if "items" in schema:
                for index, item in enumerate(value):
                    self.validate(item, schema["items"], f"{path}[{index}]")

        if isinstance(value, str):
            if "minLength" in schema and len(value) < schema["minLength"]:
                raise AssertionError(f"{path}: shorter than minLength")
            if "maxLength" in schema and len(value) > schema["maxLength"]:
                raise AssertionError(f"{path}: longer than maxLength")
            if "pattern" in schema and re.fullmatch(schema["pattern"], value) is None:
                raise AssertionError(f"{path}: does not match {schema['pattern']}")
            self._validate_format(value, schema.get("format"), path)

        if isinstance(value, (int, float)) and not isinstance(value, bool):
            if "minimum" in schema and value < schema["minimum"]:
                raise AssertionError(f"{path}: below minimum")
            if "maximum" in schema and value > schema["maximum"]:
                raise AssertionError(f"{path}: above maximum")

    @staticmethod
    def _matches_type(value, expected):
        checks = {
            "null": value is None,
            "object": isinstance(value, dict),
            "array": isinstance(value, list),
            "string": isinstance(value, str),
            "integer": isinstance(value, int) and not isinstance(value, bool),
            "number": isinstance(value, (int, float)) and not isinstance(value, bool),
            "boolean": isinstance(value, bool),
        }
        return checks.get(expected, True)

    @staticmethod
    def _validate_format(value, format_name, path):
        if not format_name:
            return
        try:
            if format_name == "uuid":
                uuid.UUID(value)
            elif format_name == "ipv4":
                if ipaddress.ip_address(value).version != 4:
                    raise ValueError("not IPv4")
            elif format_name == "ipv6":
                if ipaddress.ip_address(value).version != 6:
                    raise ValueError("not IPv6")
            elif format_name == "date-time":
                datetime.fromisoformat(value.replace("Z", "+00:00"))
            elif format_name == "hostname":
                if len(value) > 253 or not all(
                    re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label)
                    for label in value.split(".")
                ):
                    raise ValueError("invalid hostname")
        except ValueError as exc:
            raise AssertionError(f"{path}: invalid {format_name}: {value}") from exc


class ActivationContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.openapi = load_json(OPENAPI_PATH)
        cls.machine = load_json(STATE_MACHINE_PATH)
        cls.validator = SchemaValidator(cls.openapi)

    def operations(self):
        for path, path_item in self.openapi["paths"].items():
            for method, operation in path_item.items():
                if method in HTTP_METHODS:
                    yield path, method, operation

    def dereference(self, value):
        return self.validator.resolve(value)

    def parameter_names(self, operation):
        return {
            self.dereference(parameter)["name"]
            for parameter in operation.get("parameters", [])
        }

    def test_openapi_document_shape(self):
        self.assertEqual("3.1.0", self.openapi["openapi"])
        self.assertTrue(self.openapi["paths"])
        self.assertIn("schemas", self.openapi["components"])
        operation_ids = [operation["operationId"] for _, _, operation in self.operations()]
        self.assertEqual(len(operation_ids), len(set(operation_ids)))

    def test_all_internal_references_resolve(self):
        def walk(value):
            if isinstance(value, dict):
                if "$ref" in value:
                    self.dereference(value)
                for child in value.values():
                    walk(child)
            elif isinstance(value, list):
                for child in value:
                    walk(child)

        walk(self.openapi)

    def test_embedded_examples_validate_against_schemas(self):
        count = 0
        for _, _, operation in self.operations():
            request_body = operation.get("requestBody", {})
            for media in request_body.get("content", {}).values():
                if "example" in media:
                    self.validator.validate(media["example"], media["schema"])
                    count += 1
            for response in operation["responses"].values():
                response = self.dereference(response)
                for media in response.get("content", {}).values():
                    if "example" in media:
                        self.validator.validate(media["example"], media["schema"])
                        count += 1
        self.assertGreaterEqual(count, 8)

    def test_bootstrap_is_the_only_installer_credential_operation(self):
        installer_operations = []
        for path, method, operation in self.operations():
            if any("InstallerCredential" in requirement for requirement in operation["security"]):
                installer_operations.append((path, method))
        self.assertEqual([("/v1/activations", "post")], installer_operations)

    def test_post_bootstrap_operations_require_token_and_signature(self):
        for path, method, operation in self.operations():
            if (path, method) == ("/v1/activations", "post"):
                continue
            self.assertIn(
                {"ActivationToken": [], "InstallationSignature": []},
                operation["security"],
                f"{method.upper()} {path}",
            )
            names = self.parameter_names(operation)
            self.assertIn("X-Signature-Timestamp", names)
            self.assertIn("X-Signature-Nonce", names)

    def test_all_mutations_require_idempotency_key(self):
        exempt = {("/v1/activations/{activation_id}/nickname-availability", "post")}
        for path, method, operation in self.operations():
            if method not in MUTATING_METHODS or (path, method) in exempt:
                continue
            self.assertIn("Idempotency-Key", self.parameter_names(operation), f"{method} {path}")

    def test_all_operations_define_structured_error_responses(self):
        for path, method, operation in self.operations():
            errors = [response for status, response in operation["responses"].items() if status.startswith(("4", "5"))]
            self.assertTrue(errors, f"{method.upper()} {path} has no errors")
            for response in errors:
                resolved = self.dereference(response)
                schema = resolved["content"]["application/json"]["schema"]
                self.assertIs(self.dereference(schema), self.openapi["components"]["schemas"]["ErrorResponse"])

    def test_required_canonical_error_codes_are_defined(self):
        codes = set(self.openapi["components"]["schemas"]["ErrorCode"]["enum"])
        required = {
            "invalid_credential",
            "expired_credential",
            "licence_inactive",
            "nickname_invalid",
            "nickname_unavailable",
            "nickname_reserved",
            "dns_pending",
            "dns_failed",
            "https_pending",
            "https_failed",
            "mfa_incomplete",
            "activation_incomplete",
            "conflict",
            "idempotent_replay",
            "idempotency_conflict",
        }
        self.assertEqual(set(), required - codes)

    def test_state_machine_matches_openapi_enum(self):
        api_states = set(self.openapi["components"]["schemas"]["ActivationState"]["enum"])
        machine_states = set(self.machine["states"])
        self.assertEqual(api_states, machine_states)
        self.assertIn(self.machine["initial_state"], machine_states)
        self.assertIn(self.machine["completion_state"], machine_states)
        for transition in self.machine["transitions"]:
            self.assertIn(transition["from"], machine_states)
            self.assertIn(transition["to"], machine_states)
            self.assertTrue(transition["guard"])
        for transition in self.machine["global_transitions"]:
            self.assertEqual("*", transition["from"])
            self.assertIn(transition["to"], machine_states)
            self.assertTrue(set(transition["except"]).issubset(machine_states))

    def test_successful_activation_path_is_represented(self):
        edges = {(item["from"], item["to"]) for item in self.machine["transitions"]}
        required_edges = {
            ("authorized", "nickname_reserved"),
            ("nickname_reserved", "dns_pending"),
            ("dns_pending", "dns_ready"),
            ("dns_ready", "https_pending"),
            ("https_pending", "profile_pending"),
            ("profile_pending", "mfa_pending"),
            ("mfa_pending", "active"),
        }
        self.assertEqual(set(), required_edges - edges)

    def test_profile_schema_cannot_select_customer_identity(self):
        properties = set(self.openapi["components"]["schemas"]["ProfileUpdateRequest"]["properties"])
        self.assertTrue(properties.isdisjoint({"customer_id", "email", "stripe_customer_id", "installation_id"}))

    def test_membership_schema_excludes_stripe_identifiers(self):
        properties = set(self.openapi["components"]["schemas"]["Membership"]["properties"])
        self.assertTrue(properties.isdisjoint({"stripe_customer_id", "stripe_subscription_id", "stripe_token", "stripe_secret"}))

    def test_mfa_update_is_status_only_and_rejects_unknown_fields(self):
        schema = self.openapi["components"]["schemas"]["MfaStatusUpdateRequest"]
        properties = set(schema["properties"])
        self.assertFalse(properties & FORBIDDEN_MFA_NAMES)
        self.assertIs(schema["additionalProperties"], False)
        valid = {
            "enabled": True,
            "method": "totp",
            "verified_at": "2026-08-27T12:15:00Z",
            "recovery_codes_generated": True,
            "local_security_version": 1,
        }
        self.validator.validate(valid, schema)
        for forbidden in FORBIDDEN_MFA_NAMES:
            with self.assertRaises(AssertionError, msg=forbidden):
                self.validator.validate({**valid, forbidden: "must-not-cross-boundary"}, schema)

    def test_contract_contains_no_provider_or_stripe_credentials(self):
        property_names = set()

        def collect(value):
            if isinstance(value, dict):
                property_names.update(value.get("properties", {}).keys())
                for child in value.values():
                    collect(child)
            elif isinstance(value, list):
                for child in value:
                    collect(child)

        collect(self.openapi["components"]["schemas"])
        forbidden = {
            "dns_api_token",
            "route53_access_key",
            "route53_secret_key",
            "stripe_api_key",
            "stripe_webhook_secret",
            "totp_secret",
            "recovery_codes",
        }
        self.assertEqual(set(), property_names & forbidden)


if __name__ == "__main__":
    unittest.main()
