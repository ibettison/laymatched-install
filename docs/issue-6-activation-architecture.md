# LayMatched DNS, HTTPS, and Customer Activation Architecture

> **STATUS: SLICE 0 ARCHITECTURE — RUNTIME IMPLEMENTATION NOT AUTHORISED**
>
> This document records architecture and interface design only. It does not
> authorize implementation, infrastructure changes, DNS changes, runtime
> changes, credential changes, or modification of LMTest2.

## Objective

Design the production architecture for the complete first-run LayMatched
customer experience:

1. A customer purchases or subscribes.
2. A Stripe-linked licensing record exists centrally on Fasthosts.
3. The customer installs LayMatched on a VPS.
4. The customer chooses a nickname.
5. The nickname is centrally validated and reserved.
6. DNS is created automatically.
7. HTTPS is configured automatically for
   `https://nickname.matched.laysports.co.uk`.
8. The existing Stripe/licensing customer is identified from authenticated
   licence and installation identity.
9. Membership information is displayed.
10. The customer supplies their name, town/city, and country.
11. The central licensing record is enriched.
12. MFA is configured and verified locally.
13. Recovery codes are generated locally.
14. Only MFA status is reported centrally.
15. Activation completes and the customer enters the private application.

## Security boundaries

- DNS provider credentials never reach a customer VPS.
- Stripe credentials never reach a customer VPS.
- A TOTP secret never leaves the customer VPS.
- MFA recovery codes never leave the customer VPS.
- Central licensing stores only MFA enabled/status/timestamp information and
  whether recovery codes were generated.
- Customer identity is resolved from authenticated licence and installation
  identity, never from submitted name or email.
- Nickname ownership is enforced centrally.
- The API and Web containers remain exposed only to loopback behind host nginx.

## Current architecture

Read-only investigation established the following:

- The installer calls
  `POST https://auth.matched.laysports.co.uk/installer/authorize` using a
  high-entropy installer token.
- Authorization returns a short-lived Registry credential, the approved
  version, and the Registry URL.
- Installer credentials are hashed centrally. Their associated `customer_id`
  is the current trusted installation identity.
- The installer deploys PostgreSQL, API, and Web containers. The Web container
  is exposed only on `127.0.0.1:8080`; host nginx currently proxies public HTTP
  traffic to it.
- Customer installations have no automated hostname, DNS, certificate, or
  activation-state lifecycle.
- The existing public names are:
  - `matched.laysports.co.uk`
  - `auth.matched.laysports.co.uk`
  - `registry.matched.laysports.co.uk`
- Those names currently resolve to `82.165.220.193`.
- `laysports.co.uk` is authoritative on Cloudflare DNS. Existing production
  records were migrated conservatively and initially retained as DNS-only.
  Customer records will be explicit names beneath `matched.laysports.co.uk`.
- The current `matched.laysports.co.uk` certificate is a single-host Let's
  Encrypt certificate, not a wildcard certificate.
- Central LayMatched PostgreSQL already contains customer and Stripe
  subscription information.
- Installer authorization currently uses a separate SQLite token store. Its
  `customer_id` is not enforced as a database foreign key to the central
  PostgreSQL customer record. This identity bridge must be explicit before
  activation becomes authoritative.

## Proposed architecture

```text
Stripe
   │ webhook
   ▼
Central licensing/customer database
   │
   ├── Activation API ── authenticated installation identity
   │        │
   │        ├── DNS reconciliation worker ── scoped DNS API credential
   │        └── activation/profile/MFA-status records
   │
Customer installer/VPS
   │
   ├── local installation private key
   ├── local nginx + ACME client
   ├── local TOTP secret
   ├── local recovery codes
   └── private LayMatched application
```

The central Activation API is the trust coordinator. It alone can:

- Resolve an installer credential to a canonical customer/licence.
- Decide whether the subscription permits activation.
- Reserve and assign nicknames.
- Change authoritative DNS through an isolated worker.
- Store customer profile enrichment.
- Store MFA status, but never MFA material.
- Suspend an installation and withdraw its hostname.

The customer VPS:

- Generates and retains its installation private key.
- Generates and retains its ACME private key.
- Generates and retains its TOTP secret and recovery codes.
- Terminates HTTPS locally.
- Verifies MFA locally.
- Reports only signed status assertions centrally.

