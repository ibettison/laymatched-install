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
  https://github.com/ibettison/layMatchedBetting/pull/244#issuecomment-5647545786
- A replacement post-evidence verdict was requested, but no newer automated
  review result was emitted at the time of this update.

Security and release status:

- The change remains read-only for activation state, exposes no credentials,
  TOTP, private keys, or provider integration, and makes no deployment/AWS
  changes.
- Central artifact activation traffic is explicitly absent; customer artifact
  activation remains limited to the safe onboarding projection.
- PR #244 is **NOT MERGE-READY** pending a clean replacement independent
  review verdict and Owner merge approval.
- No merge, deployment, or Gate 2A live acceptance has occurred.

NEXT TASK: obtain a clean independent review verdict for final HEAD
`891d2ed377204b70794aadc8cf012e449bdd8b89`, then request separate Owner
approval for merge. Do not merge or deploy as part of this update.

## 16. Dated programme update — Gate 2A PR #244 merge-review handoff (2026-09-13)

This update records the latest merge-review request; sections 14 and 15 remain
the historical implementation and validation record.

- PR: `#244`
- Repository: `ibettison/layMatchedBetting`
- Branch: `gate-2a-requalification`
- Reviewed HEAD: `891d2ed377204b70794aadc8cf012e449bdd8b89`
- PR state at review: **OPEN**, GitHub-reported `mergeable: true`, not merged.
- `main` remains at `928b131b7ae04246fc7dce7636516d39a358a59f`.
- No GitHub workflow or deployment records are available; no deployment has
  been performed or evidenced.

Latest review written to PR #244:

- Final exact-HEAD validation review posted at:
  https://github.com/ibettison/layMatchedBetting/pull/244#issuecomment-5651274087
- The review records central/customer artifact separation, non-overlapping
  profile test discovery, standard two-profile test execution, activation
  polling coverage, preflight safety, exact validation results, and no new
  substantive findings in the requested scope.
- A GitHub `--approve` review was attempted to enable merge, but GitHub rejected
  it because the authenticated account owns the pull request and cannot
  approve its own PR. No approval status was changed by that attempt.

Merge and release status:

- PR #244 remains **NOT MERGED / NOT DEPLOYED**.
- The technical validation review is complete, but merge still requires an
  approval from an independent collaborator/Owner account.
- No merge, deployment, or Gate 2A live acceptance has occurred.

NEXT TASK: obtain independent collaborator/Owner approval for PR #244, then
perform merge only under the separate approved merge procedure. Do not deploy
or perform live acceptance until separately authorized.

## 17. Dated programme completion record — Gate 2A PR #244 merged and central deployment (2026-09-13)

This completion record is appended to the PAD history. Sections 14–16 remain
the historical implementation, review, and approval trail.

### Merge and deployment

- PR: `#244`
- Repository: `ibettison/layMatchedBetting`
- Reviewed PR HEAD: `891d2ed377204b70794aadc8cf012e449bdd8b89`
- Merge commit SHA: `ba127526eb266b2137f316c4a402d700363e3fff`
- Resulting remote `main` SHA: `ba127526eb266b2137f316c4a402d700363e3fff`
- PR state: **MERGED** at `2026-09-13T05:06:09Z`.
- Deployment target: `/opt/laymatched-betting` using the normal
  `/opt/laymatched-betting/update.sh` process.
- Deployment result: **SUCCESS**; the stack advanced from
  `928b131b7ae04246fc7dce7636516d39a358a59f` to
  `ba127526eb266b2137f316c4a402d700363e3fff`.
- The deployment process retained its rollback snapshot and reported
  migration compatibility as `unknown`; no migration version change occurred.

### Post-deployment evidence

- Update-script health gates passed on attempt 2/24.
- Independent checks: `/health` 200; `/app/` 200; unauthenticated
  `/api/bankroll` 401; `/api/owner/auth/session` 200.
