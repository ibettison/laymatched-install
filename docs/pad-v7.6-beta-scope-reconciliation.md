Warning: truncated output (original token count: 35246)
Total output lines: 2829

# LAYMATCHED — PAD v7.6 Beta-Scope Reconciliation

Date: 2026-09-10

Investigation basis: PAD Issue #3 and its v7.1/v7.2/v7.6 clarifications, plus
`ibettison/layMatchedBetting` `origin/main` at commit
`c0fe3704ac722d5428101e3450eea31ef7635fec`.

This is a read-only investigation report. No application code was changed.

## 1. Executive summary

The smallest truthful beta scope is:

- A-07 is partial: single-account manual creation exists, but the clarified
  fast multi-account catalogue and balance workflow is not implemented.
- A-08 is genuinely not implemented for customers. Existing Owner/Admin MFA
  must not be counted.
- A-09a is implemented and needs explicit acceptance/testing only.
- The synthetic customer journey proves the core calculation/journey engine,
  not overall customer application beta readiness.
- Customer UX/guidance, account and money management, and experienced-user
  organisation/workflow tools remain partial beta concerns.
- The Owner Portal is partial and requires targeted development plus
  realistic-data acceptance before it can be the daily operating console.
- B-08 has marketing attribution plumbing, but the actual referral/VPS-credit
  workflow is absent.
- I-06, I-10a, Founding Member Hub, and central Recognition were previously
  promoted into beta and must be restored to the release-gate view.
- M-01 appears complete and production-accepted.

Local frontend tests passed: 15 files and 106 tests. Backend tests could not
run because the repository environment has no usable pytest installation.
Installer tests passed: 10 tests, and activation contract tests passed:
19 tests. These results do not constitute customer or production acceptance.

### Dual-audience product positioning

PAD Issue #3 clarification comment `#5614721639` confirms that LayMatched
explicitly serves two complementary journeys:

- **New to matched betting — “Guide me.”**
- **Already matched betting — “Organise me.”**

The product principle is: **“Automate the admin. Assist the decisions. You
place the bets.”** Useful automation therefore means administrative,
calculation, tracking, and organisation assistance where appropriate—not
autonomous bet placement. The customer remains responsible for placing bets
and for the decisions and confirmations that genuinely require their action.

This clarification reinforces the existing beta concerns around A-07 fast
account onboarding, A-09a balance vigilance, customer UX/contextual guidance,
account and money management, and experienced-user organisation/workflow.
It does not introduce new beta features or change release statuses, and does
not reopen the frozen beta scope.

## 2. Beta matrix

| Requirement | Current status | Evidence | Missing work | Acceptance needed |
|---|---|---|---|---|
| A-07 Fast account onboarding & bookmaker management | 🟡 PARTIAL | `backend/app/api/mvp.py`: `OperatorCreate`, `POST /api/operators`, `POST /api/offers`; `frontend/src/Workspace.tsx`: `AccountCreateForm`, `SetupPanel`, `PlanBet`; `Operator` model/migrations; backend/frontend tests | No predefined searchable catalogue selection, multi-select, bulk creation, spreadsheet-style rapid balance entry, or fast many-account navigation. Manual unsupported-operator creation and deferred balances exist | Implement the smallest fast multi-account flow, then accept on desktop/tablet/mobile with a 20–30-account scenario |
| A-08 Customer MFA | 🔴 NOT IMPLEMENTED | `backend/app/auth.py` has password-only login; TOTP exists only in `backend/app/owner_auth.py` | Customer enrolment, QR/manual secret, activation verification, password+TOTP login, recovery, persistence, and tests | Full implementation and clean-install acceptance |
| A-09a Balance freshness | 🟢 IMPLEMENTED — ACCEPTANCE ONLY | `Operator.balance_updated_at`; migration `0002_bankroll_accounts.py`; reconciliation routes; seven-day `stale_balance` dashboard alert; freshness shown in `DashboardHome.tsx` and `Workspace.tsx` | Explicit automated boundary/restart tests are weak or absent | Verify recent/stale states, prompt, reconciliation update, restart/upgrade persistence, and responsive usability |
| Customer UX, usability & contextual guidance | 🟡 PARTIAL | Core synthetic journey is proven, but current workspace evidence is primarily functional forms/panels and general help text | Deliberate beta usability pass at points of uncertainty; ensure customers are only asked for necessary decisions, confirmations, or actions | Novice and experienced-user acceptance across the normal journey |
| Account & money management | 🟡 PARTIAL | Operator/account creation, balances, movements, freshness timestamps, and bankroll views exist in `mvp.py` and `Workspace.tsx` | Current workflow is not yet proven sufficiently fast, organised, or spreadsheet-replacing for many distributed accounts | Realistic multi-account customer acceptance, including later balance entry and stale-balance handling |
| Experienced-user organisation/workflow tools | 🟡 PARTIAL | Offers, operators, exchanges, bankroll views, and planning workflow exist | Need to prove and, where necessary, improve rapid navigation and organisation for customers with 20–30 accounts and active offers | Experienced matched-bettor acceptance against the intended control-centre outcome |
| B-08 Referral/VPS credit | 🟡 PARTIAL | Marketing `referral_code` capture in `central_models.py`, `campaign.js`, `interests.py`, and `metrics.py`; Owner Leads display | No member referral identity, paid-subscription qualification, abuse protection, reward state, manual VPS-credit workflow, or referral dashboard | End-to-end referral/subscription/reward acceptance after implementation |
| I-06 Automatic DNS/nickname provisioning | 🟡 PARTIAL | Activation OpenAPI/state contracts and `tools/local_activation.py`; installer README still describes HTTP-only/planned HTTPS | Central reservation, real DNS/ACME integration, collision/release handling, customer-facing install path, and HTTPS acceptance | Real customer-style installation on a VPS |
| I-10a Backup/restore | 🟡 PARTIAL | Application `update.sh` and backup documentation contain database backup/rollback logic; installer `update.sh` does not; installer README says automatic backups are not implemented | Protected backup in the actual customer update path, documented restore, and real loss/restore testing | Restore after simulated VPS/data loss |
| M-01 Analytics and Founding 100 interest | 🟢 COMPLETE + ACCEPTED | `campaign.js`; central funnel/lead models and APIs; Owner Leads; frontend/backend tests; v7.6 reports production interest/email path proven | No material beta implementation gap identified | No additional M-01 acceptance gate beyond normal final release checks |
| B-04 Owner Portal / Owner Operations | 🟡 PARTIAL — DEVELOPMENT + REALISTIC-DATA ACCEPTANCE REQUIRED | `backend/app/api/owner_operations.py`, Owner Leads, feedback/communications routes and existing Owner UI provide useful foundations | Daily console still needs practical customer status/onboarding, communications/history/notes, subscriptions/payments, expenses, tax-preparation support, referral/reward visibility, Founding administration, and attention queues; do not expand into full CRM/accounting | Dedicated reconciliation with realistic data and daily-operations acceptance |
| Founding Member Hub | 🔴 NOT IMPLEMENTED | Customer community routes cover bookmaker suggestions only; Owner feedback/communications are owner-only | Authenticated member hub, general bug/idea/feedback intake, history, announcements, and Owner follow-up | Full hub acceptance with a real founding member |
| R-01 Central Recognition | 🟡 PARTIAL | `Recognition.tsx` and `recognitionClient.ts` exist, but the client returns an empty/future profile; recognition contract calls the API future work | Central identity, numbering, contribution history, manual awards, audit/revocation, and authenticated member display | Central recognition acceptance |

## 3. Detailed findings

### A-07 — Fast account onboarding & bookmaker management

The latest PAD clarification defines A-07 as more than manual creation of one
operator. For an experienced matched bettor with 20–30 accounts, beta requires:

- a predefined searchable bookmaker/exchange catalogue;
- checkbox or multi-select selection of many existing accounts;
- bulk creation in one simple action;
- useful bookmaker/exchange distinction;
- an **Add another bookmaker** escape hatch;
- rapid spreadsheet-style balance entry/update;
- fast movement through many accounts without repetitive forms;
- account creation with balances entered later;
- freshness timestamps integrated with A-09a;
- desktop, tablet, and mobile usability.

What currently exists:

- `backend/app/api/mvp.py`: `OperatorCreate`, operator routes, and offer route;
- `backend/app/models.py`: `Operator`;
- `frontend/src/Workspace.tsx`: `AccountCreateForm`, `SetupPanel`, and `PlanBet`;
- `backend/tests/test_mvp_flow.py`;
- `frontend/src/Workspace.test.tsx`.

A normal customer can manually create one arbitrary bookmaker or exchange, pass
validation, see it immediately in the workspace, add an offer, and use it in
the normal workflow. Optional balance entry and freshness timestamps exist.
The code distinguishes bookmakers and exchanges, and responsive layouts exist.

The current customer path does not show a predefined searchable catalogue,
multi-select, bulk account creation, or spreadsheet-style rapid balance entry.
It remains a sequence of individual account forms and therefore does not yet
meet the clarified experienced-user outcome of being easier than maintaining a
spreadsheet. No production or real-customer acceptance evidence was found.

