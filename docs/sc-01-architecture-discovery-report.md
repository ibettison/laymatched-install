# SC-01 — LayMatched Interlocking Architecture Discovery

Date: 2026-09-20

This is a bounded architecture assessment. The report edit is documentation-only;
no application code, production configuration, live customer data, or running
services were changed.

Evidence labels used below:

- **Verified source** means present in the inspected repository at the cited
  revision.
- **Approved design** means specified by the activation architecture/contract,
  not necessarily implemented or deployed.
- **Runtime unknown** means no live installation or service was inspected.
- **Proposal** means a possible later implementation, subject to the relevant
  architecture gate.

Source references use:

- `ibettison/layMatchedBetting` `origin/main`:
  `03d459147906643bcb8dd540dab6e63428a7733c`
- `ibettison/laymatched-install` `main`:
  `1a7328dc89a1b11b9e3dfe838f2dcb223b0f7562`
- PAD Issue #3 addendum:
  [comment #5710307991](https://github.com/ibettison/laymatched-install/issues/3#issuecomment-5710307991)

## A. Repository verification

| Repository | Checked-out branch | Checked-out HEAD | Default branch reference | Worktree |
|---|---|---|---|---|
| `ibettison/layMatchedBetting` | `codex/campaign-gradient-cache-bust` | `f7a0c3ff40c36b7e2ed44a2dd7e1f964d429b374` | `origin/main` | Pre-existing modified public-site files, images and `node_modules/` |
| `ibettison/laymatched-install` | `sc-01-architecture-discovery-report` | `9188337394ac5697ba7229709079dba330955ab1` | `origin/main` | Pre-existing modified PAD documentation |

The primary checked-out branch is divergent from current `origin/main` and was
not switched during discovery. Current application behaviour was therefore
audited from the immutable local `origin/main` ref.

Both repositories and remotes were accessible locally. PR #25 remained open,
targeted `main`, and pointed to the report commit above when this revision was
prepared. No external state was changed by this documentation edit.

## B. Executive summary

Already present:

- A substantial private customer application with authentication, customer
  MFA, account setup, calculators, offer discovery, guided journeys, ledger,
  settlement and dashboards.
- A separate central artifact containing Stripe, Owner Portal, marketing,
  catalogue and community-review capabilities.
- A separate installer/Auth API/private registry path for provisioning and
  release delivery.
- A local activation journal with a read-only customer projection.
- Customer/central artifact separation in application profiles, Docker stages,
  Nginx rules and tests.

Not yet genuinely present:

- A dependable, versioned customer-VPS-to-central service-state contract.
- Central heartbeat, version, health, update-result or onboarding reporting.
- A complete durable association between central Customer records and local
  installations.
- Central visibility of MFA state or activation state.
- A reliable Owner operational view of live customer installation state.

The main architectural gap is the missing interlock:

```text
Customer VPS state
        -> safe versioned service contract
        -> central authoritative operational state
        -> Owner attention and support workflows
```

## C. Current architecture and data flow

```text
Public browser -> central web/API -> central PostgreSQL -> Stripe/public flows

Owner browser -> central web/API -> central PostgreSQL

Customer browser -> customer Nginx -> customer API -> customer PostgreSQL

Installer VPS -> Auth API -> private registry -> local customer Compose stack

Installer activation journal -> read-only state.json -> customer activation API

Approved but not verified as implemented in the inspected runtime:

```text
Installer credential -> POST /v1/activations -> central customer/licence identity
Installation key + short-lived JWT -> signed activation/status/heartbeat requests
```
```

Verified evidence:

- Customer/central profiles:
  [`backend/app/application.py`](https://github.com/ibettison/layMatchedBetting/blob/03d459147906643bcb8dd540dab6e63428a7733c/backend/app/application.py#L84-L133)
- Customer entrypoint:
  [`backend/app/customer_main.py`](https://github.com/ibettison/layMatchedBetting/blob/03d459147906643bcb8dd540dab6e63428a7733c/backend/app/customer_main.py#L1-L3)
- Customer Compose targets:
  [`docker-compose.yml`](https://github.com/ibettison/layMatchedBetting/blob/03d459147906643bcb8dd540dab6e63428a7733c/docker-compose.yml#L17-L70)
- Customer Nginx/API routing:
  [`frontend/nginx.customer.conf`](https://github.com/ibettison/layMatchedBetting/blob/03d459147906643bcb8dd540dab6e63428a7733c/frontend/nginx.customer.conf#L11-L38)
- Installer/Auth API handoff:
  [`install.sh`](https://github.com/ibettison/laymatched-install/blob/1a7328dc89a1b11b9e3dfe838f2dcb223b0f7562/install.sh#L106-L170)
- Installer-generated customer Compose:
  [`install.sh`](https://github.com/ibettison/laymatched-install/blob/1a7328dc89a1b11b9e3dfe838f2dcb223b0f7562/install.sh#L467-L549)

The customer `/api/community/*` and central `/v1/community/*` routes are
separate implementations. **Verified source:** no production customer HTTP
client, central service URL, heartbeat caller, retry queue or version negotiation
was found connecting them. **Approved design:** the existing activation contract
already defines installation identity, signed requests, heartbeat and MFA-status
endpoints; SC-01 must extend or use that contract rather than introduce a
parallel reporting credential or transport. **Runtime unknown:** no live
activation service or customer installation was inspected.

## D. Customer capability inventory

| Journey stage | Current state | Evidence |
|---|---|---|
| Registration/interest | Central interest capture exists; it is not customer-account registration | [`interests.py`](https://github.com/ibettison/layMatchedBetting/blob/03d459147906643bcb8dd540dab6e63428a7733c/backend/app/api/interests.py#L143-L197) |
| Subscription | Central Stripe checkout, idempotency, customer record and webhook state exist | [`billing.py`](https://github.com/ibettison/layMatchedBetting/blob/03d459147906643bcb8dd540dab6e63428a7733c/backend/app/api/billing.py#L15-L54), [`stripe_billing.py`](https://github.com/ibettison/layMatchedBetting/blob/03d459147906643bcb8dd540dab6e63428a7733c/backend/app/stripe_billing.py#L375-L500) |
| Installation | Local installer, Docker, Nginx, database and activation journal exist | [`install.sh`](https://github.com/ibettison/laymatched-install/blob/1a7328dc89a1b11b9e3dfe838f2dcb223b0f7562/install.sh#L308-L328) |
| Release delivery | Installer token authorization and scoped registry pulls exist | [`main.go`](https://github.com/ibettison/laymatched-install/blob/1a7328dc89a1b11b9e3dfe838f2dcb223b0f7562/auth-api/main.go#L695-L734) |
| Customer authentication/MFA | Password sessions, TOTP enrolment, encrypted secret, recovery codes and MFA login challenge exist | [`auth.py`](https://github.com/ibettison/layMatchedBetting/blob/03d459147906643bcb8dd540dab6e63428a7733c/backend/app/auth.py#L213-L375), [`customer_mfa.py`](https://github.com/ibettison/layMatchedBetting/blob/03d459147906643bcb8dd540dab6e63428a7733c/backend/app/customer_mfa.py#L68-L118) |
| Guided onboarding | First-use dashboard, tutorial, NextStep, TodayActions, alerts and milestones exist | [`DashboardHome.tsx`](https://github.com/ibettison/layMatchedBetting/blob/03d459147906643bcb8dd540dab6e63428a7733c/frontend/src/DashboardHome.tsx#L84-L123) |
| Account setup | Searchable catalogue, bulk creation, optional balances, manual fallback and duplicate handling exist | [`AccountSetupPanel.tsx`](https://github.com/ibettison/layMatchedBetting/blob/03d459147906643bcb8dd540dab6e63428a7733c/frontend/src/AccountSetupPanel.tsx#L17-L123), [`mvp.py`](https://github.com/ibettison/layMatchedBetting/blob/03d459147906643bcb8dd540dab6e63428a7733c/backend/app/api/mvp.py#L315-L375) |
| Offer discovery | Local discovery, curated sources and signed-catalogue projection scaffolding exist | [`mvp.py`](https://github.com/ibettison/layMatchedBetting/blob/03d459147906643bcb8dd540dab6e63428a7733c/backend/app/api/mvp.py#L1446-L1625) |
| Calculations | Normal, advanced, Acca and Bet Builder flows exist | [`mvp.py`](https://github.com/ibettison/layMatchedBetting/blob/03d459147906643bcb8dd540dab6e63428a7733c/backend/app/api/mvp.py#L2106-L2225) |
| Execution/tracking | Customer-recorded placement, settlement, ledger, rewards and history exist; no bookmaker API execution was found | [`mvp.py`](https://github.com/ibettison/layMatchedBetting/blob/03d459147906643bcb8dd540dab6e63428a7733c/backend/app/api/mvp.py#L2655-L2886) |
| Support | Bookmaker suggestion and Owner manual records exist; customer support delivery is incomplete | [`CommunitySubmission.tsx`](https://github.com/ibettison/layMatchedBetting/blob/03d459147906643bcb8dd540dab6e63428a7733c/frontend/src/CommunitySubmission.tsx#L1-L52), [`OwnerApp.tsx`](https://github.com/ibettison/layMatchedBetting/blob/03d459147906643bcb8dd540dab6e63428a7733c/frontend/src/OwnerApp.tsx#L118-L145) |

## E. VPS/central connection inventory

| Connection | Authentication | Data/source of truth | Persistence and failure behaviour |
|---|---|---|---|
| Installer → Auth API `/installer/authorize` | Installer token | Approved release, registry token and URL; central Auth API DB/approval file | `curl -fsS`; failure stops install/update; no customer-state queue |
| Docker → private registry | Short-lived scoped JWT | API/web image layers | Pull-only scope; one-hour token TTL |
| Installer → local activation journal | Root filesystem permissions | Installation ID, stage, revision and sanitised error | Atomic local writes and recovery; no central copy |
| Customer API → activation state | Local read-only mount | Installer-owned projection | Returns 503 if unavailable; no remote reporting |
| Customer → community service | No verified remote connection | Customer route currently writes local records | No central destination, retry or version contract found |
| Customer VPS → central activation/heartbeat | Approved contract only; no caller found in inspected source | Existing installer credential, registered installation key, short-lived JWT and signed requests are the approved model | Runtime/report delivery unknown; no parallel reporting credential is proposed |
| Customer VPS → central health/licensing | No verified caller in inspected source | Approved heartbeat/status contract is the intended source | Unknown, never inferred as healthy |
| Stripe → central API | Stripe webhook signature | Subscription/payment state | Central PostgreSQL and idempotent event handling |
| Owner Portal → central API | Owner password + TOTP | Central customer, billing, feedback, communications and finance records | Central-only; no VPS query |

## F. Data ownership and privacy

| Category | Classification |
|---|---|
| Customer identity, email, subscription and Stripe state | CENTRAL AUTHORITATIVE |
| Marketing leads, consent and campaign funnel | CENTRAL AUTHORITATIVE |
| Owner feedback, communications and finance records | CENTRAL AUTHORITATIVE |
| Local accounts, balances, ledger, bets, odds, stakes, exposure, P/L and history | VPS PRIVATE |
| Password hash, session secret, encrypted TOTP secret and recovery hashes | VPS PRIVATE / PROHIBITED CENTRALLY |
| Bookmaker credentials and exchange tokens | PROHIBITED CENTRALLY BY DEFAULT |
| Installation ID, version, schema revision, health, activation stage, MFA boolean and sanitised error | SAFE SERVICE TELEMETRY CANDIDATE; not currently transmitted |
| VPS health, running version, migration state and update result | NOT YET AVAILABLE |
| Central licence status and live onboarding state | NOT YET AVAILABLE |

The customer application should not transmit private betting records, balances,
credentials, passwords, TOTP material or private bookmaker content to central
services by default.

## G. Owner Portal dependency map

| Owner need | Current source | Status |
|---|---|---|
| Customer identity/status | Central `Customer` model | Available |
| Subscription/payment | Central Customer + Stripe records | Available when configured |
| Installation association | `Customer.installation_id` → `CommunityInstallation` | Partial/manual |
| Installation last seen | `CommunityInstallation.last_seen_at` | Misleading in current source: updated by community submissions, not an implemented activation heartbeat |
| Running version, health and update state | None | Unknown |
| Activation/onboarding stage | Local activation journal | VPS-private/unavailable centrally |
| MFA configured | Local `CustomerMfaState` | VPS-private/unavailable centrally |
| Bets, balances, exposure and journey detail | Local customer DB | Correctly private by default |
| Feedback and communications | Central Owner tables | Available manually; delivery not connected |
| Attention queue | Derived from central records only | Partial; missing VPS state |

The Owner Portal explicitly returns unavailable licensing and communications
states rather than treating missing data as healthy:

[`owner_operations.py`](https://github.com/ibettison/layMatchedBetting/blob/03d459147906643bcb8dd540dab6e63428a7733c/backend/app/api/owner_operations.py#L138-L167)

## H. Capability-preservation matrix

| Existing capability | Decision | Acceptance requirement |
|---|---|---|
| Customer password + MFA | Keep on customer VPS | Password-only access cannot reach protected APIs when MFA is enabled |
| Local activation journal | Keep local | Corruption fails closed; no secrets exposed |
| Guided dashboard/TodayActions | Keep and extend carefully | Actions reflect local state and never invent remote health |
| Account catalogue/bulk setup | Keep | Multi-account setup and manual fallback remain operational |
| Reviewed provider catalogue | Keep central/local boundary | Unreviewed providers never become trusted customer providers |
| Offer Finder/calculators | Keep customer-local | Core use remains available without central runtime dependence |
| Manual placement/settlement and ledger | Keep private | Customer financial history remains local and intact |
| Community suggestions | Clarify later | Versioned, authenticated handoff without private betting data |
| Owner customer records | Keep central | Central identity/subscription remains authoritative |
| Owner service health | Build narrowly | Missing/stale reports show UNKNOWN, never HEALTHY |
| Generic CRM expansion | Do not build now | Preserve bounded Owner Portal scope |

## I. Prioritised gaps and risks

### P1 — No implemented VPS-to-central service reporting path

**Verified source:** Owner cannot currently obtain dependable installation
activity, version, health, activation, MFA-status or offline state from a
customer reporter. **Approved design:** heartbeat and MFA-status endpoints
already exist in the activation contract. **Runtime unknown:** this report does
not claim that every live installation lacks the approved service.

### P1 — Customer and installation identities are not fully interlocked in inspected source

The Auth API knows an installer token’s `customer_id`, while the inspected
customer installer currently creates a local installation identity/journal but
does not call the approved activation bootstrap. The approved contract already
defines the missing bridge; implementation and runtime association remain
unverified.

### P1 — Installer/application configuration drift

Current application `origin/main` expects `AUTH_MFA_ENCRYPTION_KEY` and provides
a migration helper, while the checked-out installer `main` still generates
`.env` and Compose without that key:

- Application [`docker-compose.yml`](https://github.com/ibettison/layMatchedBetting/blob/03d459147906643bcb8dd540dab6e63428a7733c/docker-compose.yml#L23-L41)
- Application [`ensure-mfa-encryption-key.sh`](https://github.com/ibettison/layMatchedBetting/blob/03d459147906643bcb8dd540dab6e63428a7733c/scripts/ensure-mfa-encryption-key.sh#L1-L26)
- Installer [`install.sh`](https://github.com/ibettison/laymatched-install/blob/1a7328dc89a1b11b9e3dfe838f2dcb223b0f7562/install.sh#L396-L415)

This is a verified source-level compatibility risk.

### P2 — Artifact identity depends on release discipline

The application has explicit customer targets and boundary tests, but the
installer consumes generic registry image names. Release publication must keep
customer-visible tags strictly customer-profile builds.

### P2 — Community endpoints are duplicated but not interlocked

Similar local and central endpoints exist without a verified network client,
retry queue, version negotiation or delivery state.

### P2 — Owner Portal is operationally partial

Customer records, Stripe state, feedback, communications and finance exist, but
installation health, version, licensing, onboarding state and delivery are not
authoritatively available.

### P2 — Update/recovery paths differ between repositories

The primary application updater contains migration-policy and PostgreSQL
rollback logic. The installer updater primarily pulls/restarts images and waits
for health. They require an explicit compatibility contract.

### P2 — Installer backup and HTTPS paths remain incomplete

The installer README records no automatic backups and HTTP-only operation as
current limitations:
[`README.md`](https://github.com/ibettison/laymatched-install/blob/1a7328dc89a1b11b9e3dfe838f2dcb223b0f7562/README.md#L203-L208)

## J. Reconciled first implementation and staged delivery

The first local engineering change is configuration parity, not a new service
contract. The separately maintained installer currently does not provision or
pass `AUTH_MFA_ENCRYPTION_KEY`, while the application requires it for durable
customer MFA. This must be corrected before relying on upgrades. It is separate
from PR #25 documentation and does not change MFA cryptography or activation
semantics.

The approved activation contract already supplies the identity and transport for
future service-state reporting:

- existing installer credential for bootstrap;
- registered Ed25519 installation key;
- short-lived activation JWT;
- signed requests with timestamp and nonce;
- existing heartbeat endpoint for version/health observations;
- existing status-only MFA endpoint for local MFA state.

No new per-installation reporting credential should be introduced. Any new
fields such as schema revision, activation stage, update state or sanitised
failure category require a reviewed contract revision and architecture gate.

### Stage 1 — installer/application MFA configuration parity

- **Owner:** `laymatched-install`.
- **Scope:** generate a dedicated durable key once when absent, validate existing
  values, preserve it through reruns/upgrades, pass it only to the customer API
  through both generated Compose paths, and fail closed before deployment on
  malformed/duplicate configuration.
- **Prerequisite:** current application configuration contract; no application
  code or cryptography change.
- **Acceptance:** fresh install, legacy upgrade, repeated run, existing key,
  malformed/duplicate key, mode `600`, Compose rendering, and no secret logging.
- **Recovery:** never replace a valid key; stop before pull/restart on invalid
  configuration; retain the old deployment and configuration for inspection.

### Stage 2 — activation-contract fixture/status extension

- **Owner:** shared contract in `laymatched-install`, with a pinned fixture in
  the application repository if required.
- **Scope:** use the existing heartbeat/status endpoints; add only the minimum
  reviewed fields and explicit freshness/unknown semantics.
- **Prerequisite:** activation architecture gate and Stage 1.
- **Acceptance:** schema, backward compatibility, forbidden private fields,
  unsupported-version rejection, and stale-state fixtures.
- **Recovery:** unsupported contract versions fail closed; no customer runtime
  dependency on central availability.

### Stage 3 — central receiver and authoritative persistence

- **Owner:** `layMatchedBetting` central application.
- **Scope:** implement the approved authenticated heartbeat/status path,
  installation/customer association, idempotency, replay protection, retention
  and Owner-safe read state.
- **Prerequisite:** Stage 2 and the approved central identity bridge.
- **Acceptance:** valid, duplicate, wrong-installation, replay, revoked, stale
  and privacy-boundary tests.
- **Recovery:** invalid reports are rejected without partial state; central
  outage does not block the customer application.

### Stage 4 — customer local reporter/outbox

- **Owner:** `layMatchedBetting` customer application plus any approved local
  installer integration.
- **Scope:** collect only approved local state, sign requests, report via the
  local backend, and use bounded retry/outbox handling.
- **Prerequisite:** Stage 3 endpoint and generated/mock client.
- **Acceptance:** offline operation, retry/backoff, deduplication, redaction,
  bounded storage and no betting, balance, credential or MFA-secret payloads.
- **Recovery:** failed reports remain `UNKNOWN` centrally and never block local
  core use.

### Stage 5 — Owner operational read model

- **Owner:** `layMatchedBetting` central application.
- **Scope:** show current, stale, missing and revoked installation state without
  treating absent data as healthy.
- **Prerequisite:** Stage 3 persisted state and agreed freshness policy.
- **Acceptance:** fresh/stale/missing/revoked/contradictory state tests and
  privacy/authorization checks.
- **Recovery:** missing or stale data is visibly `UNKNOWN`; no inferred health.

### Safe MFA and migration acceptance plan

Use a disposable VM/container harness with mocked Auth API, registry and Docker:

1. Missing key generates once, is mode `600`, and is never printed.
2. A second update preserves the exact key; an existing valid key is unchanged.
3. Duplicate/malformed/unsafe values fail closed before deployment.
4. Both generated Compose paths pass the key only to the customer API.
5. Disposable PostgreSQL applies `0032 -> 0033`, restarts with the unchanged MFA
   key, and decrypts a test secret; changing only `AUTH_SESSION_SECRET` does not
   break decryption.
6. An incompatible rollback restores the pre-update database snapshot before
   old application images restart.

No live installation or customer data is required for these tests.

## Validation and stop status

Repository/source inspection was performed with Git and `rg`; the existing
activation contract suite passed **19/19**. Shell syntax checks for both
installer repositories passed. No live services, production queries or
customer data were accessed.

This report revision changes documentation only. The first engineering change
described in Stage 1 was not implemented in this checkout because the checkout
is already the PR #25 documentation branch and branch/worktree switching or a
new worktree was not authorised. PR #25 remains documentation-only and its
branch has not been updated in this work.