Stripe and DNS provider credentials remain within the central service runtime.
They are never built into customer images or sent to customer VPSs.

## DNS design

### Authoritative zone foundation

Cloudflare is now authoritative for the existing `laysports.co.uk` zone. The
earlier proposal to delegate `matched.laysports.co.uk` from Fasthosts to Route
53 is obsolete and must not be implemented. Existing production records were
copied conservatively and initially left DNS-only while the migration was
verified.

Customer hostnames use explicit records in the existing authoritative zone:

```text
nickname.matched.laysports.co.uk
```

Cloudflare remains an internal implementation detail. The public Activation
API, state machine, errors, customer VPS, and normal test suite are
provider-neutral. Replacing Cloudflare later must require only a new internal
adapter, not a customer contract change.

### Customer records

Use explicit records rather than a wildcard:

```text
nickname.matched.laysports.co.uk A    <customer-public-ipv4>
nickname.matched.laysports.co.uk AAAA <verified-public-ipv6>  # optional
```

- Create `AAAA` only after IPv6 reachability and service binding are verified.
- Use a TTL of approximately 300 seconds during activation and steady state.
- Permanently reserve infrastructure and misleading names, including `auth`,
  `registry`, `www`, `api`, `admin`, `mail`, and `support`.

Explicit records provide enforceable ownership, clean suspension, controlled
IP changes, and no accidental routing for unreserved names.

### Nickname lifecycle

1. Normalize the requested nickname to lowercase ASCII.
2. Initially enforce an LDH-only policy: 3–32 characters, alphanumeric at both
   ends, with internal hyphens allowed.
3. Reject reserved, confusable, misleading, and policy-prohibited names.
4. Insert a transactional reservation protected by a unique constraint on the
   normalized nickname.
5. Give an incomplete reservation a bounded renewable lease, initially 15
   minutes. Legitimate pending central work renews it before expiry.
6. Permit only the owning signed activation to request renewal. Renewal cannot
   transfer ownership or revive an expired, released, quarantined, or terminal
   reservation.
7. Commit durable ownership to the customer only when an activation is
   established.
8. Queue DNS reconciliation using a transactional outbox.
9. Observe provider state until the desired record is applied.
10. Independently resolve the hostname before allowing ACME issuance.

An availability check is advisory only. The unique transactional reservation
is the authority. A nickname must never be transferred because another
installation submits a matching display name, email address, or IP address.

### IP changes

An authenticated installation submits a signed network update. The central
service must:

- Reject private, loopback, link-local, multicast, documentation, and reserved
  addresses.
- Issue a random HTTP reachability challenge.
- Require the new address to serve that challenge.
- Serialize updates for each hostname.
- Update DNS only after successful proof.
- Record the previous address and an audit event.
- Rate-limit changes and flag suspicious geographic or high-frequency movement.

Where possible, the old address remains active until the replacement endpoint
passes proof. Otherwise, DNS remains explicitly pending rather than reporting
false activation success. A certificate normally remains valid after an IP
change because it identifies the hostname, but HTTPS reachability must be
rechecked.

### Cancellation and deactivation

Stripe cancellation and explicit customer deactivation are distinct:

- `cancel_at_period_end` retains service until the entitlement end time.
- An expired, revoked, or administratively suspended entitlement revokes
  activation access and removes customer `A`/`AAAA` records.
- The nickname remains assigned or quarantined for a defined retention period.
- Names are not immediately recycled because this could enable hostname and
  certificate trust takeover.
- DNS deletion matches the stored hostname, record type, TTL, value, and
  version so a stale job cannot delete a newer assignment.

### DNS failure, retry, and rollback

- Record the desired state and outbox event in the same database transaction.
- Process DNS asynchronously; return `202` and `retry_after` while pending.
- Store an opaque internal provider operation reference where one exists and
  observe it to completion.
- Retry throttling and transient failures with bounded exponential backoff and
  jitter.
- Serialize or rate-limit same-zone changes where required by the adapter.
- If DNS succeeds but an API response is lost, idempotency and reconciliation
  recover the existing change instead of creating another owner or record.
- If DNS fails, retain the reservation and expose a retryable state. Do not
  release ownership automatically.
- If certificate issuance fails, retain the correct DNS record and retry ACME;
  do not expose the private app over plain HTTP.