Classification: **🟡 PARTIAL**.

The smallest implementation slice is a focused catalogue/multi-select/bulk
creation and rapid balance-entry experience, retaining the existing manual
escape hatch and deferred-balance behaviour. This is not a request for
sophisticated provider integration.

### A-08 — Customer MFA

Customer login remains password-only:

- `backend/app/auth.py` has username/password login and session creation.
- Login throttling and secure-cookie behavior exist.
- No customer TOTP secret, enrolment state, QR generation, manual-secret
  display, recovery codes, or customer MFA challenge was found.

Owner/Admin MFA is separate and is implemented in `backend/app/owner_auth.py`,
with owner challenges, TOTP verification, replay protection, and owner tests.
That does not satisfy customer A-08. Installer activation documents describe MFA
as a future contract, not implemented runtime.

Classification: **🔴 NOT IMPLEMENTED**.

### A-09a — Balance freshness/vigilance

The required non-scraping freshness subset is substantially present:

- `Operator.balance_updated_at` is persisted.
- Manual balance updates, movements, corrections, and completed pending
  transactions update the timestamp.
- The timestamp is exposed to the frontend.
- Dashboard logic marks balances stale after seven days and creates a
  `stale_balance` alert.
- `DashboardHome.tsx` displays relative freshness and a reconciliation prompt.
- `Workspace.tsx` displays last-reconciled information and freshness guidance.

This is a vigilance mechanism, not automatic bookmaker scraping. Dedicated
tests for the exact seven-day boundary and restart/upgrade persistence are weak
or absent. A real customer journey should verify that reconciling a stale
balance updates or removes the warning.

Classification: **🟢 IMPLEMENTED — ACCEPTANCE ONLY**.

### Customer application readiness beyond the synthetic journey

The previously proven synthetic customer journey demonstrates the **core
matched-betting calculation/journey engine**. It does not prove that the
overall customer application is beta-ready.

The latest PAD clarification requires separate treatment of:

- **Customer experience, usability, and contextual guidance — 🟡 PARTIAL**;
- **Account and money management — 🟡 PARTIAL**;
- **Experienced-user organisation/workflow tools — 🟡 PARTIAL**.

These are beta-readiness concerns, not automatically post-beta enhancements.
The product principle is:

> LayMatched should make complex matched-betting tasks feel simple. Customers
> should only be involved where their decision, confirmation, or action is
> genuinely required.

Guidance should appear throughout the journey, especially at points of
uncertainty. The customer application therefore needs a deliberate usability
and contextual-guidance pass, including the fast many-account workflow in
A-07, before the synthetic journey can be treated as evidence of overall beta
readiness.

### B-08 — Referral/VPS-credit workflow

The application has partial marketing attribution through `referral_code` in
lead and funnel records, public-site attribution storage, interest APIs, and
Owner Leads reporting.

It does not support the frozen B-08 workflow: there is no eligible-member
referral identity, referrer-to-customer relationship, subscription attribution,
qualifying-paid-subscription state, self/duplicate/abuse control, VPS-credit
state, or manual Owner credit workflow. Existing matched-betting reward-credit
code is unrelated.

Classification: **🟡 PARTIAL**.

### B-04 — Owner Portal / Owner Operations

The Owner Portal has useful partial foundations:

- customer and subscription records exist;
- Owner Leads and acquisition reporting exist;
- Owner feedback and communication routes exist;
- Owner-authenticated operations and dashboard surfaces exist.

However, the latest PAD clarification correctly treats B-04 as broader than an
acceptance-only review. The portal is not yet proven complete enough to be the
Owner's daily operating console. Evidence of a complete practical workflow for
all of the following is not present:

- new customers, onboarding progress, and customer status;
- subscription/payment visibility and key payment notes;
- communications history, contact notes, and follow-up tracking;
- internal customer and operational notes;
- expense recording and categorisation;
- tax-preparation information/reporting support;
- founder/referral/reward visibility;
- Founding Member administration;
- clear alerts or work queues for Owner attention.

The requirement is not a full CRM or accounting package. It is a focused
operating console for safely managing the first Founding Member cohort.

Classification: **🟡 PARTIAL — DEVELOPMENT + REALISTIC-DATA ACCEPTANCE REQUIRED**.

### Other frozen-beta requirements

#### I-06 — Automatic DNS/nickname provisioning

The installer contains an activation contract with nickname availability and
reservation paths, DNS/HTTPS state stages, and local activation tooling. This is
contract/local-state work. The activation README states that runtime
implementation and deployment are not authorised. The installer README still
describes HTTP-only operation and planned HTTPS/custom hostnames.

Classification: **🟡 PARTIAL**.

#### I-10a — Minimum backup/restore

The application repository has stronger backup support: `update.sh` performs
pre-update PostgreSQL backups and rollback handling, and
`docs/04-backup-and-recovery.md` documents recovery scenarios.

The actual installer repository's `update.sh` does not provide the required
backup/restore behavior. Its README explicitly says automatic backups are not
implemented. No evidence was found of encrypted/off-server backup or a real
restore after simulated VPS loss.

Classification: **🟡 PARTIAL**.

#### M-01 — Analytics and Founding 100 interest

First-party page/CTA events, UTM/source/referral attribution, interest capture,
Owner aggregate reporting, and the production interest/email path are present.
Relevant tests exist, and v7.6 records production proof.

Classification: **🟢 COMPLETE + ACCEPTED**.

#### Founding Member Hub

Existing customer community functionality is limited to bookmaker suggestions
and offer signals. Owner feedback and communications are owner-authored and
owner-visible. There is no authenticated central founding-member hub for bugs,
ideas, general feedback, announcements, history, or follow-up.

Classification: **🔴 NOT IMPLEMENTED**.

#### R-01 — Central Recognition

`Recognition.tsx`, `recognitionClient.ts`, and the recognition contract provide
a presentation seam, but the client currently returns an empty/future profile.
No authoritative central recognition record, contribution history, manual award
workflow, or authenticated member-facing central recognition API was found.

Classification: **🟡 PARTIAL**.

## 4. ALREADY COMPLETE

PAD can safely turn these green:

- M-01 analytics and Founding 100 interest funnel.
- The core matched-betting calculation/journey engine represented by the
  previously accepted A-01 through A-06 synthetic baseline, subject to the
  PAD's current acceptance record.
- Marketing attribution and production interest/email flow described in v7.6.

A-07 should not be called complete under the strengthened definition. A-09a's
freshness implementation should not be rebuilt, but still requires acceptance.
The core engine being green does not make the overall customer application or
Owner Portal green.

## 5. IMPLEMENTED BUT NEEDS ACCEPTANCE

- A-07 single-account bookmaker/exchange creation, manual unsupported-operator
  escape hatch, deferred balance entry, and immediate normal-workflow use.
- A-09a balance freshness, stale detection, visible vigilance prompt, and
  reconciliation timestamps.

Acceptance should follow the required A-07 UX implementation and be performed
against a clean `origin/main` deployment, including desktop, tablet, and mobile
paths. A-09a can remain acceptance-only if the explicit freshness checks pass.

## 6. GENUINE IMPLEMENTATION GAPS

The smallest implementation slices are:

1. A-07 focused catalogue/search, multi-select/bulk creation, rapid balance
   entry/update, and fast many-account navigation, retaining the manual escape
   hatch and deferred-balance behaviour.
2. Customer application UX/usability/contextual guidance, focused on points of
   uncertainty and the principle that customers act only where genuinely
   required.
3. Account and money management improvements needed to make many-account use
   easier than maintaining a spreadsheet.
4. A-08 customer MFA enrolment, activation, login challenge, recovery, reset,
   throttling, persistence, and clean-install tests.
5. B-08 central referral identity, paid-subscription qualification, abuse
   controls, Owner-visible state, and manual VPS-credit workflow.
6. I-06 central nickname reservation, DNS/ACME integration, collision/release
   handling, and real customer install flow.
7. I-10a backup/restore behavior in the actual installer/update path, with
   protected backup storage and real restoration testing.
8. Owner Portal targeted operational development for customer status,
   communications/notes, subscription/payment visibility, expenses,
   tax-preparation support, referrals/rewards, Founding administration, and
   attention queues, without expanding into a full CRM/accounting package.
9. Founding Member Hub authenticated identity, submissions, history,
   announcements, and Owner follow-up.
10. R-01 authoritative central recognition records and authenticated member
   presentation.

## 7. PAD corrections

Issue #3 should be corrected as follows:

- Keep A-08 as a genuine implementation blocker and explicitly state that
  Owner/Admin MFA does not satisfy Customer MFA.
- Reassess A-07 against the strengthened Fast Account Onboarding & Bookmaker
  Management definition and classify it **partial** until catalogue search,
  multi-select/bulk creation, rapid balance entry, and experienced-user
  usability are implemented and accepted.
- Change A-09a to **implemented — acceptance only**.
- Record separately that the proven synthetic journey is the core calculation/
  journey engine only, not proof of overall customer application readiness.
- Add Customer UX/usability/contextual guidance, Account & Money Management,
  and Experienced-user Organisation/Workflow Tools as partial beta gates.