- `docker compose ps`: API, web, and database containers all running and
  healthy; web served on `127.0.0.1:8083`.
- Deployed central web assets contain **0** references to
  `/api/activation/onboarding`.
- The running central API route table reports
  `central_route_present=false` and no `/api/activation/*` routes.
- The merged customer web image was built with the supported Docker
  `customer` target; its asset contains the expected
  `/api/activation/onboarding` reference. The customer artifact boundary test
  passed, including exclusion of central/Owner/Stripe/private-key material.
- The merged scope is the 15 previously allowlisted Gate 2A files only;
  `git diff --check` passed. No credential-like material was detected, and
  there was no change to credential, TOTP, private-key, provider, DNS, Stripe,
  ACME, AWS, environment, Compose, or deployment configuration scope.
- GitHub reports no available workflow/status checks for the merged PR
  (`statusCheckRollup: []`).

### Gate 2A status

- **IMPLEMENTED:** YES — customer-only activation panel and safe onboarding
  projection are present; central profile does not mount the panel.
- **TESTED:** YES — exact reviewed HEAD validation passed before merge, and
  post-merge central/customer artifact and production smoke checks passed.
- **DEPLOYED:** YES — the approved merge is running in the central production
  stack at the resulting `main` SHA.
- **ACCEPTED-PROVEN LIVE:** **NOT YET PROVEN** — the customer artifact has
  been built and boundary-checked, but no separate customer production
  installation/live acceptance has been evidenced. The full backend suite is
  also still inconclusive from the previously recorded run.

NEXT TASK: perform the separately approved controlled customer-artifact
deployment and live Gate 2A acceptance, proving the onboarding request and
activation flow in the intended customer installation while preserving the
central no-request invariant.

## 18. Dated programme update — A-07 fast account onboarding and bookmaker management (2026-09-13)

This A-07 record is appended to the PAD history. Gate 2A customer-VPS/live
acceptance remains deferred and PR #244 was not reopened or changed.

### Workstream and review target

- Workstream: **A-07 — Fast Account Onboarding & Bookmaker Management**.
- Repository: `ibettison/layMatchedBetting`.
- Starting branch/SHA: `main` at
  `ba127526eb266b2137f316c4a402d700363e3fff`.
- New branch: `a-07-fast-account-onboarding`.
- Commit/HEAD: `c3c8bcec6f35a1137d4462f890f626a088093234`
  (`feat: speed up bookmaker account setup`).
- New PR: `#245` —
  https://github.com/ibettison/layMatchedBetting/pull/245
- No merge or deployment has occurred.

### Audit findings

Before A-07, My Money supported one-at-a-time account creation, bookmaker or
exchange classification, optional starting balance, HTTPS homepage validation,
account editing, manual money movements, balance timestamps, ledger history,
and the existing normal offer/bet workflow. The existing reviewed canonical
operator registry and bookmaker-directory metadata supplied provider names and
official homepages, but the customer profile had no searchable setup catalogue,
bulk account operation, optional per-provider balance grid, or idempotent
multi-selection handling. Existing individually-created accounts had to remain
unchanged.

### Implemented scope

- Added a customer-facing `/api/account-catalogue` projection that reuses the
  reviewed canonical provider identities and adds a small reviewed exchange set.
- Added idempotent `POST /api/operators/bulk`, capped at 50 accounts, with
  strict payload validation, optional non-negative opening balances, duplicate
  selection de-duplication, and safe already-existing-account skips.
- Added the responsive My Money setup panel: search, bookmaker/exchange badges,
  select-all-visible, multi-select, optional balance inputs, and one submit for
  the selected accounts.
- Preserved the existing single-account form as the visible fresh-install and
  manual “Add another bookmaker or exchange” escape hatch; unknown providers
  remain immediately usable through the existing `/api/operators` flow.
- Preserved account balance timestamps and the existing ledger so future A-09a
  freshness work can extend the data without an A-07 schema change.

### Files changed

Only these eight A-07 files were committed:

- `backend/app/api/mvp.py`
- `backend/tests/test_mvp_flow.py`
- `frontend/src/AccountSetupPanel.tsx`
- `frontend/src/AccountSetupPanel.test.tsx`
- `frontend/src/Workspace.tsx`
- `frontend/src/Workspace.test.tsx`
- `frontend/src/api.ts`
- `frontend/src/styles.css`

### Validation and acceptance evidence

- Focused A-07 frontend tests: **2 passed**; the representative flow selects
  multiple bookmaker/exchange providers, enters one optional balance, and sends
  one bulk request. The manual unknown-provider escape hatch is also covered.
- Existing Workspace regression tests: **25 passed**.
- Full frontend validation: **127 central-profile tests passed** and **1
  customer-profile test passed**.
- Backend focused validation covering A-07, customer-artifact boundary, and
  activation regression tests: **passed**; `test_mvp_flow.py` passed.
- Bulk API evidence covers approximately 20-account-scale selection semantics
  through a single capped batch, optional zero balances, existing-account
  skips, repeated submission with zero new creations, and rejection of negative
  opening balances without partial creation.
- Central and customer production builds: **passed**.
- Lint: **0 errors, 4 pre-existing warnings**.
- Shell syntax, ShellCheck, Python compileall, and `git diff --check`: **passed**.
- Full backend suite reached 65% and then stalled without failure output; it was
  stopped and recorded as **inconclusive**. Focused backend coverage passed.
- No screenshots were captured; the UI acceptance evidence is the focused
  Testing Library interaction trace plus the full central/customer build.

### Security and scope review

- No bookmaker passwords or login credentials are accepted or stored.
- No central exposure of customer private-VPS data was added.
- No migrations, Stripe, DNS/HTTPS, MFA, provider API, scraping, email
  ingestion, automatic discovery, reconciliation, betting automation, Owner
  Portal, or backup/restore scope was added.
- Changed-file review found no credential-like tokens, private keys, TOTP
  material, or unrelated integration/configuration changes.
- The original dirty landing-page worktree was not modified; the A-07 branch
  was developed in a clean isolated worktree from the specified main SHA.

### A-07 status split

- **IMPLEMENTED:** YES.
- **TESTED:** YES, subject to the full backend suite remaining inconclusive.
- **DEPLOYED:** NO — explicitly not authorized in this work review.
- **ACCEPTED-PROVEN LIVE:** NO — no live customer acceptance was performed.

NEXT TASK: obtain independent Owner review and approval for PR #245, then
follow a separate explicit merge/deployment approval gate. Do not merge or
deploy PR #245 as part of this PAD update.

## 19. Dated programme update — A-07 account personalisation and safe removal (2026-09-13)

This record is appended to the PAD history. It extends PR #245 only; PR #244
remains complete and was not reopened. No merge or deployment has occurred.

### Workstream and review target

- Workstream: **A-07 — Fast Account Onboarding & Bookmaker Management**.
- Repository: `ibettison/layMatchedBetting`.
- Branch: `a-07-fast-account-onboarding`.
- PR: `#245` —
  https://github.com/ibettison/layMatchedBetting/pull/245
- Exact reviewed HEAD: `63751c993131864f4085ec4fa59f3834e5cd4170`.
- Commit: `fix: make A-07 account removal and rename safe`.

### Additional requirements addressed

The existing implementation already retained canonical provider `slug`,
bookmaker/exchange classification, balances, ledger movements, bets, offers,
and account history on the `Operator` record. The remaining A-07 gaps were
customer display-name personalisation, a deliberate self-service correction
route for accidental/duplicate accounts, and safe handling of removal when
financial or operational history exists.

- Added editable account display name in My Money. The update path changes
  only `Operator.name`; canonical `slug`, provider relationships,
  bookmaker/exchange classification, balances, and history remain unchanged.
- Added a named-confirmation `DELETE /api/operators/{operator_id}` action.
  The confirmation identifies the display name and canonical provider slug.
