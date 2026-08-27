# LayMatched Activation Contract

> **STATUS: GATE 2A CONTRACT — NOT APPROVED FOR IMPLEMENTATION OR DEPLOYMENT**

This directory is the authoritative shared integration boundary for customer
activation. It does not contain a licensing backend, onboarding frontend, DNS
provider integration, or ACME implementation.

The approved design authority is
[`docs/issue-6-activation-architecture.md`](../../docs/issue-6-activation-architecture.md).

## Contract artifacts

- [`openapi.json`](openapi.json) defines endpoints, authentication, request and
  response schemas, status representations, and canonical error codes.
- [`state-machine.json`](state-machine.json) defines activation states,
  transitions, guards, global entitlement transitions, and invariants.
- [`tests/test_contract.py`](tests/test_contract.py) validates the contract's
  structure, references, examples, security boundaries, state consistency, and
  idempotency requirements using only the Python standard library.

Run validation from the repository root:

```bash
python3 -m unittest discover -s contracts/activation/tests -v
```

## Trust and authentication boundary

`POST /v1/activations` is the sole bootstrap operation. The existing installer
credential is sent in the `Authorization` header by the local installer or
local backend. It must not be placed in a URL, request JSON, browser storage,
or browser JavaScript.

Central licensing resolves this credential to the canonical customer/licence.
`full_name`, `town_city`, `country_code`, nickname, email, and network address
are never identity selectors.

Bootstrap registers an installation public key and returns a short-lived
activation JWT. Every later operation requires both that JWT and an Ed25519
request signature, with timestamp and nonce headers. The installation private
key stays on the customer VPS.

The canonical signature input for a later implementation is UTF-8 text joined
by line feed characters in this exact order:

```text
UPPERCASE_HTTP_METHOD
NORMALIZED_PATH_WITHOUT_QUERY
LOWERCASE_HEX_SHA256_OF_EXACT_BODY_BYTES
X-Signature-Timestamp
X-Signature-Nonce
```

An empty request body uses the SHA-256 digest of zero bytes. Query parameters
must be canonically specified in a later contract revision before any signed
endpoint is allowed to use them.

## Idempotency and optimistic concurrency

Every state-mutating operation requires an `Idempotency-Key` UUID. Keys are
scoped to installation and operation.

- Same key and request hash returns the originally stored status, headers, and
  response body. This is a successful idempotent replay.
- Same key with a different request hash returns
  `409 idempotency_conflict`.
- A stale `If-Match` value returns `409 version_conflict`.
- A reused signature nonce returns `401 replay_detected`.

The availability endpoint is advisory and non-mutating. Only the reservation
endpoint, backed by central transactional uniqueness, grants nickname ownership.

## State semantics

The primary successful progression is:

```text
authorized
  → nickname_reserved
  → dns_pending
  → dns_ready
  → https_pending
  → profile_pending (when required)
  → mfa_pending
  → active
```

DNS or HTTPS failures move to `retry_pending`; the activation retains nickname
ownership while the failed stage is retried. Entitlement and customer events
can move an activation to `suspended`, `cancelled`, or `deactivated`. Hostname
withdrawal then moves ownership to `nickname_quarantined`; it does not make the
nickname immediately reusable.

The JSON state machine is canonical where prose and a transition differ.

## Canonical errors

All error responses use `ErrorResponse` with a stable `error` value,
human-readable `message`, opaque `correlation_id`, `retryable`, and optional
`retry_after` and `details`.