- Treat B-04 Owner Portal / Owner Operations as **partial — development +
  realistic-data acceptance required**, with the daily-console scope defined by
  the latest PAD clarification.
- Restore B-08 as an explicit frozen-beta gate.
- Restore I-06 as an explicit installer/customer-path gate.
- Restore I-10a as an explicit backup/restore gate, distinguishing application
  `update.sh` support from installer-path support.
- Add the v7.2 Founding Member Hub requirement explicitly to the beta gates.
- Keep central Recognition as an explicit release gate and mark it partial.
- Mark M-01 complete/accepted and remove it from implementation blockers.
- Continue deferring full automatic balance scraping, mailbox features, richer
  intelligence, private AI, paid acquisition, and richer post-beta community
  features.

## 8. Recommended execution order

1. Implement the smallest A-07 fast multi-account catalogue, bulk creation,
   and rapid balance-entry UX while retaining the manual escape hatch.
2. Perform a deliberate customer application UX/usability/contextual-guidance
   pass, including account/money management and experienced-user organisation.
3. Accept A-07 and A-09a through focused clean-environment customer tests.
4. Implement Customer MFA.
5. Perform a dedicated Owner Portal reconciliation/development pass, then
   realistic-data acceptance against the daily operating-console outcome.
6. Establish the central founding-member identity layer needed by the Hub,
   Recognition, and referral workflow.
7. Implement the minimum Hub and central Recognition workflow.
8. Complete I-06 and I-10a through real customer-style VPS installation and
   recovery tests.
9. Implement B-08 against the real customer/subscription identity and Stripe
   lifecycle.
10. Complete Stripe test-mode lifecycle acceptance and final clean-install/
    customer handoff.
11. Perform the final Founding Member Beta RC review.

## 9. Current release blockers

- Customer MFA is not implemented.
- Customer application usability, contextual guidance, account/money
  management, and experienced-user organisation are not yet accepted as
  beta-ready.
- A-07 fast multi-account onboarding is partial and not yet proven complete.
- A-09a freshness implementation requires acceptance.
- Owner Portal / Owner Operations is incomplete for daily operational use and
  requires development plus realistic-data acceptance.
- B-08 referral/VPS-credit workflow is materially incomplete.
- Real DNS/nickname/HTTPS installation acceptance is not demonstrated.
- Required backup/restore behavior is not established in the actual installer
  path.
- Founding Member Hub is not implemented.
- Central Recognition is not authoritative or operational.
- Stripe lifecycle and Owner realistic-data acceptance remain required by PAD.

- Final clean-install, novice-customer, responsive, and production handoff
  acceptance remains outstanding.

M-01 is not a current implementation blocker.

## 10. Dated correction — PR #24 Gate 1 security re-review (2026-09-11)

PAD Issue #3's previous statement that the next task is controlled production
installation-proof acceptance was premature. PR #24 remains part of Gate 1,
and production acceptance is still **UNPROVEN**.

PR #24 re-review status:

- Branch: `fix/gate-1-auth-registry-production-bootstrap`
- Implementation HEAD: `a49594c156508b82d9b70d5f73145ad7bba03094`
- P1-1 resolved: installer-token `/token` exchanges now re-read and validate
  the current approval record; missing, empty, and invalid records return
  503 without issuing a registry JWT. Valid approval retains the restricted
  LayMatched pull scopes, and unknown, revoked, and expired installer tokens
  remain rejected.
- P1-1 owner-path review: owner-token exchanges remain scoped and available
  for release publication and verification before approval advances; owner
  revocation and expiry checks remain enforced.
- P1-2 resolved: approval metadata is migrated to
  `/opt/laymatched-auth/approval/approved_version.txt`, owned by root and
  mounted read-only at `/approval`; Auth API runtime state remains in the
  service-owned data directory, with explicit runtime file modes and reserved
  UID/GID collision checks. The release workflow writes approval only through
  its privileged host path, not through the Auth API container.
- Test evidence: Auth API Go tests, focused approval/token tests, deployment
  tests, installer/security tests, activation contract tests, nginx policy,
  shell syntax checks, workflow shell parsing, and `git diff --check` pass.
  Containerized integration tests could not run because the local Docker API
  socket is unavailable; production acceptance remains unproven.

Gate 1 remains **IN PROGRESS**. Only after both P1 findings are closed with
reviewed evidence should the next task become controlled production
installation-proof acceptance.

## 11. Dated correction — PR #24 release-control re-review (2026-09-11)

This update supersedes the release-control status in the preceding PR #24
correction while preserving that historical entry. PAD Issue #3 is now
current for PR #24 HEAD `760be8e`.

PR #24:

- Branch: `fix/gate-1-auth-registry-production-bootstrap`
- Current HEAD: `760be8e`
- P1-1 remains resolved: Installer-Token `/token` issuance re-reads and
  validates the current approval record and fails closed with no registry JWT
  when the record is missing, empty, or invalid. Valid approval retains only
  the LayMatched API/Web pull scopes; unknown, revoked, and expired Installer
  Tokens remain rejected. Owner release-management exchange remains available
  under its explicit Owner scopes.
- P1-2 remains resolved: `approved_version.txt` is root-controlled at the
  separate `/opt/laymatched-auth/approval` path, mounted read-only into Auth
  API. Runtime SQLite/key state remains service-writable only where required,
  and reserved UID/GID collision checks remain enforced.
- Release-control finding resolved: Docker Distribution repository scopes do
  not constrain a tag, so release candidates now publish only to the
  owner-scoped `laymatched-api-staging` and `laymatched-web-staging`
  repositories. The Owner verifies both candidates there; only then does the
  privileged approval update run, followed by Owner promotion into the
  customer-visible API/Web repositories. Installer credentials receive no
  staging or push scope and can pull the candidate only after promotion.
- Focused evidence covers approved API/Web Installer pulls, unavailable
  unapproved candidate tags before promotion, missing/empty/invalid approval,
  Owner publication/verification, invalid/revoked/expired Installer Tokens,
  and pull-only customer scope.
- Validation: Auth API Go tests pass (`go test ./...`, 16.4s); deployment tests
  pass (23); installer/security tests pass (12); activation contract tests
  pass (19); registry nginx policy, shell syntax, workflow parsing, workflow
  copy identity, and `git diff --check` pass. Docker-backed integration tests
  were attempted but remain UNPROVEN because the local Docker API socket is
  inaccessible (`/var/run/docker.sock` permission denied). Token-tool tests
  were also unavailable locally because this environment has Go 1.22.2 while
  that module requires Go 1.23.

Gate 1 remains **IN PROGRESS**. Production installation-proof acceptance and
direct production-registry confirmation remain **UNPROVEN**; no production
system was contacted or changed.

NEXT TASK: controlled production installation-proof acceptance, after the
required merge approval and under the separate production-change controls.

## 12. Dated final verification — Gate 1 PR #24 (2026-09-11)

This is a new programme-control update; previous PAD history is retained.

### Gate 1 — Installation Proof

PR #24: `#24`

Branch: `fix/gate-1-auth-registry-production-bootstrap`

Current HEAD: `1f8465c560369d4e0920f37485aa089fa4e871a5`

Scope completed:

- Installer `/token` issuance fails closed when `approved_version.txt` is
  missing, empty, or invalid.
- Approval metadata is separated from Auth API runtime state, root-controlled,
  and mounted read-only to the non-root Auth API service.
- Release candidates are built, pushed, and Owner-verified in owner-only
  staging repositories before approval.
- Only approved candidates are promoted into customer-visible API/Web
  repositories. Installer credentials have no staging or push scope.
- Exact application SHA labels are checked for both API and Web images at
  build, staging verification, and post-promotion Installer pull steps.

Previous P1 findings:

- P1-1: resolved. Installer-token `/token` checks the current approved release
  and issues no pull JWT when approval is unavailable. Valid approval preserves
  the restricted API/Web pull scope; invalid, revoked, and expired Installer
  Tokens remain denied. Owner release-management exchange remains available
  under explicit Owner scopes.
- P1-2: resolved. `approved_version.txt` is root-owned under the separate
  `/opt/laymatched-auth/approval` path and read-only-mounted into Auth API.
  SQLite/generated-key runtime state retains only required service write access;
  reserved UID/GID collision checks remain active.

Release-control finding:

- Resolved. Docker Distribution repository scopes do not constrain tags, so
  unapproved candidates are never placed in customer-visible repositories.
  Owner staging publication and verification precede the privileged approval
  update; Owner promotion follows approval. Installer scope remains pull-only
  for the approved customer API/Web repositories.

Validation evidence:

- Auth API Go tests: PASS — `GOCACHE=/tmp/laymatched-install-go-cache go test
  ./...`.
- Focused approval/token/registry tests: PASS, including valid approved flow,
  missing/empty/invalid approval fail-closed, invalid/revoked/expired token
  rejection, staging/push scope denial, and no credential leakage.