- Dependency-aware removal hard-deletes only a row with no linked history,
  configuration, or account audit events. Otherwise it sets the existing safe
  inactive/disabled state, records an archive event, and returns the dependency
  summary with history-preserved status.
- Normal `/api/operators` and active My Money accounts now omit inactive rows;
  bankroll calculations retain their financial values and a clearly labelled
  removed/inactive section keeps historical account detail accessible.
- Existing inactive accounts can be re-enabled. Duplicate correction remains
  customer-controlled: identify, optionally rename, then safely remove/archive
  the unwanted account; no automatic merge was added.

### Files changed in this update

- `backend/app/api/mvp.py`
- `backend/tests/test_mvp_flow.py`
- `frontend/src/Workspace.tsx`
- `frontend/src/Workspace.test.tsx`
- `frontend/src/api.ts`
- `frontend/src/styles.css`

No database migration or unrelated application/configuration file was added.

### Validation and acceptance evidence

- Backend focused suite: `backend/tests/test_mvp_flow.py` — **34 passed**.
  Coverage includes rename preservation, exact-name removal confirmation,
  balance/history retention, inactive-list hiding, history-preserving archive,
  and duplicate correction without merging.
- Focused frontend suite: `AccountSetupPanel.test.tsx` and
  `Workspace.test.tsx` — **29 passed**.
- Full frontend suite: **129 central-profile tests passed** and **1
  customer-profile test passed**.
- Production and customer builds: **passed**.
- Lint: **0 errors, 4 pre-existing warnings**.
- Python compileall and `git diff --check`: **passed**.
- The previously recorded full backend run remains inconclusive after reaching
  65% and stalling without failure output; it was not rerun solely for this
  focused account-management change.
- No screenshots were captured; the UI evidence is the focused interaction
  tests and the successful central/customer production builds.

### Security and scope review

- Display-name editing does not alter canonical provider identity or provider
  relationships.
- Removal preserves ledger, bet, offer, correction, connection, and audit-event
  history whenever any such dependency exists.
- No bookmaker passwords, bookmaker login credentials, customer private-VPS
  data, TOTP material, private keys, provider integrations, Stripe, DNS/HTTPS,
  ACME, AWS, scraping, email ingestion, or deployment scope was introduced.
- Changed-file review found no credential-like material or unrelated files.

### A-07 status split

- **IMPLEMENTED:** YES — display-name editing, safe removal/archive,
  inactive-account visibility, and duplicate correction are implemented in PR
  #245.
- **TESTED:** YES — focused backend/frontend coverage, full frontend tests,
  builds, lint, compileall, and diff checks passed; full backend remains
  inconclusive as recorded above.
- **DEPLOYED:** NO — not authorized.
- **ACCEPTED-PROVEN LIVE:** NO — no customer live installation acceptance has
  been performed.

REMAINING LIMITATION: the ordinary create-account path records an opening
ledger entry and creation audit event, so normal customer-created accounts
take the history-preserving archive path; the dependency-free hard-delete
branch remains available for genuinely unreferenced records but was not
exercised through the customer UI.

NEXT TASK: obtain independent Owner review and approval of PR #245 including
this account-management extension. If approved, use a separate explicit
merge/deployment gate; do not merge or deploy as part of this PAD update.

## 20. Dated independent exact-SHA review — A-07 PR #245 (2026-09-13)

This record preserves the prior A-07 implementation history and records the
fresh base-to-HEAD review. No code was modified, and PR #245 was not merged or
deployed.

### Review identity

- Repository: `ibettison/layMatchedBetting`.
- PR: `#245` —
  https://github.com/ibettison/layMatchedBetting/pull/245
- Base reviewed: `origin/main` at
  `ba127526eb266b2137f316c4a402d700363e3fff`.