- Provider failures do not trigger zone migration or customer-visible provider
  instructions. Central operations retain desired state and reconcile or use a
  separately reviewed infrastructure rollback.

## Internal DNS adapter contract

The machine-readable internal port is
`contracts/activation/dns-provider-adapter.json`. It defines three operations:

- `ensure_record`: idempotently make an owned record equal desired state.
- `observe_record`: read provider-observed state without mutation.
- `delete_owned_record`: idempotently remove only the record owned by the
  specified activation.

The ownership key is activation ID, hostname, and record type. An independent
resolver, not the provider response alone, is required before `dns_ready`.
Provider-specific names, identifiers, request payloads, errors, and credentials
must not cross the public API. Internal failures map only to the canonical
`dns_pending` or `dns_failed` customer errors with retry metadata.

Normal automated tests use a deterministic, in-memory fake adapter. It has a
logical clock, monotonic call order, isolated state, fixed result sequences,
idempotent operation replay, and no network. Required scenarios cover immediate
success, two-tick propagation delay, transient failure followed by success,
and permanent policy failure.

## Cloudflare adapter security model

The later real adapter runs only in the central DNS worker. Slice 0 neither
implements it nor authorizes a credential or DNS change.

Required controls for that later gate are:

- a dedicated non-human Cloudflare API token restricted to the
  `laysports.co.uk` zone and only the DNS read/edit permissions required;
- zone-ID pinning in central configuration;
- adapter input restricted to owned `A` and separately verified `AAAA` records
  beneath `matched.laysports.co.uk`, with bounded TTL and public addresses;
- an application-level protected-name denylist for the apex and infrastructure
  names such as `auth`, `registry`, `www`, `api`, `admin`, `mail`, and
  `support`;
- no wildcard, CNAME, MX, TXT, NS, infrastructure-record, proxy-mode, or zone
  setting mutation through customer activation;
- central secret-store injection, rotation, audit, rate limits, anomaly alerts,
  and a separately controlled break-glass administrator path;
- no token, account/zone identifier, provider response, or raw provider error in
  source control, CI logs, public API payloads, customer images, or customer
  VPS storage.

Cloudflare token creation/use and real adapter acceptance require a fresh
explicit infrastructure approval. A public request handler never calls
Cloudflare directly; it commits desired state and an outbox item for the worker.

## HTTPS and ACME design

Each customer VPS obtains its own single-host certificate using local ACME
HTTP-01 validation:

1. The central service reserves the nickname.
2. The central service creates DNS and confirms it is authoritative.
3. The customer VPS proves port-80 reachability using a central challenge
   nonce.
4. A local ACME client requests a certificate for the single hostname.
5. `/.well-known/acme-challenge/` is served locally on port 80.
6. Host nginx installs the certificate and serves the application on port 443.
7. HTTP requests other than ACME challenges redirect to HTTPS.
8. The VPS reports the public certificate fingerprint and expiry.
9. The central service independently probes HTTPS before marking it ready.

This avoids giving DNS credentials to the VPS and avoids transferring the TLS
private key through the central service.

Network requirements are:

- Inbound TCP 80 for HTTP-01 issuance and renewal.
- Inbound TCP 443 for the application.
- Outbound HTTPS and DNS from the VPS.
- API and Web containers remain loopback-only.