- Release workflow/deployment tests: PASS — 23 tests.
- Installer/security tests: PASS — 12 tests.
- Activation contract tests: PASS — 19 tests.
- Nginx/deployment policy: PASS.
- Shell syntax checks: PASS.
- GitHub workflow YAML and embedded shell parsing: PASS.
- Canonical and deployment workflow copies: identical.
- `git diff --check`: PASS.
- Docker-backed integration suite: NOT RUN / UNPROVEN. The command was
  attempted, but every Testcontainers case stopped before setup because
  `/var/run/docker.sock` returned permission denied. No registry or production
  endpoint was contacted.

Security review: customers cannot access staging repositories through the
Installer scope; Installer Tokens cannot obtain push or administration scope;
Owner staging publication and promotion remain scoped; Auth API cannot alter
the trusted approval file; installer/registry credentials remain ephemeral and
are cleaned up; and no secrets are exposed in logs or repository content.

Status:

- Gate 1: **IMPLEMENTED**
- Gate 1: **TESTED** (all runnable repository checks pass)
- Gate 1: **NOT YET DEPLOYED / NOT YET PROVEN LIVE**
- Production installation-proof and direct production registry confirmation
  remain **UNPROVEN** by design.

Recommended NEXT TASK: **controlled production installation-proof acceptance**,
under separate Owner-approved production-change controls. Do not begin it in
this task; PR #24 has not been merged or deployed.

## 13. Post-merge programme update — Gate 1 PR #24 (2026-09-11)

PR #24 has now been merged. Previous PAD entries remain unchanged.

- Gate: **Gate 1 — Installation Proof**
- PR: `#24`
- Feature branch: `fix/gate-1-auth-registry-production-bootstrap`
- Merged PR head: `7c59f02ec031b012f6b4f589ede2a2961f63e0a6`
- Merge commit on `main`: `444357b39d5dbe3f3883e6b5a08662fd59fe9540`
- Scope merged: fail-closed Installer `/token` approval checks; root-controlled
  read-only approval metadata; Owner-only staging publication and verification;
  post-approval promotion into customer-visible repositories; pull-only,
  non-staging Installer scope; exact-SHA API/Web release checks; and ephemeral
  installer Docker credentials.
- P1-1 resolved: missing, empty, or invalid approval prevents Installer
  registry JWT issuance; valid approval supports the restricted API/Web pull
  flow; invalid, revoked, and expired Installer Tokens remain denied; Owner
  release-management exchange remains scoped and available.
- P1-2 resolved: approval metadata is outside Auth API writable state, remains
  root-controlled, and is read-only-mounted to the non-root Auth API; runtime
  database/key ownership and reserved UID/GID collision checks remain enforced.
- Release-control finding resolved: candidates remain in Owner-only staging
  until verification and approval, then are promoted to the customer-visible
  repositories. Installer Tokens cannot access staging or obtain push/admin
  scope.
- Validation before merge: Auth API, focused approval/token/registry,
  deployment, installer/security, activation, nginx policy, shell syntax,
  workflow parsing/copy identity, and `git diff --check` all passed. Docker
  integration assertions remained **UNPROVEN** because the local Docker socket
  denied Testcontainers initialization.
- Deployment status: **NOT DEPLOYED**. Read-only host inspection found the
  running Auth/Registry stack still uses the legacy GHCR/bootstrap compose
  configuration; the repository has no single production deploy command, and
  the production approval file is currently absent. No production container,
  file, DNS record, or certificate was changed.

Gate 1 status:

- **IMPLEMENTED**
- **TESTED** (all runnable repository checks passed)
- **MERGED**
- **NOT YET DEPLOYED / NOT YET PROVEN LIVE**

Recommended NEXT TASK: **controlled production installation-proof acceptance**.
Before execution, the Owner must explicitly establish the intended production
Auth/Registry deployment target and approved application release version.

## 14. Dated programme update — Gate 2A PR #244 preflight portability correction (2026-09-12)

This is a new programme-control update; previous PAD history is retained.

### Gate 2A — Safe local onboarding projection

- PR: `#244`
- Repository: `ibettison/layMatchedBetting`
- Branch: `gate-2a-requalification`
- Current PR HEAD: `e96119dfbb4a82db713b5c297b41b45ac2a63ba6`
- Base: `main`
- Commit: `Fix Gate 2A preflight checkout portability`

Scope of this correction:

- Removed the preflight guard's dependency on the historical
  `/tmp/laymatched-gate2a-requalification` checkout path.
- The guard continues to derive the active repository root using
  `git rev-parse --show-toplevel` and reports that root in its pass output.
- Existing remote, branch, expected-base, clean-worktree, changed-file
  allowlist, and credential-like diff protections remain in force.
- Added a focused portability test using an isolated checkout whose path
  contains spaces.

Validation evidence:

- `bash -n scripts/gate2a-preflight.sh scripts/test_gate2a-preflight.sh`: PASS.
- ShellCheck: PASS.
- Focused preflight portability test: PASS. The guard passed from an isolated
  checkout at a space-containing path.
- `git diff --check`: PASS.
- Prior exact-HEAD application validation remains applicable because this
  correction changes only the preflight guard and its focused test: frontend
  124/124 tests passed; backend onboarding tests passed; frontend build passed;
  and lint reported zero errors with four pre-existing warnings. The full
  backend regression suite remained inconclusive after exceeding ten minutes
  without a completion result.
- No GitHub workflow checks or commit statuses are reported for this branch.

Independent review status:

- Fresh exact-SHA review of `e96119dfbb4a82db713b5c297b41b45ac2a63ba6`:
  **CHANGES REQUESTED / AMBER**.
- Review reference:
  https://github.com/ibettison/layMatchedBetting/pull/244#issuecomment-5647330349
- The portability correction was assessed as correct. The remaining finding
  is that the customer-only activation panel is also shipped in the central
  frontend, where `/api/activation/onboarding` is not mounted. It therefore
  retries 404 responses indefinitely in the central workspace, creating
  avoidable API traffic/log noise and exceeding the customer-only scope.

Security and release status:

- The portability correction does not add application integrations, credentials,
  private material, migrations, deployment changes, or production access.
- The preflight safety checks remain active.
- PR #244 is **NOT MERGE-READY** pending the central-profile scope correction,
  a central-profile test proving no activation request is made, and fresh
  exact-SHA validation/review.
- No merge, deployment, or Gate 2A live acceptance has occurred.

NEXT TASK: correct the customer-only activation panel scope in PR #244, add the
central-profile no-request test, rerun exact-HEAD validation and independent
review, then append the resulting evidence here before requesting merge approval.

## 15. Dated programme update — Gate 2A PR #244 customer artifact activation gate (2026-09-12)

This update supersedes the open Gate 2A action in section 14 while retaining
the prior history.

### Scope completed

- PR: `#244`
- Repository: `ibettison/layMatchedBetting`
- Branch: `gate-2a-requalification`
- Final PR HEAD: `891d2ed377204b70794aadc8cf012e449bdd8b89`
- Base: `main` at `928b131b7ae04246fc7dce7636516d39a358a59f`
- The activation panel is compile-time gated to the customer artifact/profile;
  the central artifact does not mount it.
- The central frontend regression test proves `/api/activation/onboarding` is
  not requested. The customer-profile integration test proves the customer
  `App` mounts the panel and requests the endpoint.
- Customer and central Vitest discovery are explicit and non-overlapping, and
  the standard frontend `npm test` command runs both profiles.
- The preflight guard continues to derive the actual checkout root and keeps
  its remote, branch, base, clean-worktree, changed-file allowlist, and
  credential-like diff protections. Its isolated checkout regression uses a
  path containing spaces.

Validation evidence pinned to final HEAD:

- Standard frontend `npm test`: central profile 125/125 across 16 files, then
  customer profile 1/1.
- `npm run lint`: 0 errors and 4 pre-existing warnings.
- `npm run build` and `npm run build:customer`: PASS.
- Central bundle contains 0 `/api/activation/onboarding` references; customer
  bundle contains 1 expected reference.
- Backend activation/onboarding and activation-state tests: 15 passed.
- `bash -n`, ShellCheck, direct Gate 2A preflight, isolated non-standard
  checkout preflight test, and `git diff --check`: PASS.
- PR diff summary from base to final HEAD: 15 allowlisted files changed,
  574 insertions and 1 deletion. No unrelated repository paths were included.
- No GitHub workflow runs or commit-status checks are available for this PR.
- The full backend regression suite remains inconclusive from the previously
  recorded run; it was not rerun because this correction is frontend test
  profile/build wiring and the focused backend activation tests pass.

Independent review status:

- Fresh automated exact-SHA review of final HEAD `891d2ed377204b70794aadc8cf012e449bdd8b89`:
  **CHANGES REQUESTED / AMBER**.
- Review reference:
  https://github.com/ibettison/layMatchedBetting/pull/244#issuecomment-5647536677
- The review confirmed that profile-specific discovery is non-overlapping and
  that the standard command runs both profiles. It initially requested exact
  final-HEAD validation evidence; that evidence was subsequently rerun on the
  clean final HEAD and attached to PR #244:
  https://github.com/ibettison/layMatchedBetting/pull/244#issuecomment-5…15246 tokens truncated…overy token, credential, or deployment
material has been added to PAD.

