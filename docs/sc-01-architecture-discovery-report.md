# SC-01 — LayMatched Interlocking Architecture Discovery

Date: 2026-09-20

This is a read-only architecture discovery report. No application code,
production configuration, live customer data, or running services were changed.

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
| `ibettison/laymatched-install` | `main` | `1a7328dc89a1b11b9e3dfe838f2dcb223b0f7562` | `origin/main` | Pre-existing modified PAD documentation |

The primary checked-out branch is divergent from current `origin/main` and was
not switched during discovery. Current application behaviour was therefore
audited from the immutable local `origin/main` ref.

Both repositories and remotes were accessible locally. GitHub API connectivity
was intermittent during the final re-check; no external state was changed.

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
separate implementations. No production customer HTTP client, central service
URL, heartbeat, retry queue or version negotiation was found connecting them.

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
| Customer VPS → central health/licensing | Not implemented | No payload/source | Unknown, not healthy |
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
| Installation last seen | `CommunityInstallation.last_seen_at` | Misleading: updated by community submissions, not heartbeat |
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

### P1 — No dependable VPS-to-central service contract

Owner cannot reliably know whether a customer installation is active, current,
healthy, blocked at activation, MFA-configured or offline.

### P1 — Customer and installation identities are not fully interlocked

The Auth API knows an installer token’s `customer_id`, but the generated local
configuration does not establish a durable central Customer association.

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

## J. Recommended first interlocking implementation slice

Implement a bounded, one-way, versioned customer service-state report.

### Customer outcome

The customer application remains fully functional if central services are
unavailable. Only minimal installation/service state is shared.

### Minimum proposed contract

```json
{
  "contract_version": 1,
  "installation_id": "...",
  "application_version": "...",
  "schema_revision": "...",
  "activation_stage": "active",
  "api_health": "healthy",
  "web_health": "healthy",
  "mfa_configured": true,
  "update_state": "current",
  "reported_at": "...",
  "failure_code": null
}
```

Safeguards:

- per-installation credential provisioned during installation;
- TLS, replay/idempotency protection and explicit contract versioning;
- no passwords, TOTP secrets, balances, bets, odds, stakes, P/L or credentials;
- stale reports become `UNKNOWN`;
- customer core operation does not depend synchronously on central availability;
- bounded local retry/outbox contains no sensitive payloads.

### Owner outcome

Owner Portal can show current/unknown service state, last report, application
and schema version, activation stage, MFA-configured boolean, sanitised failure
category and update state.

### Dependencies

1. Central installation/customer association.
2. Versioned contract fixture shared by both repositories.
3. Central persistence and authenticated endpoint.
4. Installer provisioning and preservation of the reporting credential.
5. Customer-local reporter and retry policy.
6. Owner read model with explicit stale/unknown semantics.

### Acceptance tests

- Fresh installation registers once.
- Repeated identical reports are idempotent.
- Valid state appears in Owner Portal.
- Stale state becomes `UNKNOWN`.
- Customer core application remains usable while central is offline.
- Wrong installation, replay, invalid signature and unsupported versions fail.
- No private betting or authentication data appears in transmitted payloads.
- Upgrade preserves installation identity and reporting credential.
- Customer and central artifacts remain unable to access one another’s Owner routes.

### Future repository/branch plan

No implementation branch or PR existed before this report. A later bounded
sequence could use:

1. `laymatched-install`: contract fixture, credential provisioning and
   preservation.
2. `layMatchedBetting`: central endpoint, customer reporter, persistence and
   Owner read model.
3. Coordinated independent exact-SHA review across both repositories.

## Validation and stop status

Read-only repository/source inspection was performed with Git, `rg`, `git show`,
route inspection and cached PR/PAD metadata. No tests, builds, deployments,
production queries or live-service checks were run because this was explicitly
discovery-only.

SC-01 discovery is complete. No application code, production configuration or
live customer data was changed.