Let's Encrypt documents that HTTP-01 operates only on port 80 and recommends
retaining port 80 with ordinary traffic redirected to HTTPS. See the
[HTTP-01 documentation](https://letsencrypt.org/docs/challenge-types/) and
[port 80 guidance](https://letsencrypt.org/docs/allow-port-80/).

### Certificate capacity

At the original architecture review, Let's Encrypt limited new issuance to 50 certificates per
registered domain per seven days. Customer names under `laysports.co.uk` share
that registered-domain limit. Launch volume must be forecast, staging must be
used during testing, and a production limit override or alternative ACME CA
must be arranged before onboarding can exceed that rate. See
[Let's Encrypt rate limits](https://letsencrypt.org/docs/rate-limits/).

The ACME client must preserve account and certificate state, support ACME
Renewal Information where possible, and use bounded backoff with jitter. It
must not repeatedly delete state or request replacement certificates.

An issuance failure leaves activation in `https_pending`. It does not expose
the private application over plain HTTP or automatically release the nickname.
On cancellation, DNS withdrawal and activation revocation provide primary
containment. Any certificate private key remaining on the former VPS is local
data and cannot restore authoritative DNS ownership.

## Activation API contract

The shared contract should be OpenAPI 3.1 under:

```text
https://auth.matched.laysports.co.uk/v1/activations
```

A separately deployed activation service may later implement the same contract
without changing customer clients.

### Authentication and identity

Bootstrap uses the existing high-entropy installer credential in an HTTP
header rather than request JSON:

```http
Authorization: Bearer <installer-token>
```

The token maps centrally to `installer_tokens.customer_id`, which must resolve
to the canonical customer/licence record. Submitted profile data is never used
to look up or select that identity.

During bootstrap, the VPS generates an Ed25519 installation keypair and submits
only the public key. The service returns a short-lived activation JWT containing:

- `sub`: immutable installation ID.
- Canonical customer ID.
- Activation ID.
- Allowed scopes.
- Expiry, audience, and issuer.

Subsequent mutations use the JWT plus a request signature over method, path,
body hash, timestamp, and nonce. This limits bearer-token copying and replay.
The private installation key never leaves the VPS.

After the short-lived JWT expires, the VPS calls
`POST /v1/activation-sessions` with its public installation ID and a request
signed by the registered Ed25519 key. The installation ID only locates the
public key; it is not a credential. The central service consumes a fresh nonce,
re-checks licence and activation state, and issues a new short-lived JWT. This
supports browser reload, interruption, and VPS reboot without retaining or
re-pasting the installer credential.

### Idempotency and concurrency

Every mutating endpoint requires:

```http
Idempotency-Key: <UUID>
```

The server stores the key, installation, route, request hash, response, and
expiry.

- Same key and same request: return the original response.
- Same key and different request: return `409 idempotency_conflict`.
- A retried session request uses the same idempotency key and body with a fresh
  signature nonce. Reusing a nonce is always `401 replay_detected`.
- DNS work is asynchronous and backed by a transactional outbox.
- Optimistic row versions or ETags prevent conflicting state transitions.
- Responses include a correlation ID and machine-readable error code.

### `POST /v1/activations`

Creates or resumes an activation.

Request:

```json
{
  "installation_id": "uuid",
  "installation_public_key": "base64url-ed25519-key",
  "app_version": "v0.1.1",
  "public_ipv4": "203.0.113.10"
}
```

Response:

```json
{
  "activation_id": "uuid",
  "customer_id": "opaque-id",
  "access_token": "jwt",
  "expires_in": 900,
  "status": "profile_pending",
  "membership": {
    "status": "active",
    "tier": "founder",
    "founding_member": true,
    "current_period_end": "2026-09-27T00:00:00Z",
    "cancel_at_period_end": false
  },
  "profile_required": true,
  "next_action": "reserve_nickname",
  "server_time": "2026-08-27T12:00:00Z"
}
```

An inactive or cancelled entitlement returns `403 licence_inactive`. The
central policy determines the number of active installations permitted by one
licence.

### `POST /v1/activation-sessions`

Issues a replacement short-lived JWT to a previously registered installation.
It requires `X-Installation-Id`, timestamp, fresh nonce, Ed25519 signature, and
an idempotency key. It never accepts an installer credential or a replacement
public key. The response returns activation state and `next_action` so local
resume follows central authority rather than replaying completed steps.

### `POST /v1/activations/{id}/nickname-reservations`

Request:

```json
{
  "nickname": "winning-way",
  "public_ipv4": "203.0.113.10"
}
```

Response:

```json
{
  "reservation_id": "uuid",
  "nickname": "winning-way",
  "hostname": "winning-way.matched.laysports.co.uk",
  "status": "dns_pending",
  "reservation_expires_at": "2026-08-27T12:15:00Z",
  "retry_after": 5
}
```

Expected errors include:

- `nickname_invalid`
- `nickname_reserved`
- `nickname_unavailable`
- `installation_limit_reached`

A unique database constraint, not an availability check, decides ownership.

### `POST /v1/activations/{id}/nickname-reservations/{reservation_id}/renew`

The owning signed activation may extend a live, incomplete reservation by a
bounded interval while central DNS/HTTPS work is pending or retrying. Renewal
uses idempotency, nonce replay protection, and `If-Match`. It cannot rename,
transfer, revive, or extend a terminal/quarantined reservation. Once ownership
is committed, the expiry is null and renewal is an idempotent no-op.

### `PUT /v1/activations/{id}/network`

Updates network addresses and starts reachability verification.

```json
{
  "public_ipv4": "203.0.113.11",
  "public_ipv6": null,
  "challenge_response": "signed-random-nonce"
}
```

The service returns `202` with `retry_after` while verification or DNS
reconciliation is pending.

### `GET /v1/activations/{id}`

Returns safe current state:

```json
{
  "status": "mfa_pending",
  "hostname": "winning-way.matched.laysports.co.uk",
  "membership": {},
  "profile": {
    "complete": true
  },
  "dns": {
    "status": "ready"
  },
  "https": {
    "status": "verified"
  },
  "mfa": {
    "enabled": false,
    "verified_at": null
  },
  "next_action": "configure_mfa"
}
```

### `PATCH /v1/activations/{id}/profile`

```json
{
  "full_name": "Example Customer",
  "town_city": "York",
  "country_code": "GB"
}
```

Validate lengths and use ISO 3166-1 alpha-2 country codes. Email, customer ID,
and Stripe ID are not accepted as identity selectors.

### `POST /v1/activations/{id}/https-proof`

```json
{
  "hostname": "winning-way.matched.laysports.co.uk",
  "certificate_fingerprint_sha256": "hex",
  "certificate_not_after": "2026-11-25T00:00:00Z",
  "challenge_nonce": "central-random-value",
  "observed_at": "2026-08-27T12:10:00Z"
}
```

The central service independently probes the nonce and certificate before
accepting the assertion. No TLS private key is uploaded.

### `PUT /v1/activations/{id}/mfa-status`

```json
{
  "enabled": true,
  "method": "totp",
  "verified_at": "2026-08-27T12:15:00Z",
  "recovery_codes_generated": true,
  "local_security_version": 1
}
```

Unknown properties are rejected. Properties resembling `totp_secret`, `otp`,
`recovery_codes`, seeds, or QR payloads are expressly forbidden.

### `POST /v1/activations/{id}/complete`

Preconditions:

- Licence is active.
- Customer profile is complete.
- Nickname is committed.
- DNS is authoritative.
- HTTPS is independently verified.
- Local MFA verification has been reported.

Response:

```json
{
  "status": "active",
  "hostname": "winning-way.matched.laysports.co.uk",
  "activated_at": "2026-08-27T12:16:00Z"
}
```

The local application, not the central API, establishes the private application
session.

### `POST /v1/activations/{id}/deactivate`

Revokes activation credentials and queues DNS removal and nickname quarantine.
It is idempotent.

### `POST /v1/activations/{id}/heartbeat`

Reports application version, public address observations, certificate expiry,
and service health. It does not report user activity or MFA material.

### Activation state machine

```text
authorized
  → nickname_reserved
  → dns_pending
  → dns_ready
  → https_pending
  → profile_pending
  → mfa_pending
  → active
```

Exceptional states are:

- `retry_pending`
- `suspended`
- `cancelled`
- `deactivated`
- `nickname_quarantined`

## Existing licensing fields

The existing central `customers` record contains:

- `id`
- `display_name`
- `email`
- `status`
- `founding_member`
- `joined_at`
- `last_activity_at`
- `owner_notes`
- `installation_id`
- `created_at`
- `updated_at`
- `stripe_customer_id`
- `stripe_subscription_id`
- `subscription_status`
- `subscription_tier`
- `subscription_price_minor`
- `subscription_currency`
- `subscription_current_period_start`
- `subscription_current_period_end`
- `subscription_cancel_at_period_end`
- `subscription_canceled_at`
- `stripe_updated_at`

The installer-token store contains:

- `id`
- `customer_id`
- hashed token material
- `created_at`
- `revoked_at`
- `expires_at`
- `notes`
- `last_used_at`

The current membership fields can display safe subscription status, tier,
renewal period, and founding-member status. Raw Stripe identifiers should not
be returned to a customer VPS without a defined operational requirement.

## New licensing and activation fields

Customer-profile additions:

- `full_name`
- `town_city`
- `country_code`
- `profile_completed_at`

A distinct `full_name` avoids silently changing the existing meaning of
`display_name`.

New `activations` data:

- `activation_id`
- canonical `customer_id`
- immutable `installation_id`
- installation public key/thumbprint
- activation state and row version
- installed application version
- public IPv4/IPv6
- created, updated, activated, suspended, and last-seen timestamps
- HTTPS verified timestamp
- certificate fingerprint and expiry
- MFA enabled
- MFA method
- MFA verified timestamp
- recovery-codes-generated boolean
- local security schema version

New `hostnames` data:

- normalized nickname with unique index
- FQDN with unique index
- customer and activation ownership
- reserved, committed, released, and quarantined timestamps
- lifecycle state

New `dns_records` data:

- hostname
- provider and hosted-zone identifier
- record type, desired values, and TTL
- provider change ID
- desired and observed state
- retry count, last attempt, last error, and confirmation time

New supporting data:

- idempotency records
- signed-request nonces
- activation event/audit log
- transactional DNS outbox

The installer-token `customer_id` must be formally bound to the same immutable
customer/licence identity used by Stripe-backed licensing. If the data stores
remain separate, this requires an explicit, validated cross-service mapping and
reconciliation process.

There must be no central TOTP-secret or recovery-code columns.

## MFA security model

- TOTP generation occurs on the customer VPS.
- The TOTP secret is encrypted locally at rest.
- The QR provisioning URI is rendered locally.
- Initial OTP verification occurs locally.
- Recovery codes are generated locally.
- Only salted hashes of recovery codes are stored locally.
- Plain recovery codes are shown once and never logged.
- Central licensing receives only enabled status, method, verification time,
  and whether recovery codes were generated.
- The MFA-status assertion is signed using the installation key.
- Reconfiguration requires an authenticated local session and an appropriate
  recovery or administrative process.
- Central suspension does not require or reveal the TOTP secret.
- Logs and telemetry redact installer tokens, OTPs, QR payloads, provisioning
  URIs, and recovery codes.

Central licensing cannot independently verify a customer's TOTP without
possessing its secret. Its MFA field is therefore a signed installation-status
assertion, not possession of the second factor.

## Worker 1 interface contract: customer onboarding and MFA

Worker 1 owns customer-VPS onboarding and MFA:

- Installer nickname collection or a local bootstrap UI.
- Local activation-state presentation.
- A typed client generated from the shared OpenAPI contract.
- Polling and retry UX for DNS and HTTPS pending states.
- The local nginx/ACME orchestration interface.
- Customer name, town/city, and country forms.
- Membership display using response-safe membership fields only.
- Local TOTP setup and verification.
- Local recovery-code generation and storage.
- Entry to the private application after activation completion.

Worker 1 must:

- Never call the DNS provider.
- Never possess Stripe credentials.
- Never expose the installer token to browser JavaScript.
- Route central API calls through the local backend.
- Never send TOTP secrets, OTP values, or recovery codes centrally.
- Develop against mock responses for every state and error code.

## LM-2nd interface contract: central licensing and activation

The LM-2nd/central worker owns:

- Installer-token and customer/licence identity resolution.
- Activation JWT and signed-request validation.
- Subscription entitlement decisions.
- Nickname normalization, reservation, uniqueness, and quarantine.
- Customer profile persistence.
- The activation state machine.
- MFA-status persistence.
- DNS desired-state and the reconciliation worker.
- Stripe webhook-driven suspension and cancellation.
- Idempotency, audit records, and operational metrics.
- Independent DNS, HTTP, and HTTPS verification.

The LM-2nd worker publishes:

- OpenAPI 3.1 schema.
- JSON request and response examples.
- Error-code catalogue.
- State-transition specification.
- Mock server.
- Contract-test suite.
- Fake DNS provider adapter for tests.

It never receives local MFA secrets and has no dependency on Worker 1's UI
implementation. Worker 1 and LM-2nd can therefore develop independently once
the shared OpenAPI contract, state machine, and error catalogue are frozen.

## Implementation sequence

This is a proposed sequence for a later approved implementation phase; it is
not authorization to begin any step.

1. Confirm the exact hostname namespace and the existing Cloudflare zone
   boundary; any real token/use remains separately gated.
2. Freeze the provider-neutral OpenAPI contract, state machine, internal DNS
   adapter, fake semantics, error codes, and identity
   semantics.
3. Establish the canonical customer/licence ID bridge between installer
   authorization and central PostgreSQL.
4. Add activation, hostname, DNS-state, idempotency, and audit schemas.
5. Implement central authentication and signed installation requests.
6. Implement nickname reservation using transactional uniqueness.
7. Implement and test a fake DNS adapter and reconciliation worker.
8. Build Worker 1 UI and local MFA against the mock API in parallel.
9. Implement local ACME/nginx orchestration using staging ACME.
10. Re-verify the Cloudflare record inventory and protected-name policy before
    any real adapter is enabled.
11. Implement the restricted Cloudflare adapter behind the already-tested
    internal port, without changing the public contract.
12. Arrange production ACME capacity or a rate-limit override.
13. Conduct a separately reviewed Cloudflare credential and test-record phase
    with rollback readiness.
14. Run staged end-to-end activation with a non-production customer
    installation.
15. Security-test identity binding, nickname races, replay protection,
    SSRF/IP validation, cancellation, and secret redaction.
16. Enable production customer activation only after separate review gates.

## Dependencies

- The existing Cloudflare-authoritative `laysports.co.uk` zone.
- A restricted central Cloudflare token, created and used only under a later
  explicit approval.
- A verified inventory and protected-name policy for current records beneath
  `matched.laysports.co.uk`.
- Canonical linkage between installer-token customer identity and the
  Stripe-backed customer identity.
- A durable queue/outbox and retry worker.
- Secret storage and rotation for the DNS credential.
- Public IPv4 or verified IPv6 on each customer VPS.
- Customer firewall/NAT permitting ports 80 and 443.
- A local ACME client with persistent state and ARI support.
- An ACME issuance-capacity decision before broad launch.
- Shared OpenAPI tooling, generated clients, mocks, and contract tests.
- Defined subscription suspension, hostname retention, and nickname-reuse
  policies.
- Privacy and retention policy for customer profile, IP, hostname, and
  activation audit data.

## Risks

- **Identity mismatch:** separate installer-token and customer databases could
  activate the wrong record unless the canonical ID bridge is enforced.
- **Existing-record damage:** a wrongly scoped adapter could change migrated
  production records for the application, Auth, Registry, mail, or website.
- **DNS credential blast radius:** the exact hostname requirement places
  automated customer records in the same child zone as critical services.
- **Certificate capacity:** the registered-domain issuance limit can constrain
  onboarding below expected demand.
- **Nickname races:** availability checks without transactional reservation
  would permit duplicate ownership.
- **Hostname takeover:** immediate reuse after cancellation could redirect an
  established trusted name.
- **DNS rebinding and SSRF:** accepting arbitrary supplied addresses without
  public-address validation and reachability proof is unsafe.
- **Port blocking:** HTTP-01 fails where inbound port 80 is unavailable.
- **NAT and dynamic IP:** changing addresses require authenticated updates and
  repeated reachability verification.
- **Partial failure:** DNS may succeed while an API response, certificate
  issuance, or database update fails; reconciliation and idempotency are
  mandatory.
- **Retry storms:** DNS and ACME operations require bounded exponential backoff
  and rate-aware queues.
- **MFA overclaim:** central MFA status is an installation attestation, not
  independent verification of the TOTP secret.
- **Customer VPS compromise:** a compromised installation key could report
  false status or request IP changes; revocation, rotation, anomaly detection,
  and installation limits are needed.
- **Privacy:** profile, subscription, IP, hostname, and audit data require
  retention limits and strict access control.
- **Credential compromise:** an exposed DNS token could reroute customer
  traffic; least privilege, rotation, audit, and protected-name denies are
  essential.
- **State divergence:** Stripe, licensing, activation, DNS, and customer VPS
  state may disagree; reconciliation must define which system is authoritative
  for each field.

## Gate status

- Application source modified: **No**
- Runtime modified: **No**
- DNS modified: **No**
- Fasthosts modified: **No**
- Cloudflare modified: **No**
- LMTest2 modified: **No**
- Credentials or secrets modified: **No**
- Recommendations implemented: **No**

**SLICE 0 DEFINES CONTRACT/ARCHITECTURE ONLY — RUNTIME GATES REMAIN CLOSED**