NEXT TASK: obtain a fresh independent exact-SHA security review of PR #251 at
`6509aaf9d840c5c95800f8617ab7f2c8fcf53afd`; do not merge or deploy before that
review and explicit Owner approval.

## 37. A-08 MFA encryption-key lifecycle correction — PR #251 (2026-09-15)

The independent security review identified a P1 key-lifecycle issue in the
previous A-08 implementation: durable customer TOTP secrets were encrypted
using a key derived from `AUTH_SESSION_SECRET`. This record corrects that
decision; the prior record remains preserved as history.

### Release identity

- Repository: `ibettison/layMatchedBetting`.
- Branch: `a-08-customer-mfa`.
- PR: [#251](https://github.com/ibettison/layMatchedBetting/pull/251) — OPEN,
  unmerged and undeployed.
- Corrected implementation HEAD:
  `f78de8ef71dd9cd254a7c8211af0f698ded4c32d`.

### Security-key decision and implementation

- Added dedicated `AUTH_MFA_ENCRYPTION_KEY` configuration, independent of
  `AUTH_SESSION_SECRET`.
- Preserved AES-GCM authenticated encryption and HKDF derivation.
- Missing or shorter-than-32-character MFA encryption configuration fails
  closed when MFA secret encryption is required; the key is never logged or
  returned by the application.
- Installer and credential generation create the dedicated key, Compose passes
  it only to the API, and the normal protected `.env` backup path preserves it
  across restart and upgrade.
- Production configuration documentation now requires retaining this key when
  rotating the session-signing secret.

### Validation evidence

- Customer MFA, authentication, throttling, deployment configuration, and
  migration revision tests: **27 passed**.
- Regression explicitly encrypts a TOTP secret, changes `AUTH_SESSION_SECRET`,
  and successfully decrypts with the unchanged MFA key.
- Missing/invalid dedicated-key encryption failure: **passed**.
- Compose API wiring and installer preservation assertions: **passed**.
- Python compileall: **passed**.
- `bash -n install.sh update.sh`: **passed**.
- `git diff --check`: **passed**.
- Frontend suites were not rerun because no frontend files changed in this
  bounded backend/configuration correction.
- Full backend suite was not rerun for this bounded correction; the prior
  recorded full-suite result remains **INCONCLUSIVE**, not failed.

### A-08 status

- **IMPLEMENTED:** YES — dedicated key lifecycle correction is at the exact
  HEAD recorded above.
- **TESTED:** YES — 27 focused/relevant tests and static checks passed.
- **DEPLOYED:** NO.
- **ACCEPTED-PROVEN LIVE:** NO.

The remaining gate is a fresh independent exact-SHA security review of the
corrected PR, followed by explicit Owner approval. No merge or deployment has
been performed, and no customer credentials, TOTP secrets, recovery tokens, or
other sensitive values were added to PAD.

NEXT TASK: obtain a fresh independent exact-SHA security review of PR #251 at
`f78de8ef71dd9cd254a7c8211af0f698ded4c32d`; do not merge or deploy before that
review and explicit Owner approval.

## 38. A-08 customer MFA merged and deployed (2026-09-15)

PR #251 has passed the fresh independent exact-SHA security review and has
been merged and deployed. The dedicated MFA encryption-key correction is part
of the deployed release.

### Release identity

- Repository: `ibettison/layMatchedBetting`.
- PR: [#251](https://github.com/ibettison/layMatchedBetting/pull/251) —
  **MERGED**.
- Approved implementation HEAD:
  `f78de8ef71dd9cd254a7c8211af0f698ded4c32d`.
- Merge commit and resulting deployed `main` SHA:
  `4865091449e8d5f4d4835a0b63a807cd9fe76cd2`.

### Deployment evidence

- Standard deployment: `/opt/laymatched-betting/update.sh` completed
  successfully from `01f2113` to `4865091`.
- API health: **200**.
- Root/customer application: **200**.
- Protected MFA status without a session: **401**, confirming the auth
  boundary remains enforced.
- API, web, and PostgreSQL containers reported healthy.
- The existing production `.env` had no MFA key because it predated A-08. A
  fresh persistent key was added without exposing its value; `.env` remains
  root-owned with mode `600`. The API was recreated and verified with the key
  configured.
- Deployment retained a rollback snapshot at
  `/opt/laymatched-betting/.deployment-backups/20260915T071837Z-4865091`.
- The deploy script reported migration compatibility as **unknown** while
  moving from `0032_public_interest_recovery` to `0033_customer_mfa`; the API
  started healthy and reported revision `0033_customer_mfa`.

### A-08 status

- **IMPLEMENTED:** YES.
- **TESTED:** YES — focused security/configuration validation passed before
  merge; deployment health and auth-boundary checks passed after deployment.
- **DEPLOYED:** YES — resulting `main` SHA is deployed and healthy.
- **ACCEPTED-PROVEN LIVE:** NO — the complete customer MFA journey through the
  trusted HTTPS hostname and customer devices has not yet been independently
  demonstrated.

Remaining acceptance evidence is customer-device verification of enrollment,
QR/manual setup, password-plus-TOTP login, invalid-code handling,
recovery/reset, and persistence after restart/upgrade. No MFA secret or other
sensitive value has been added to PAD.

NEXT TASK: perform controlled live A-08 acceptance through the customer's
trusted HTTPS hostname, including enrollment, second-factor login, recovery or
reset, and restart/upgrade persistence; then record whether A-08 is
ACCEPTED-PROVEN LIVE. Do not begin a new security feature before that gate is
recorded.

## 39. A-08 legacy customer deployment-path repair — PR #252 (2026-09-15)

The A-08 live diagnostic identified a pre-existing upgrade/deployment-path
defect on older customer installations: the default Compose configuration
selected the central API/web build targets even though A-08 MFA is correctly
customer-artifact-only. The diagnostic also found that legacy installations
did not receive a missing durable MFA encryption key automatically and that
the tracked migration compatibility metadata was absent from the deployment
path. This correction addresses those deployment concerns without changing
MFA cryptography, TOTP behavior, recovery codes, or authentication semantics.

### Release identity

- Repository: `ibettison/layMatchedBetting`.
- Branch: `a-08-customer-deployment`.
- PR: [#252](https://github.com/ibettison/layMatchedBetting/pull/252) —
  **OPEN / UNMERGED**.
- Implementation HEAD: `4ed0038bc1050ab2bc31bd41da436dcf0d7256dc`.
- Base: `main` at `4865091449e8d5f4d4835a0b63a807cd9fe76cd2`.

### Implementation

- Default customer Compose now selects the `customer` API and web targets;
  central Owner credential wiring is not passed through that profile.
- Customer health gates use the customer root application and customer session
  route.
- Legacy `.env` upgrades use an idempotent helper: a missing
  `AUTH_MFA_ENCRYPTION_KEY` is generated once and persisted with mode `600`;
  valid existing values are preserved; malformed or duplicate values fail
  closed; the value is never printed.
- The release carries reviewed migration metadata for
  `0032_public_interest_recovery -> 0033_customer_mfa`. The metadata records
  that downgrade compatibility is not tested, and unknown compatibility now
  fails safely rather than leaving an updated installation running without a
  decision. Rollback of this known untested downgrade uses the pre-update
  database backup.
- Controlled deployment documentation now describes the customer artifact
  and metadata location. No live installation or production data was changed.

### Validation evidence

- Upgrade-path and customer-artifact boundary tests: **10 passed**.
- Focused backend customer-artifact, MFA, deployment-auth-config, and
  migration-revision tests: **32 passed** with one existing Alembic
  deprecation warning.
- Customer artifact build/inspection: **passed**.
- Explicit central web/API target builds and central API import smoke check:
  **passed**.
- Rendered Compose validation: **passed**; API and web targets both resolve to
  `customer` and the customer profile contains no central Owner credential
  wiring.
- Python `compileall`: **passed**.
- Shell syntax (`bash -n install.sh update.sh
  scripts/ensure-mfa-encryption-key.sh`): **passed**.
- `git diff --check`: **passed**.
- Full backend suite: not rerun for this bounded deployment/configuration
  correction; the previously recorded full-suite result remains
  **INCONCLUSIVE**, not failed.

### A-08 status

- **IMPLEMENTED:** YES — the legacy customer deployment-path correction is
  implemented at the exact HEAD above.
- **TESTED:** YES — focused deployment, customer-boundary, MFA/configuration,
  migration, build, and static validation passed.
- **DEPLOYED:** NO — PR #252 is not merged and no live installation was
  changed.
- **ACCEPTED-PROVEN LIVE:** NO.

Remaining acceptance evidence is a fresh independent exact-SHA review of PR
#252, followed by explicit Owner approval before merge and deployment. After a
successful deployment, the old installation still requires live verification
that the customer artifact is served, A-08 setup is discoverable, and the
legacy key/migration path behaves as recorded. No sensitive key value or
customer data has been added to PAD.

NEXT TASK: obtain a fresh independent exact-SHA review of PR #252 at
`4ed0038bc1050ab2bc31bd41da436dcf0d7256dc`; do not merge or deploy before that
review and explicit Owner approval.

## 40. A-08 migration rollback-policy clarification — PR #252 (2026-09-15)

The independent review of PR #252 found one bounded migration-safety ambiguity:
the field `compatible: false` did not distinguish an allowed forward migration
from an unsafe rollback of old application images against the migrated schema.
This correction preserves the customer deployment and legacy MFA-key work while
making that distinction executable and explicit.

### Release identity

- Repository: `ibettison/layMatchedBetting`.
- Branch: `a-08-customer-deployment`.
- PR: [#252](https://github.com/ibettison/layMatchedBetting/pull/252) —
  **OPEN / UNMERGED**.
- Corrected implementation HEAD:
  `461531bcb336334d68ebcb3d1f09160b8ca6ae55`.
- Previous reviewed HEAD:
  `4ed0038bc1050ab2bc31bd41da436dcf0d7256dc`.

### Exact semantics and correction

- `forward_migration: "permitted"` means the reviewed forward Alembic
  migration may be applied.
- `rollback_database_compatible: false` means the previous application images
  must not run against the migrated database; rollback must restore the
  pre-update PostgreSQL snapshot first.
- Missing, malformed, unknown, or blocked policy fails closed.
- Rollback now leaves application containers stopped when the snapshot is
  missing or restoration fails; it cannot restart old images against an
  uncertain schema.
- The `0032_public_interest_recovery -> 0033_customer_mfa` entry explicitly
  permits the forward migration and requires database restoration for rollback.

### Validation evidence

- Exact policy/upgrade/rollback regression suite:
  **14 passed**. This executes the policy helper for the `0032 -> 0033` path,
  verifies unknown and blocked forward decisions fail closed, and exercises
  missing-snapshot, failed-restore, and successful restore-before-restart
  rollback branches with isolated mock services.
- Current customer Compose boundary tests are included in the 14 passed.
- Current shell syntax, Python policy compilation, backend `compileall`,
  Compose render validation, and `git diff --check`: **passed**.
- The previously recorded focused backend customer-artifact/MFA/deployment/
  migration suites remain **32 passed** at the prior implementation HEAD; no
  backend application files changed in this bounded clarification.
- Full backend suite remains **INCONCLUSIVE**, not failed.
- No live installation, production database, or production MFA key was
  changed.

### A-08 status

- **IMPLEMENTED:** YES — migration policy semantics and rollback guard are
  implemented at the corrected HEAD.
- **TESTED:** YES — bounded deployment/migration/rollback tests and static
  validation passed.
- **DEPLOYED:** NO — PR #252 remains unmerged.
- **ACCEPTED-PROVEN LIVE:** NO.

NEXT TASK: obtain a fresh independent exact-SHA review of PR #252 at
`461531bcb336334d68ebcb3d1f09160b8ca6ae55`; do not merge or deploy before that
review and explicit Owner approval.

## 41. A-08 legacy metadata compatibility correction — PR #252 (2026-09-15)

The final independent review identified one remaining legacy-upgrade edge case:
an obsolete local `.migration-metadata.json` could shadow the packaged policy
and be unreadable by the new parser. The correction does not reinterpret the
ambiguous legacy `compatible` field.

### Release identity

- Repository: `ibettison/layMatchedBetting`.
- Branch: `a-08-customer-deployment`.
- PR: [#252](https://github.com/ibettison/layMatchedBetting/pull/252) —
  **OPEN / UNMERGED**.
- Corrected implementation HEAD:
  `e4ef50b1cc045e4c241544976cc347897b5b9cdc`.
- Previous reviewed HEAD:
  `461531bcb336334d68ebcb3d1f09160b8ca6ae55`.

### Exact correction

- The executable migration-policy resolver considers a local metadata file
  only when it contains the current explicit fields for the exact upgrade:
  `forward_migration` and `rollback_database_compatible`.
- Missing local metadata, obsolete `compatible` metadata, malformed local
  metadata, or local metadata without an exact valid policy cannot shadow the
  packaged reviewed policy.
- The packaged reviewed policy is used when available; if neither source has
  an explicit valid policy, resolution fails closed.
- For `0032_public_interest_recovery -> 0033_customer_mfa`, forward migration
  remains permitted and rollback still requires successful restoration of the
  pre-update PostgreSQL snapshot before old application images restart.

### Validation evidence

- Customer upgrade, migration-policy, rollback, and customer-boundary
  regressions: **15 passed**.
- Coverage includes absent local metadata fallback, valid current local
  override, legacy-format fallback, malformed/unknown fail-closed behavior,
  the full `0032 -> 0033` decision, missing/failed snapshot protection, and
  restore-before-restart ordering.
- Shell syntax, policy compilation, backend `compileall`, Compose render
  validation, and `git diff --check`: **passed**.
- No MFA authentication behavior or production state was changed.

### A-08 status

- **IMPLEMENTED:** YES — legacy metadata selection is corrected at the exact
  HEAD above.
- **TESTED:** YES — bounded deployment/migration/rollback validation passed.
- **DEPLOYED:** NO — PR #252 remains unmerged.
- **ACCEPTED-PROVEN LIVE:** NO.

NEXT TASK: obtain a final independent exact-SHA review of PR #252 at
`e4ef50b1cc045e4c241544976cc347897b5b9cdc`; do not merge or deploy before that
review and explicit Owner approval.

## 42. PR #252 merged; customer deployment blocked and recovered (2026-09-15)

PR #252 was merged after Owner authorization, but the resulting customer
deployment was not successful. The candidate customer API failed during
startup migration because the customer image omits migration
`0024_marketing_leads` while later migrations still reference it. This is a
customer-artifact migration-chain defect discovered during deployment; it is
not an A-08 MFA behavior change.

### Release and recovery identity

- PR: [#252](https://github.com/ibettison/layMatchedBetting/pull/252) —
  **MERGED**.
- Approved implementation HEAD:
  `e4ef50b1cc045e4c241544976cc347897b5b9cdc`.
- Merge commit and resulting `main` SHA:
  `92e58c9f3ec044962c28591eed4282c782ac92b2`.
- Deployment attempt: `/opt/laymatched-betting/update.sh` from `4865091` to
  `92e58c9`.
- Final live runtime after recovery: prior `4865091` release; merged
  `92e58c9` is **NOT DEPLOYED**.

### Deployment evidence

- Candidate customer API startup: **FAILED** — Alembic could not resolve
  `0024_marketing_leads` referenced by a later migration.
- Pre-update PostgreSQL snapshot restoration: **SUCCEEDED**.
- Automatic rollback health: **NOT GREEN**; previous API remained in restart
  loop because the updater’s previous image retag did not recover the runtime.
- Recovery: retained pre-deployment central API/web images containing the A-08
  migration were restored and recreated without changing source or database
  data.
- Post-recovery API health: **200**.
- Root application: **200**.
- Legacy `/app/`: **200**.
- Protected API without session: **401**.
- Owner session health: **200**.
- API, web, and PostgreSQL containers: **healthy**.
- The deployment result and recovery evidence were posted to PR #252 in
  [comment #5677393931](https://github.com/ibettison/layMatchedBetting/pull/252#issuecomment-5677393931).

### A-08 / deployment status

- **IMPLEMENTED:** YES — PR #252 is merged.
- **TESTED:** YES — bounded implementation validation passed before merge.
- **DEPLOYED:** NO — the merged customer deployment failed its startup
  migration gate and live runtime was restored to `4865091`.
- **ACCEPTED-PROVEN LIVE:** NO.

No production customer data was intentionally modified, and no MFA key was
regenerated. The customer artifact migration chain must be corrected and
validated before another deployment attempt.

NEXT TASK: create a bounded customer-artifact migration-chain correction for
the missing `0024_marketing_leads` dependency, obtain independent exact-SHA
review, and only then retry controlled deployment. Do not claim PR #252 is
deployed or A-08 live-accepted.

## 43. Customer migration-chain correction deployed (2026-09-15)

The bounded follow-up corrected the legacy customer artifact migration chain
and completed a controlled deployment retry. The customer image now retains
the complete Alembic chain, including `0024_marketing_leads`, while continuing
to exclude central runtime modules. This preserves the customer/central
artifact boundary and allows later migrations, including `0033_customer_mfa`,
to resolve their declared parents.

### Release identity

- PR: [#253](https://github.com/ibettison/layMatchedBetting/pull/253) —
  **MERGED**.
- Branch: `a-08-customer-migration-chain`.
- Implementation HEAD: `407edc1a74549b7a93b7d9b1bfa3ca835f365767`.
- Merge commit and resulting `main` SHA:
  `2dff9f41e32fb2c93d3d28a9980ba3df8ea8d873`.

### Exact correction

- Customer `backend/Dockerfile` now removes only `app/central_models.py` and
  retains the complete `alembic/` directory.
- Customer artifact tests assert that `0024_marketing_leads.py` is present and
  the migration script resolves head `0033_customer_mfa`.
- An isolated customer image migrated a fresh PostgreSQL database through every
  revision to `0033_customer_mfa`.
- The migration-policy resolver now treats identical old/new revisions as a
  permitted no-op with rollback database compatibility, which is required for
  safe redeployment of installations already at `0033_customer_mfa`.

### Deployment and recovery evidence

- First retry from the recovered legacy checkout correctly built the customer
  candidate, but the old loaded updater probed the customer root as `/app/`;
  the customer artifact intentionally redirects `/app/` to `/`, so the health
  gate rejected that candidate with `302`.
- The updater restored the PostgreSQL snapshot. The old API image tag was not
  recovered automatically, so the central API was rebuilt from the explicitly
  restored `4865091` checkout before retrying. No production customer data or
  MFA key was changed or regenerated.
- The successful retry used the customer-aware updater from the merged release
  against `/opt/laymatched-betting` and completed:
  `4865091 -> 2dff9f4`.
- API health: **200**; customer root: **200**; protected bankroll without a
  session: **401**; customer session endpoint: **200**.
- API, web, and PostgreSQL containers: **healthy**.
- Live database revision: `0033_customer_mfa`.
- Live customer API artifact check: central runtime modules absent; complete
  migration chain present; migration head `0033_customer_mfa`.
- Deployment snapshot retained at
  `/opt/laymatched-betting/.deployment-backups/20260915T092300Z-2dff9f4`.

### Validation evidence

- Customer artifact boundary tests: **6 passed**.
- Customer artifact and migration revision tests: **22 passed**, with one
  pre-existing Alembic deprecation warning.
- Customer upgrade/migration-policy/rollback tests: **16 passed**.
- Customer artifact build and filesystem/chain inspection: **passed**.
- Isolated PostgreSQL customer-image migration: **passed**, ending at
  `0033_customer_mfa`.
- Shell syntax, Python compilation, Compose config rendering, and
  `git diff --check`: **passed**.

### A-08 status

- **IMPLEMENTED:** YES — A-08 and the required legacy customer deployment-path
  correction are merged.
- **TESTED:** YES — focused migration-chain, customer-boundary, policy,
  rollback, artifact-build, and live health validation passed.
- **DEPLOYED:** YES — resulting `main` SHA `2dff9f41e32fb2c93d3d28a9980ba3df8ea8d873`
  is running in the customer profile.
- **ACCEPTED-PROVEN LIVE:** NO — the owner has not yet completed the live MFA
  enrolment, QR/manual-secret, recovery, disable/reset, and re-login journey
  through the trusted customer hostname.

No unrelated application behavior was changed in PR #253. No credentials,
MFA secrets, or production customer records were exposed or intentionally
modified.

NEXT TASK: perform the owner-controlled live A-08 acceptance journey through
the trusted customer HTTPS hostname, including MFA setup, valid/invalid code
handling, recovery/reset, persistence, and password-plus-TOTP re-login; then
record ACCEPTED-PROVEN LIVE only if that evidence succeeds.

## 45. Installer DNS recovery and HTTPS support-file fix (2026-09-22)

The reported installer run first timed out while waiting for customer DNS, then
recovered to DNS ready on retry. Let's Encrypt issued the customer certificate,
but Nginx could not enable HTTPS because
`/etc/letsencrypt/options-ssl-nginx.conf` was absent. This issue and recovery
were reported by the operator; the customer VPS was not accessed as part of
this work.

### Root cause and correction

- The installer installs the base Certbot package and uses `certonly
  --webroot`; that flow does not guarantee Certbot's Nginx options file exists.
- The HTTPS helper referenced missing Certbot TLS support files when rendering
  the TLS site. It now atomically creates a root-owned options file with TLS
  1.2/1.3 settings and an FFDHE 2048 parameter file before certificate
  issuance or enabling HTTPS.
- The helper already installs a Certbot renewal deploy hook that validates and
  reloads Nginx and reports HTTPS status. The redundant command-line deploy
  hook was removed so certificate issuance uses one renewal hook path. The
  exact warning text from the customer run was not available to attribute more
  specifically.
- Retry flow remains on the existing activation session and reservation. The
  helper preserves pre-existing HTTPS configuration on failure and does not
  delete issued certificates. A still-valid certificate is reused on retry;
  Certbot retains responsibility for normal renewal when a certificate is due.

### Release and verification

- PR: [#37](https://github.com/ibettison/laymatched-install/pull/37),
  separate from merged PR #36; **MERGED**.
- HTTPS implementation commit: `154d4005d3d763d5fe2de0d7fc557e647f6cc56d` on
  `fix/customer-https-tls-support`, targeting `main`; the PR also includes a
  follow-up PAD metadata commit.
- Merge commit and resulting `main` SHA:
  `f354bbb9a11f692bd1d6cfb84a28886f45767fa7`.
- Changed files: `scripts/configure-customer-https.sh`, `update.sh`,
  `tests/test_customer_dns_https.py`, and this section.
- `tests/test_customer_dns_https.py` and
  `tests/test_installer_activation_resume.py`: **16 passed**.
- Shell syntax (`bash -n install.sh update.sh
  scripts/configure-customer-https.sh`): **passed**.
- `git diff --check`: **passed**.
- Embedded updater helper fallback reproducibility and byte comparison:
  **passed** as part of the DNS/HTTPS suite.
- **MERGED:** YES — PR #37 merged after the focused checks passed.
- **DEPLOYED ON FASTHOSTS:** NO — this installer repository has no documented
  Fasthosts deployment workflow or target path. Its documented Fasthosts
  deployment process belongs to the separate application repository; applying
  this installer change there would not update the installer safely.
- **AWS CUSTOMER VPS:** NOT ACCESSED OR MODIFIED. Safe update-and-resume
  commands are provided in the work review for the operator to run after the
  merged fix is available.

### HTTPS challenge-routing follow-up (2026-09-22)

The subsequent HTTPS proof returned HTTP 422 with
`X-Activation-Error: https_failed` and the detail “Independent HTTPS
verification failed.” The customer homepage returned HTTP 200 with valid TLS,
and the challenge file existed below `/var/www/letsencrypt/.well-known/laymatched-https/`,
but requesting it over HTTPS returned HTTP 404. Inspection confirmed that the
port 80 server mapped this path to `/var/www/letsencrypt`, while the port 443
server had only the application proxy route. The challenge request therefore
went to the application instead of Nginx's static-file handler.

The HTTPS server template now has a `^~ /.well-known/laymatched-https/`
location rooted at the configured challenge directory, serves it as
`text/plain`, and returns 404 for a missing challenge file. The HTTP challenge
routes, TLS settings, certificate files, activation session and reservation
flows are unchanged. A focused rendered-configuration regression verifies
that HTTPS challenge requests use this static route and remain separate from
the application proxy.

- Focused HTTPS retry/challenge-route test function and embedded-helper
  reproducibility test function, run directly with temporary directories:
  **passed (2)**.
- Shell syntax for `scripts/configure-customer-https.sh` and `update.sh`, and
  `git diff --check`: **passed**. The pytest runner was unavailable; installing
  it in an isolated `/tmp` environment was blocked because package DNS was
  unavailable.
- Fasthosts deployment: not performed; no documented installer deployment
  target/procedure was available. AWS was not accessed or modified.

### Customer application release and login-route acceptance follow-up (2026-09-23)

The operator reported that the disposable AWS install reached MFA onboarding
with API and web image tags `v0.1.1`. The installer prompt pointed to the
customer hostname root, which returned Nginx 404; `/app` returned a login
screen. The operator stopped before completing activation because that image
was identified as an old application version. AWS was not accessed for this
review; these observations are operator-provided evidence.

### Root cause and correction

- The installer has no `v0.1.1` fallback. Fresh install and resume both use
  `approved_version` returned by the authorization API. Resume writes that
  approved tag and registry to a candidate environment, pulls both images,
  runs Compose `up -d`, and only persists the candidate version after health
  checks. Therefore an old healthy local image is not intentionally accepted
  in place of the authorized tag.
- The authorization API reads its approved tag from central
  `approved_version.txt`; the release workflow supplies that value from its
  explicitly approved version input. The observed image tag is consistent
  with the value served by that release contract, but this review did not read
  live central approval metadata or inspect the AWS containers. The exact
  approved current tag and image digests remain to be confirmed through the
  operator's approved release record. No replacement tag is guessed here.
- The current application customer Nginx configuration serves its SPA at `/`
  and retains `/app/` compatibility. It uses `/app/` as the build base and
  rewrites that compatibility route to the root app. The MFA prompt's root
  URL matches that contract; the reported 404 indicates the deployed web
  image did not satisfy the current customer artifact contract.
- The installer now checks the HTTPS customer root locally, with the
  customer hostname and TLS SNI preserved, after central HTTPS proof and
  before profile/MFA onboarding. It requires the customer SPA root element
  and emits only a generic error if the route is unavailable. This prevents
  onboarding or activation completion against an old or incorrectly routed
  image while leaving the existing activation session, hostname reservation,
  certificate, and customer data untouched.
- Both fresh and resumed image selection remain bound to the authorization
  API's approved tag; resumed installs pull that version and Compose recreates
  services when the image changes. The route check is read-only and retries
  remain on the existing activation session.

### Focused verification

- Added installer regressions for fresh approved image selection, stale-image
  resume selection and recreation, HTTPS root login-route validation, and
  preventing profile/MFA onboarding until that route passes.
- Existing activation-resume tests cover forward-only journal stages and
  reuse of the existing central activation session. Existing HTTPS retry
  tests verify existing certificates are retained.
- Direct focused regression invocation: **7 passed**, including fresh/resumed
  approved-tag deployment, root route success/failure, read-only preservation
  of activation session/certificate, and certificate reuse. Installer retry
  unittest: **4 passed**. Shell syntax and `git diff --check`: **passed**.
- `pytest` could not run because it is not installed. Installation in an
  isolated `/tmp` virtual environment failed because package DNS was
  unavailable; the focused pytest-style test functions were invoked directly.
- No AWS, central approval file, registry credentials, customer tokens, or
  live activation state were accessed. Local checks do not establish AWS
  acceptance; the operator must rerun safely after confirming the approved
  application tag/digests and then verify `/` before completing MFA.

### AWS-first customer Release Candidate qualification (2026-09-23)

The owner clarified that the authoritative process is:

`DEVELOPMENT → AUTOMATED QUALIFICATION → IMMUTABLE RELEASE CANDIDATE → CLEAN
AWS CUSTOMER INSTALLATION → OWNER REVIEW / ACCEPTANCE ON AWS → PROMOTE THE
EXACT APPROVED ARTIFACTS TO LIVE`.

Production remains on its existing approved release until explicit owner
acceptance of the clean AWS installation. On acceptance failure, diagnose and
fix the defect, create a new immutable `rc.N`, and repeat AWS acceptance. Do
not rebuild the accepted application after approval.

The owner-confirmed production approval is still **v0.1.1**. Application
release policy is now documented in the app's `RELEASE.md`: before 1.0, a
customer-facing capability/contract increment advances MINOR; fixes without
capability advance PATCH. The post-v0.1.1 history adds MFA, customer
activation/DNS, and account onboarding, so the next final version is **v0.2.0**
and the proposed first candidate is **v0.2.0-rc.1**.

#### Qualified application source and root causes

Application source SHA
`c8efccf843f4eec7d1d6f0fd035b023ff9ea3c69` is on
`codex/customer-release-qualification`; PR
[layMatchedBetting #263](https://github.com/ibettison/layMatchedBetting/pull/263)
is open and was reported mergeable with no review decision. It contains:

- The Workspace lint defect fix and picker regression test.
- Explicit terminal DNS outbox state (`failed`) and a non-null terminal
  timestamp; retryable errors stay `pending` with backoff. Tests prove no
  retry hint or reprocessing remains after terminal failure.
- Owner leads API handlers converted to `async def`. Async owner authorization
  and sync handlers had shared one SQLAlchemy session across the event loop and
  AnyIO worker thread; that thread-boundary use caused ASGI to stall after the
  response object was constructed. The bounded regression now passes.
- Reset table classifications preserve newly introduced operational data;
  startup worker tests isolate background pollers; a funnel test now awaits its
  async summary.

#### Qualification evidence

- Frontend lint: **passed, 0 errors and 4 existing warnings**.
- Frontend suites: **139 passed**; customer artifact suite: **2 passed**.
- Standard frontend build and customer frontend build: **passed**.
- Complete application backend suite: **passed at 100%**, including owner
  leads and DNS; existing skips and the Alembic deprecation warning remain.
- Auth API Go `go test ./...`: **passed**.
- Installer unittest suite: **50 passed**.
- Candidate/promotion workflow contract tests: **10 passed**; `bash -n`, shell
  parsing, and `git diff --check`: **passed**.

#### Candidate and promotion workflow review

Installer/auth/release changes are in open PR
[laymatched-install #41](https://github.com/ibettison/laymatched-install/pull/41)
on branch `codex/aws-accepted-release-flow`. It replaces the combined release
workflow with separate candidate creation and post-acceptance promotion.
Candidate creation checks out the exact application SHA, runs the full
automated qualification, builds API and web once, publishes owner-only
staging images, pulls them back to verify source labels, and creates a
manifest with candidate/final version, source SHA and both image digests.
The customer installer consumes that manifest only on a clean installation,
validates its full identity tuple, and pulls each candidate by digest.

Promotion requires the AWS acceptance JSON record to bind candidate version,
source SHA and both image digests and mark clean installation, artifact
identity, DNS, HTTPS, activation, login, MFA, current UI/functionality, public
routes, normal startup and owner acceptance true. It uses a protected
`production` GitHub Environment (which must require owner review), copies the
exact accepted manifests without rebuilding, verifies resulting digests and
Installer Token pulls, then atomically replaces `approved_release.json` and
`approved_version.txt` (version written last), and verifies the Auth API read
back. The exact same digests flow from candidate manifest through AWS
acceptance and live approval.

Rebasing onto current main exposed an Auth API regression: the release identity
response change had dropped the existing fail-closed check for an empty
activation-service URL. The guard is restored before approved-version
authorization, and the existing missing-URL regression is included in the
passing full Go suite.

The installer reader has executable tests for candidate/final version
consistency, source SHA, registry and image-reference/digest matching. The
workflow has serialization by candidate/release version and refuses existing
tags; production promotion also preserves OCI manifests/digests with Skopeo.

#### Current boundary

- The app source is fully qualified locally at the exact SHA above; no images
  have been built or published. No actual immutable candidate manifest exists
  yet, so an owner cannot review the running candidate on AWS yet.
- PR #41 must be merged before its candidate workflow can be dispatched from
  the default branch; PR #263 also needs normal review. Configure the GitHub
  `production` Environment with an owner reviewer before enabling promotion.
- Production approval remains **v0.1.1**. Neither approval metadata nor
  production images were changed.
- AWS was **not accessed or modified**. No candidate/promotion workflow was
  dispatched.

NEXT ACTION: review/merge PRs #263 and #41, confirm protected owner review on
the `production` Environment, then dispatch candidate creation for source
`c8efccf843f4eec7d1d6f0fd035b023ff9ea3c69` as `v0.2.0-rc.1`. Download and
review its immutable manifest, use the customer installer with that manifest
to install those exact digests on clean AWS, and complete the documented
acceptance checklist. Only after explicit owner acceptance should PR #41's
promotion workflow be dispatched with those same digests and the AWS evidence.

#### Repository identity review (2026-09-23)

Independent review confirmed an owner spelling defect in PR #41's candidate
workflow: the application checkout and both OCI source labels named the
application repository with an extra `s` in its owner name; the authoritative
identity is `ibettison/layMatchedBetting`. The existing workflow contract test
repeated the incorrect expected checkout repository. A historical PR #252 evidence
link in this PAD also used the misspelled owner. The canonical and deployment
workflow copies now share one `APPLICATION_REPOSITORY` value; checkout, both
image source labels, and candidate manifest metadata use that identity. The
test asserts the exact authoritative owner/repository, its use by checkout,
labels and manifest, and rejects the typo in the candidate/promotion
workflows. The historical evidence link now points to the correct repository.
Search across both local application and installer repositories found no
other operational occurrences. Release workflow contracts: **11 passed**;
installer suite: **61 passed**; shell syntax and `git diff --check`: **passed**.
These changes are in PR #41 and remain unmerged; production approval remains
**v0.1.1** and no candidate or AWS action was performed.

#### Direct reset and approved identity reauthorization review (2026-09-23)

PR #263's reset review finding reproduced in a fresh Python process that
imports `app.reset_personal_state` without application startup or test
`conftest.py`: the reset classifier unconditionally required three
central-only tables (`campaign_funnel_events`,
`interest_notification_outbox`, and `interest_request_idempotency`) even when
those models were absent from `Base.metadata`. They are now optional known
reference tables and are preserved/classified when present. A subprocess
regression creates an isolated SQLite schema from customer models and runs the
actual module `--dry-run` entry path without importing central models.

PR #41's installer rerun review finding also reproduced from the existing
configuration flow: reruns changed `APP_VERSION` and `REGISTRY_URL` in
`.env.candidate`, while copying old pinned API/web refs and source SHA from
`.env`; Compose could therefore start the old digests and later record the new
version. A shared release-identity helper now clears old refs before reading
authorization, accepts only a complete SHA/API digest/web digest tuple (or a
fully empty legacy identity), atomically writes version, registry, refs and
SHA together, pulls and checks both source labels before Compose starts, and
persists the tuple only after the new services pass health/activation gates.
The updater uses the same helper and checks. Existing RC staging digest refs
remain accepted; RC installs still require a clean customer installation.

The rerun regression starts from v0.1.1 with old API/web digests and SHA,
applies a v0.2.0 approval identity, checks the candidate environment and fake
Compose pull/up use the new exact digests, verifies label SHA, persists all
five identity fields, then simulates a subsequent updater resume and verifies
the same identity is used again. Partial metadata is also rejected and cannot
leave old refs populated.

Validation after these changes: complete application backend suite **491
passed, 4 skipped** (one existing Alembic deprecation warning); direct reset
regression included. Installer pytest suites **108 passed, 24 subtests**;
installer unittest suite **65 passed**; candidate/promotion workflow contracts
**11 passed**; Bash syntax and `git diff --check` passed. Production approval
remains **v0.1.1**; no AWS access, merge, release dispatch, or approval change
occurred.