- Exact reviewed HEAD: `63751c993131864f4085ec4fa59f3834e5cd4170`.
- Review result: **RED — do not merge**.
- PR review comment:
  https://github.com/ibettison/layMatchedBetting/pull/245#issuecomment-5652784350

### Unresolved acceptance blockers

The review found four P1 blockers:

1. `account_setup_catalogue` still exposes directory variants separately
   instead of collapsing `canonical_operator_slug`/registry variants to one
   canonical selectable provider.
2. The catalogue loop does not exclude `needs_review` directory identities or
   unreviewed homepage URLs, while the UI labels any non-null URL as “Official
   site”.
3. Bulk creation remains a check-then-insert operation without concurrent
   unique-conflict handling, so simultaneous duplicate requests can fail with
   an unhandled integrity error.
4. Bankroll active totals still sum inactive/archived operators even though
   the account list is split into active and inactive sections.

The account-management additions themselves passed review for rename identity
preservation, balance/history retention, deliberate named confirmation,
dependency-aware archive, inactive history access, and customer-controlled
duplicate correction. The dependency-free hard-delete branch exists but has
no focused regression exercising a truly unreferenced operator.

### Revalidated evidence

- Backend focused `test_mvp_flow.py`: **34 passed**.
- Full frontend: **129 central-profile tests passed** and **1
  customer-profile test passed**.
- Focused A-07 tests: **29 passed**.
- Central/customer builds: **passed**.
- Lint: **0 errors, 4 pre-existing warnings**.
- Python compileall and `git diff --check`: **passed**.
- Full backend remains separately recorded as inconclusive after the prior 65%
  stall without failure output.
- Isolated catalogue probe reproduced both a canonical variant and an
  unreviewed directory row in the selectable catalogue.

### Current A-07 status split

- **IMPLEMENTED:** YES, but the full A-07 acceptance bar is blocked by the
  four unresolved provider/concurrency/total-integrity findings above.
- **TESTED:** YES for the reported implementation and regression suites;
  required blocker cases are not yet covered or safe.
- **DEPLOYED:** NO.
- **ACCEPTED-PROVEN LIVE:** NO.

NEXT TASK: fix the four review blockers, add focused regressions for canonical
variant collapse, reviewed-catalogue filtering, concurrent bulk idempotency,
and inactive-total exclusion, then request another independent exact-HEAD
review. Do not merge or deploy PR #245 before that GREEN review and explicit
Owner approval.

## 21. Dated A-07 blocker remediation — PR #245 (2026-09-13)

This record appends the remediation evidence for the four RED exact-SHA review
blockers. PR #245 remains unmerged and undeployed.

### Remediation identity

- Repository: `ibettison/layMatchedBetting`.
- PR: `#245` —
  https://github.com/ibettison/layMatchedBetting/pull/245
- Branch: `a-07-fast-account-onboarding`.
- Exact implementation HEAD: `cb83d282f63e154f0a275bbf481d034add7f34f9`.
- Commit: `Fix A-07 provider setup safety`.
- Files changed: `backend/app/api/mvp.py` and
  `backend/tests/test_mvp_flow.py` only.

### Blockers fixed

1. Account setup now collapses reviewed directory variants through the
   canonical operator mapping, preserving bookmaker/exchange type separation.
2. Customer setup now admits only canonical seeds and directory identities with
   explicit `approved` or `current` review status. Unreviewed URLs are not
   exposed as customer “Official site” links; manual provider entry remains the
   escape hatch.
3. Bulk creation now uses database-native conflict-safe insertion for SQLite and
   PostgreSQL, with savepoint-based conflict recovery for other dialects. A
   losing request safely skips the existing operator, so opening ledger entries
   and creation events are emitted only by the winner.
4. Live bankroll cash, pending transfers, bookmaker/exchange cash, committed
   stakes, unsettled returns, and exchange liability now use active operators;
   inactive account records and their history remain available separately.

### Validation evidence

- Focused A-07/backend account-management tests: **10 passed**, including
  canonical/needs-review catalogue filtering, archive totals, and dependency-
  free hard deletion.