| Error | Meaning |
|---|---|
| `invalid_credential` | Credential is unknown, revoked, malformed, or not valid for the requested activation. |
| `expired_credential` | Credential was valid but has expired. |
| `licence_inactive` | The authenticated customer is not entitled to activate or progress. |
| `activation_not_found` | No activation visible to the authenticated installation exists. |
| `installation_limit_reached` | The licence's permitted active-installation count is exhausted. |
| `nickname_invalid` | Nickname fails normalization, syntax, reserved-name, or policy validation. |
| `nickname_unavailable` | Another customer owns or quarantines the nickname. |
| `nickname_reserved` | A reservation exists and prevents the requested operation. |
| `dns_pending` | Authoritative DNS creation or independent verification is not complete. |
| `dns_failed` | DNS reconciliation or verification failed. Inspect `retryable`. |
| `https_pending` | Local issuance or independent HTTPS verification is not complete. |
| `https_failed` | Independent HTTPS verification failed. Inspect `retryable`. |
| `profile_incomplete` | Required profile enrichment is incomplete. |
| `mfa_incomplete` | Locally verified MFA status has not been reported. |
| `activation_incomplete` | One or more completion guards are not satisfied. `details` identifies gates without exposing secrets. |
| `conflict` | Generic current-state conflict where no narrower code applies. |
| `idempotent_replay` | Informational code for an explicitly surfaced successful replay; normal replay should return the original response. |
| `idempotency_conflict` | An idempotency key was reused with a different request. |
| `version_conflict` | `If-Match` does not identify the current activation version. |
| `invalid_signature` | Installation request signature failed verification. |
| `replay_detected` | Signature nonce was already consumed or the timestamp is outside the accepted window. |
| `validation_failed` | Request shape or semantic validation failed. |
| `rate_limited` | Caller must respect `Retry-After`. |
| `internal_error` | Unexpected central error; secrets and provider internals must not appear in the response. |

`dns_pending`, `dns_failed`, `https_pending`, `https_failed`,
`profile_incomplete`, and `mfa_incomplete` may be returned as the narrow reason
for `activation_incomplete` when completion is attempted.

## Worker 1 integration contract

Worker 1 owns the local installer/onboarding and MFA experience.

- Keep the installer credential and activation token in the local backend,
  never browser JavaScript.
- Generate and retain the installation private key locally.
- Use `nickname-availability` for UX only and
  `nickname-reservations` for ownership.
- Poll `GET /v1/activations/{id}` using `next_action`, DNS state, HTTPS state,
  and `retry_after`; do not infer state from prose messages.
- Generate, store, display, and verify TOTP and recovery codes locally.
- Send only the fields permitted by `MfaStatusUpdateRequest`.
- Enter the private application only after `/complete` returns `active`.
- Develop against contract-derived mocks; no production service is required
  for Worker 1 development.

Worker 1 must not implement or call a DNS-provider API, possess Stripe or DNS
credentials, or upload TLS/MFA private material.

## LM-2nd integration contract

LM-2nd owns the future central licensing and activation implementation.

- Resolve identity exclusively through the authenticated installer and
  installation records.
- Return only safe membership metadata; never return Stripe identifiers or
  credentials.
- Enforce transactional nickname uniqueness and quarantine centrally.
- Treat DNS and HTTPS as asynchronous desired/observed state.
- Implement DNS through an internal adapter/worker, not inside this public
  contract and not in Gate 2A.
- Independently verify authoritative DNS and HTTPS before advancing state.
- Strictly reject additional MFA properties so secret-bearing fields cannot be
  accepted accidentally.
- Store idempotency responses and request hashes and enforce signed-request
  nonce replay protection.
- Use the canonical state machine and errors rather than adding private states
  that Worker 1 cannot understand.

LM-2nd can implement against fake DNS and HTTPS-verifier ports. This contract
does not authorize real provider integration or deployment.

## Security invariants

- Browser never receives the installer credential.
- DNS credentials never reach the customer VPS.
- Stripe credentials never reach the customer VPS.
- TOTP secret never leaves the customer VPS.
- Recovery codes and their hashes never leave the customer VPS.
- Central licensing receives MFA status metadata only.
- TLS and ACME private keys remain local to the VPS.
- Customer identity is never resolved from submitted profile data.

## Change control

Contract evolution must remain backward compatible within `/v1` unless a
reviewed breaking-change process explicitly creates a new API version. Any
change that alters the approved Gate 1 architecture requires a new architecture
gate rather than an implementation-only decision.