- Full `backend/tests/test_mvp_flow.py`: **36 passed**.
- Canonical registry tests: **6 passed**.
- True overlapping bulk duplicate regression: **passed**; exactly one
  operator, opening-balance ledger entry, and creation event were verified.
- Central frontend tests: **129 passed**.
- Customer-profile tests: **1 passed**.
- Central production build: **passed**.
- Customer production build: **passed**.
- Lint: **0 errors, 4 pre-existing warnings**.
- Python compileall: **passed**.
- `git diff --check`: **passed**.
- Credential/scope review of changed files: no credentials, secrets, private
  keys, provider integrations, DNS, Stripe, ACME, AWS, or customer-data-boundary
  expansion introduced.
- Full backend suite: **inconclusive**; it again emitted passing dots to about
  70% and then stalled until the explicit 120-second timeout, with no failure
  output.

### Current A-07 status split

- **IMPLEMENTED:** YES — the four RED acceptance blockers are remediated at
  the exact HEAD above.
- **TESTED:** YES — focused and required frontend/backend/build/static checks
  passed; full backend remains inconclusive as recorded.
- **DEPLOYED:** NO.
- **ACCEPTED-PROVEN LIVE:** NO.

Nothing in this record claims merge, deployment, customer-VPS acceptance, or
live proof. No unrelated files were changed in the implementation worktree.

NEXT TASK: obtain a fresh independent exact-SHA review of PR #245 at
`cb83d282f63e154f0a275bbf481d034add7f34f9`; do not merge or deploy until that
review is GREEN and the Owner gives explicit approval.

## 22. Dated canonical variant remediation — PR #245 (2026-09-13)

This record corrects the previous remediation status after the independent
review found that the parallel variant map did not cover every variant declared
by the reviewed canonical registry. PR #245 remains unmerged and undeployed.

### Remediation identity

- Repository: `ibettison/layMatchedBetting`.
- PR: `#245` —
  https://github.com/ibettison/layMatchedBetting/pull/245
- Branch: `a-07-fast-account-onboarding`.
- Previous reviewed HEAD: `cb83d282f63e154f0a275bbf481d034add7f34f9`.
- New exact implementation HEAD: `e09a297d06584d24a77f214efa3791d984f7e572`.
- Commit: `Fix canonical A-07 provider variants`.
- Implementation files changed in this increment: `backend/app/api/mvp.py`,
  `backend/app/domain/offers/canonical_registry.py`, and
  `backend/tests/test_mvp_flow.py` only.

### Previous gap and exact fix

The previous HEAD used `VARIANT_PARENTS` for account setup, but that parallel
map omitted declared registry variants including `paddy-power-acca`,
`paddy-power-daily-rewards`, and `william-hill-extra-places`. Approved/current
directory rows for those variants could therefore appear as separate setup
providers.

The canonical registry now derives and validates a complete
`CANONICAL_VARIANT_PARENTS` map directly from every `CANONICAL_OPERATORS` seed.
Account setup uses that map to collapse every declared variant to its one
canonical identity while preserving bookmaker/exchange separation. Bulk
requests also canonicalize declared variant slugs defensively, preventing a
stale or manually crafted variant payload from creating a second provider.

### Corrected validation evidence

- Focused A-07/backend tests: **12 passed**.
- Full `backend/tests/test_mvp_flow.py`: **39 passed**.
- Canonical registry tests: **6 passed**.
- All declared canonical registry variants regression: **passed**.
- Variant bulk-payload duplicate-prevention regression: **passed**.
- Central frontend tests: **129 passed**.
- Customer-profile tests: **1 passed**.
- Focused A-07 UI tests: **29 passed**.
- Central/customer builds: **passed**.
- Lint: **0 errors, 4 pre-existing warnings**.
- Python compileall: **passed**.
- `git diff --check`: **passed**.
- Full backend suite: **inconclusive**; it again stalled around 70% after
  passing output and timed out without failure output.
- Credential/scope review: no credentials, secrets, private keys, provider
  integrations, DNS, Stripe, ACME, AWS, or customer-data-boundary expansion.

### Corrected A-07 status split

- **IMPLEMENTED:** YES — the previously identified canonical variant gap is
  fixed at the new exact HEAD.
- **TESTED:** YES — all focused and requested validation passed; the full
  backend suite remains inconclusive as recorded.
- **DEPLOYED:** NO.
- **ACCEPTED-PROVEN LIVE:** NO.

The prior section 21 status claim is superseded by this correction; its history
is preserved. The PR is still awaiting independent review and Owner approval.

NEXT TASK: obtain a fresh independent exact-SHA review of PR #245 at
`e09a297d06584d24a77f214efa3791d984f7e572`; do not merge or deploy until that
review is GREEN and the Owner gives explicit approval.

## 23. Dated financial-state remediation — PR #245 (2026-09-13)

This record appends the final financial-state remediation for A-07. PR #245
remains unmerged and undeployed.

### Remediation identity

- Repository: `ibettison/layMatchedBetting`.
- PR: `#245` —
  https://github.com/ibettison/layMatchedBetting/pull/245
- Branch: `a-07-fast-account-onboarding`.
- Previous reviewed HEAD: `e09a297d06584d24a77f214efa3791d984f7e572`.
- New exact implementation HEAD: `059c31e82d65ef1997d84c336f674ab8904bcf47`.
- Commit: `Separate archived accounts from operational inactivity`.
- Files changed in this increment: `backend/app/api/mvp.py`,
  `backend/tests/test_mvp_flow.py`, `frontend/src/Workspace.tsx`, and
  `frontend/src/api.ts` only.

### Previous financial-state gap and exact fix

The previous implementation treated `active=false` as removal for financial
purposes, although ordinary operational statuses such as restricted, paused,
disabled, source-broken, and closed also set that flag. Legitimate account cash
and exposure could therefore disappear from current totals.

The removal path now uses the explicit `archived` account status. Financial
cash totals include every non-archived operator regardless of operational
status. Removal is refused while unresolved bets or pending transfers exist, so
live financial activity cannot be hidden by archiving. Legacy archived records
with already placed bets or pending transfers retain that exposure in current
totals until resolution, while archived cash remains excluded. The customer
account view displays the archived status without allowing it to be submitted
as an ordinary operational update.

### Validation evidence

- Focused A-07 financial/account tests: **18 passed**.
- Full `backend/tests/test_mvp_flow.py`: **45 passed**.
- Canonical registry tests: **6 passed**.
- Central frontend tests: **129 passed**.
- Customer-profile tests: **1 passed**.
- Focused A-07 UI tests: **29 passed**.
- Central/customer builds: **passed**.
- Lint: **0 errors, 4 pre-existing warnings**.
- Python compileall: **passed**.
- `git diff --check`: **passed**.
- Credential/scope review: no credentials, secrets, private keys, provider
  integrations, DNS, Stripe, ACME, AWS, or customer-data-boundary expansion.
- Full backend suite: not rerun for this focused financial-state increment;
  the immediately preceding exact-HEAD run at `e09a297d` remains
  **INCONCLUSIVE**, stalling around 70% after passing output and timing out
  without failure output.

### Current A-07 status split

- **IMPLEMENTED:** YES — operational inactivity is distinct from explicit
  customer removal/archive, and unresolved financial activity is protected.
- **TESTED:** YES — focused backend, frontend, customer, build, lint, compile,
  and diff checks passed; full backend status remains as recorded above.
- **DEPLOYED:** NO.
- **ACCEPTED-PROVEN LIVE:** NO.

NEXT TASK: obtain a fresh independent exact-SHA review of PR #245 at
`059c31e82d65ef1997d84c336f674ab8904bcf47`; do not merge or deploy until that
review is GREEN and the Owner gives explicit approval.
