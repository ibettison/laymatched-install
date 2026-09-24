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

## 24. Exact-HEAD validation record — PR #245 (2026-09-13)

This record appends execution evidence for the exact implementation HEAD. PR
#245 remains **UNMERGED** and **UNDEPLOYED**.

### Validation identity

- Repository: `ibettison/layMatchedBetting`.
- PR: `#245` —
  https://github.com/ibettison/layMatchedBetting/pull/245
- Branch: `a-07-fast-account-onboarding`.
- Exact validated HEAD: `059c31e82d65ef1997d84c336f674ab8904bcf47`.
- Worktree remained clean; no code changes were required during validation.

### Exact-HEAD execution evidence

- `pytest -q -rA backend/tests/test_mvp_flow.py -k 'a07 or bankroll_accounts_movements_and_funding_warnings'`: **18 passed**.
  This includes the overlapping bulk duplicate regression, archived cash
  exclusion, paused/restricted/disabled/source-broken/closed totals,
  unsettled-bet and pending-transfer removal protection, dependency-free
  hard-delete, rename/history preservation, and duplicate correction checks.
- `pytest -q -rA backend/tests/test_mvp_flow.py`: **45 passed**.
- `pytest -q -rA backend/tests/test_canonical_registry.py`: **6 passed**.
- `npx vitest run src/AccountSetupPanel.test.tsx src/Workspace.test.tsx`:
  **29 passed** in 2 files.
- `npm test`: central **129 passed** in 17 files; customer-profile **1
  passed** in 1 file.
- `npm run build`: **passed**.
- `npm run build:customer`: **passed**.
- `npm run lint`: **0 errors, 4 pre-existing warnings**.
- `python -m compileall -q backend/app backend/tests`: **passed**.
- `git diff --check`: **passed**.

The full backend command `pytest -vv` collected 456 tests and is
**INCONCLUSIVE**, not failed: it reached 71% and stalled after the last
reported pass at `tests/test_offer_discovery.py::test_automatic_bootstrap_on_fresh_install`.
It timed out with exit 124 after 120 seconds and produced no failure output.

### Current A-07 status split

- **IMPLEMENTED:** YES.
- **TESTED:** YES — all required focused exact-HEAD checks passed; the full
  backend suite is separately recorded as inconclusive.
- **DEPLOYED:** NO.
- **ACCEPTED-PROVEN LIVE:** NO.

NEXT TASK: obtain a fresh independent exact-SHA review of PR #245 at
`059c31e82d65ef1997d84c336f674ab8904bcf47`; do not merge or deploy until that
review is GREEN and the Owner gives explicit approval.

## 25. Final account-setup UX correction — PR #245 (2026-09-14)

This record appends the final P2 UX correction for A-07. PR #245 remains
**UNMERGED** and **UNDEPLOYED**.

### Implementation identity

- Repository: `ibettison/layMatchedBetting`.
- PR: `#245` —
  https://github.com/ibettison/layMatchedBetting/pull/245
- Branch: `a-07-fast-account-onboarding`.
- Previous HEAD: `059c31e82d65ef1997d84c336f674ab8904bcf47`.
- New exact implementation HEAD: `35ba8a0fbb53371d99991c203623ea930bb67f02`.
- Commit: `fix: recognise inactive accounts in setup`.

### Remaining P2 finding and exact fix

The setup panel previously received only active accounts, so paused,
restricted, and archived providers could appear selectable again even though
the API would safely skip their duplicate creation.

`BankrollPanel` now passes the union of active and inactive accounts to
`AccountSetupPanel`, while the existing active/inactive account presentation
is unchanged. The panel therefore identifies every existing provider slug as
already in My Money and disables it as a new selection. Bulk completion text is
now derived from the API's actual `created` and `skipped` results, including
mixed and all-skipped outcomes. No financial-state, archive/removal,
canonical-registry, idempotency, or provider-trust rules changed.

### Validation evidence

- Focused AccountSetupPanel and Workspace tests: **32 passed**.
- Full central frontend tests: **132 passed** in 17 files.
- Customer-profile test: **1 passed**.
- Focused backend A-07 tests: **18 passed**.
- Central production build: **passed**.
- Customer production build: **passed**.
- Lint: **0 errors, 4 pre-existing warnings**.
- Python compileall: **passed**.
- `git diff --check`: **passed**.
- No backend files changed in this increment. The latest full backend result
  remains **INCONCLUSIVE** at the prior exact HEAD, where 456 tests reached 71%
  before timing out at `test_automatic_bootstrap_on_fresh_install` without
  failure output.
- Implementation worktree was clean after commit and push.
- PAD Issue #3: https://github.com/ibettison/laymatched-install/issues/3

### Current A-07 status split

- **IMPLEMENTED:** YES — the remaining account-setup recognition and result
  messaging defect is fixed at `35ba8a0fbb53371d99991c203623ea930bb67f02`.
- **TESTED:** YES — focused and full requested frontend checks, focused backend
  checks, builds, lint, compile, and diff validation passed.
- **DEPLOYED:** NO.
- **ACCEPTED-PROVEN LIVE:** NO.

NEXT TASK: obtain a final independent exact-SHA review of PR #245 at
`35ba8a0fbb53371d99991c203623ea930bb67f02`; do not merge or deploy until that
review is GREEN and the Owner gives explicit approval.

## 26. PR #245 merged — A-07 post-merge record (2026-09-14)

PR #245 has now been merged into `main`. Deployment has not been performed.

### Merge identity

- Repository: `ibettison/layMatchedBetting`.
- PR: `#245` —
  https://github.com/ibettison/layMatchedBetting/pull/245
- Approved implementation HEAD: `35ba8a0fbb53371d99991c203623ea930bb67f02`.
- Resulting merge commit and `main` SHA:
  `0c4ab02830c83ffc1674279e5992d272093b65a7`.
- Merge method: standard merge commit.

### A-07 status split

- **IMPLEMENTED:** YES — PR #245 is merged into `main`.
- **TESTED:** YES — the recorded exact-HEAD focused validation passed; the
  full backend suite remains **INCONCLUSIVE**, not failed, after stalling at
  71% on `test_automatic_bootstrap_on_fresh_install` without failure output.
- **DEPLOYED:** NO.
- **ACCEPTED-PROVEN LIVE:** NO.

### Remaining deployment/live-validation requirement

A valid customer environment must be deployed using the normal LayMatched
deployment process, followed by health/smoke checks and Gate 2A live
acceptance evidence. That evidence must confirm the central artifact does not
request `/api/activation/onboarding` while the intended customer artifact
retains the onboarding path. Until that customer-environment evidence exists,
A-07 is not accepted-proven live.

NEXT TASK: obtain explicit Owner approval for deployment, then deploy the
merged `main` SHA `0c4ab02830c83ffc1674279e5992d272093b65a7` to the valid
customer environment and append the health, smoke, artifact-boundary, and
Gate 2A live-acceptance evidence. Do not claim deployment or live acceptance
before those checks are completed.

## 27. PR #245 deployed — A-07 post-deployment record (2026-09-14)

Deployment was explicitly approved and completed using the standard
LayMatched `update.sh` process. This record does not claim live customer
acceptance.

### Deployment identity and evidence

- Repository: `ibettison/layMatchedBetting`.
- PR: `#245` — MERGED.
- Approved implementation HEAD: `35ba8a0fbb53371d99991c203623ea930bb67f02`.
- Merged `main` / deployed SHA:
  `0c4ab02830c83ffc1674279e5992d272093b65a7`.
- Deployment command: `sudo /opt/laymatched-betting/update.sh`.
- Previous deployed SHA: `ba127526eb266b2137f316c4a402d700363e3fff`.
- Candidate API and web images built from the merged `main` revision.
- PostgreSQL pre-update backup created at
  `/opt/laymatched-betting/.deployment-backups/20260914T065551Z-0c4ab02/postgres.dump`.
- Deployed checkout SHA verified as
  `0c4ab02830c83ffc1674279e5992d272093b65a7`.
- API, web, and database containers reported healthy.
- Standard health gates passed: API **200**, application **200**, protected
  API **401**, owner-session **200**.
- Central site root: **200**.
- Private application shell at `/app/`: **200**.
- Deployed bundle contains the A-07 setup, existing-account, truthful-result,
  and manual-provider-fallback UI strings.

### A-07 status split

- **IMPLEMENTED:** YES — PR #245 is merged into `main`.
- **TESTED:** YES — exact-HEAD focused validation is recorded in section 25;
  the full backend suite remains **INCONCLUSIVE**, not failed, after reaching
  71% and timing out at `test_automatic_bootstrap_on_fresh_install` without
  failure output.
- **DEPLOYED:** YES — merged `main` SHA is running through the standard
  deployment stack and passed all deployment health gates.
- **ACCEPTED-PROVEN LIVE:** NO.

### Deferred live acceptance evidence

This host exposes the central deployment and private application shell but has
no separately deployed customer-profile artifact/runtime or authenticated
customer session for the requested live journey. Therefore My Money account
creation, existing active/paused/restricted/archived account recognition,
optional balances, created/skipped messaging, manual fallback, rename, and
safe removal/archive behavior remain **unproven live** here. The existing
pre-merge UI/backend tests remain the available evidence for those behaviors.

NEXT TASK: use a valid customer environment to perform the authenticated A-07
live journey and artifact-boundary checks, record the customer health/smoke
evidence and any deferred Gate 2A acceptance results, and only then consider
`ACCEPTED-PROVEN LIVE`. Do not claim that status from this central deployment
alone.

## 28. A-07 Proud-to-Release My Money UX polish — PR #246 (2026-09-14)

This record appends the owner-confirmed post-deployment acceptance state and
the next, deliberately separate UX-polish workstream. A-07 functional live
acceptance succeeded after PR #245 was merged and deployed. The earlier
deferred-live note in section 27 is preserved as history; this record reflects
the later acceptance evidence supplied for the completed A-07 workstream.

### Proud-to-Release findings

The visual review identified three focused My Money issues:

1. Long bookmaker/exchange account lists needed clearer organisation.
2. The catalogue presentation of Betfair was ambiguous between bookmaker and
   exchange.
3. The tablet account-detail form needed stronger spacing and grid-cell
   containment.

### PR and implementation record

- Repository: `ibettison/layMatchedBetting`.
- New branch: `a-07-my-money-polish`.
- New PR: [#246](https://github.com/ibettison/layMatchedBetting/pull/246).
- Exact implementation HEAD: `c36e435516d418c38857b1693c465c60272eb6d8`.
- PR #245 remains merged and deployed; this UX-polish PR is **UNMERGED** and
  **NOT DEPLOYED**.
- The change is limited to My Money grouping/search/collapse presentation,
  explicit Betfair Sportsbook/Betfair Exchange presentation, responsive account
  form spacing, and focused regressions. Financial calculations, bankroll
  semantics, archive/removal rules, and A-07 bulk-create behavior are not
  changed.

### Validation evidence

- Focused frontend Workspace/AccountSetupPanel tests: **34 passed**.
- Full central frontend tests: **134 passed** across 17 files.
- Customer-profile test: **1 passed**.
- Backend `test_mvp_flow.py`: **45 passed**.
- Backend canonical registry tests: **6 passed**.
- Python `compileall`: passed.
- Central production build: passed.
- Customer production build: passed.
- Lint: **0 errors**, 4 pre-existing warnings.
- `git diff --check`: passed.
- Local fixture visual evidence captured for desktop/tablet expanded groups,
  tablet form layout, narrow/mobile collapsed groups, and Betfair Exchange
  presentation.

### A-07 status split

- **IMPLEMENTED:** YES — PR #245 is merged into `main`.
- **TESTED:** YES — functional and regression evidence is recorded above; the
  full backend suite remains **INCONCLUSIVE**, not failed, per the prior PAD
  record.
- **DEPLOYED:** YES — PR #245 merged `main` is deployed.
- **ACCEPTED-PROVEN LIVE:** YES for the completed A-07 functional journey,
  based on the owner-confirmed successful live acceptance.
- **PROUD-TO-RELEASE UX:** IN PROGRESS — PR #246 is the unmerged,
  undeployed polish work.

Anything not proven live for the new polish remains deferred until PR #246 is
independently reviewed, approved, merged, and deployed.

NEXT TASK: obtain an independent exact-SHA review of PR #246 at
`c36e435516d418c38857b1693c465c60272eb6d8`. Do not merge or deploy PR #246
before that review and explicit Owner approval.

## 29. PR #246 merged and deployed — A-07 Proud-to-Release UX (2026-09-14)

PR #246 was approved after an independent GREEN review, merged into `main`,
and deployed using the normal LayMatched deployment process. Proud-to-Release
UX remains pending the Owner’s device-level acceptance checks.

### Merge and deployment identity

- Repository: `ibettison/layMatchedBetting`.
- PR: `#246` — MERGED.
- Approved implementation HEAD: `c36e435516d418c38857b1693c465c60272eb6d8`.
- Merge commit / resulting `main` SHA:
  `62c3fcdf9c00b7b71845e18480b92e1e35c4e850`.
- Deployment command: `sudo /opt/laymatched-betting/update.sh`.
- Deployed checkout SHA verified as
  `62c3fcdf9c00b7b71845e18480b92e1e35c4e850`.
- Candidate API and web images built successfully from the resulting `main`.
- PostgreSQL rollback snapshot retained at
  `/opt/laymatched-betting/.deployment-backups/20260914T082829Z-62c3fcd/`.

### Health and smoke evidence

- API health: **200**.
- Central application shell: **200**.
- Protected API without session: **401**.
- Owner session route: **200**.
- Explicit post-deployment checks on port 8083: root **200**, `/app/` **200`,
  `/health` **200**, `/api/bankroll` **401**, and
  `/api/owner/auth/session` **200**.
- API, web, and database containers reported healthy.
- No application-code changes were made during deployment.

### Deployment warnings

- Docker Compose reported that Bake was configured but `buildx` was not
  installed; the candidate images still built successfully.
- Migration compatibility was reported as **unknown** because the Alembic
  revision remained `0032_public_interest_recovery` before and after the
  deployment; no migration was required.

### A-07 status split

- **IMPLEMENTED:** YES — PR #245 and the PR #246 UX polish are merged into
  `main`.
- **TESTED:** YES — pre-merge functional/regression/build evidence is recorded
  in sections 28 and the PR records.
- **DEPLOYED:** YES — resulting `main` SHA is deployed and passed health gates.
- **LIVE ACCEPTANCE:** PENDING OWNER DEVICE CHECK — the Owner will verify the
  My Money grouping, collapse/expand, search, Betfair presentation, and
  portrait/landscape form spacing on iPad.
- **PROUD-TO-RELEASE UX:** PENDING OWNER ACCEPTANCE.

Anything beyond the automated/local evidence and the deployment smoke checks
remains unproven until the Owner completes those device checks. No merge or
deployment action remains for PR #246.

NEXT TASK: Owner device-check the deployed My Money UX on iPad portrait and
landscape, then append the acceptance result. Do not mark Proud-to-Release UX
complete before that check.

## 30. A-07 account-detail responsive correction — follow-up HEAD (2026-09-14)

PR #246 remains the current My Money Proud-to-Release polish workstream. Owner
live acceptance confirmed that the new Bookmakers/Exchanges grouping is
materially improved, but found that account-detail fields could still merge
visually at iPad/tablet portrait widths.

### Correction record

- Repository: `ibettison/layMatchedBetting`.
- Workstream branch: `a-07-my-money-polish`.
- Existing PR #246: already merged at the prior approved HEAD; this follow-up
  commit is not a new merge or deployment.
- Exact correction HEAD: `3bc736e62ab29b15a94f80be189f087fbfaf487f`.
- Commit: `fix: prevent account form overlap on tablets`.
- Files changed: `frontend/src/styles.css` and
  `frontend/src/Workspace.test.tsx` only.
- No Floating Page Section Organiser work was included.

### Exact fix

- Retain two account-form columns above 820px, suitable for desktop and tablet
  landscape widths.
- Switch the account form to one column at or below 820px, before iPad portrait
  controls become cramped.
- Preserve the existing field order, form behavior, and financial/account
  semantics.
- Allow long labels to wrap without forcing neighboring grid cells wider.
- Add a structural regression confirming all account-detail controls remain in
  the responsive form grid.

### Validation evidence

- Focused Workspace/AccountSetupPanel tests: **35 passed**.
- Full central frontend tests: **135 passed** across 17 files.
- Customer-profile test: **1 passed**.
- Central production build: passed.
- Customer production build: passed.
- Lint: **0 errors**, 4 pre-existing warnings.
- `git diff --check`: passed.
- Visual evidence captured at desktop/tablet landscape, tablet portrait, and
  narrow/mobile widths; landscape retained two columns and portrait/mobile used
  one column without visible overlap.
- The follow-up branch commit was pushed, but no merge or deployment was
  performed.

### Current status

- **A-07 IMPLEMENTED:** YES.
- **A-07 TESTED:** YES.
- **A-07 DEPLOYED:** YES for the previously merged PR #245/#246 main release;
  this responsive correction is **NOT DEPLOYED**.
- **LIVE ACCEPTANCE:** PENDING OWNER DEVICE CHECK after redeployment of this
  correction.
- **PROUD-TO-RELEASE UX:** PENDING OWNER ACCEPTANCE.

Remaining unproven item: the corrected responsive form must be reviewed on the
Owner’s iPad in portrait and landscape after it is placed into a reviewed,
merged, and deployed release. The floating Page Section Organiser remains a
separate future UX item.

NEXT TASK: obtain fresh independent exact-SHA review and Owner approval for
`3bc736e62ab29b15a94f80be189f087fbfaf487f`, then place the correction into the
release workflow. Do not merge or deploy before that review and approval.

## 31. PR #247 merged and deployed — A-07 tablet form correction (2026-09-14)

The follow-up responsive account-detail correction was independently approved,
merged, and deployed. The Proud-to-Release UX gate remains pending the Owner’s
device checks.

### Merge and deployment identity

- Repository: `ibettison/layMatchedBetting`.
- PR: [#247](https://github.com/ibettison/layMatchedBetting/pull/247) — MERGED.
- Approved correction HEAD: `3bc736e62ab29b15a94f80be189f087fbfaf487f`.
- Merge commit / resulting `main` SHA:
  `440f7f1fde3282b5b0db6c3e6b93522c0d06a561`.
- Deployment command: `sudo /opt/laymatched-betting/update.sh`.
- Deployed checkout SHA verified as
  `440f7f1fde3282b5b0db6c3e6b93522c0d06a561`.
- PostgreSQL rollback snapshot retained at
  `/opt/laymatched-betting/.deployment-backups/20260914T191852Z-440f7f1/`.

### Health and smoke evidence

- Updater health gates passed on attempt 2.
- API health: **200**.
- Central application shell: **200**.
- Protected API without session: **401**.
- Owner session route: **200**.
- Explicit port-8083 checks: root **200**, `/app/` **200**, `/health` **200`,
  `/api/bankroll` **401`, and `/api/owner/auth/session` **200**.
- API, web, and database containers reported healthy.
- No application-code changes were made during deployment.

### Deployment warnings

- Docker Compose reported Bake configured without `buildx`; candidate images
  still built successfully.
- Migration compatibility was reported as **unknown** because the Alembic
  revision remained `0032_public_interest_recovery` before and after; no
  migration was required.

### Status

- **IMPLEMENTED:** YES.
- **TESTED:** YES — focused and full frontend validation passed before merge.
- **DEPLOYED:** YES — `main` SHA `440f7f1…` is deployed and healthy.
- **LIVE ACCEPTANCE:** PENDING OWNER DEVICE CHECK — iPad portrait and landscape
  checks remain required for grouping, collapse/expand, search, Betfair
  presentation, and account-form spacing.
- **PROUD-TO-RELEASE UX:** PENDING OWNER ACCEPTANCE.

NEXT TASK: Owner completes the deployed My Money acceptance checks on iPad
portrait and landscape, then append the result. Do not mark Proud-to-Release
UX complete before that check.

## 32. A-07 account-opened date field correction — follow-up (2026-09-14)

Owner iPad acceptance identified one remaining presentation defect in the
bounded My Money account-detail correction: the existing `opened_at` date input
was an unlabelled, visually unexplained control below Official website.

### Correction identity and scope

- Workstream branch: `a-07-my-money-polish`.
- Exact implementation HEAD:
  `dd548de549e7e1c861891c23dc71e3fb9cc874f5`.
- Only `frontend/src/Workspace.tsx` and `frontend/src/Workspace.test.tsx`
  changed for the implementation correction.
- The existing `opened_at` value, native `type="date"` input, state binding,
  PATCH contract, save behavior, and field order were preserved.
- The input is now a labelled account-form field named **Account opened**,
  using the existing grid sizing and spacing so it remains a normal single-line
  control on desktop, tablet, and mobile.
- No Floating Page Section Organiser work was included.

### Validation evidence

- Focused Workspace/AccountSetupPanel tests: **36 passed**.
- Full central frontend tests: **136 passed** across 17 files.
- Customer-profile test: **1 passed**.
- Central production build: passed.
- Customer production build: passed.
- Lint: **0 errors**, 4 pre-existing warnings.
- `git diff --check`: passed.
- Focused regression confirms the accessible **Account opened** label, native
  date type, loaded `opened_at` value, changed value, and PATCH payload.
- Fresh local-fixture visual evidence captured for tablet landscape, tablet
  portrait, and narrow/mobile layouts; the field is labelled, single-line, and
  does not overlap neighboring fields.
- No backend files were changed; no backend validation was required.

### Current status

- **A-07 IMPLEMENTED:** YES.
- **A-07 TESTED:** YES.
- **A-07 DEPLOYED:** YES for the previously merged/deployed release;
  this account-opened-date correction is **NOT DEPLOYED**.
- **LIVE ACCEPTANCE:** PENDING OWNER DEVICE CHECK after this correction is
  independently reviewed, merged, and redeployed.
- **PROUD-TO-RELEASE UX:** PENDING OWNER ACCEPTANCE.

Remaining unproven item: Owner must verify the corrected Account opened field
on iPad portrait and landscape after release, including empty, loaded, edited,
saved, and reopened values. The floating Page Section Organiser remains a
separate future UX item.

NEXT TASK: obtain a fresh independent exact-SHA review and Owner approval for
`dd548de549e7e1c861891c23dc71e3fb9cc874f5`, then place this bounded correction
into the release workflow. Do not merge or deploy before that review and
approval.

## 33. PR #248 merged and deployed — Account opened field correction (2026-09-14)

The bounded My Money account-detail date-field correction was added to PR #248,
merged, and deployed after the requested owner approval.

### Release identity

- PR: [#248](https://github.com/ibettison/layMatchedBetting/pull/248) — MERGED.
- Approved implementation HEAD:
  `dd548de549e7e1c861891c23dc71e3fb9cc874f5`.
- Merge commit / resulting `main` SHA:
  `0be32f844a8ae959dc79fb2024111a2da079e2e8`.
- Deployment command: `sudo /opt/laymatched-betting/update.sh`.
- Deployed checkout SHA verified as
  `0be32f844a8ae959dc79fb2024111a2da079e2e8`.

### Deployment evidence

- Candidate API and web images built successfully.
- API container: healthy.
- Web container: healthy.
- PostgreSQL container: healthy.
- API health: **200**.
- Central application shell `/`: **200**.
- Central application `/app/`: **200**.
- Protected bankroll API without session: **401**.
- Owner session route: **200**.
- Rollback snapshot retained at
  `/opt/laymatched-betting/.deployment-backups/20260914T200035Z-0be32f8/`.
- Migration compatibility remained **unknown** because the Alembic revision
  was unchanged; no migration was required.
- Docker Compose warned that Buildx is unavailable; images nevertheless built
  and deployment completed successfully.

### Status

- **A-07 IMPLEMENTED:** YES.
- **A-07 TESTED:** YES.
- **A-07 DEPLOYED:** YES — resulting `main` SHA is deployed and healthy.
- **LIVE ACCEPTANCE:** PENDING OWNER DEVICE CHECK, including confirmation of
  the Account opened field on iPad portrait and landscape with empty, loaded,
  edited, saved, and reopened values.
- **PROUD-TO-RELEASE UX:** PENDING OWNER ACCEPTANCE.

The Floating Page Section Organiser remains out of scope and unimplemented.

NEXT TASK: Owner performs the post-deployment iPad portrait/landscape acceptance
checks for the My Money grouping, Betfair presentation, responsive account
form, and labelled Account opened field. Do not mark Proud-to-Release UX
complete until those checks are recorded.

## 34. PR #249 merged and deployed — compact Account opened control (2026-09-14)

The final bounded My Money date-field UX polish was merged and deployed after
Owner approval.

### Release identity

- PR: [#249](https://github.com/ibettison/layMatchedBetting/pull/249) — MERGED.
- Implementation HEAD: `e751340118e8e4f9b3df3265ce751d3d1c133cb5`.
- Merge commit / resulting `main` SHA:
  `dfd7d47e928ebd7cbe5b6e7937a424de7ce91255`.
- Deployment command: `sudo /opt/laymatched-betting/update.sh`.
- Deployed checkout SHA verified as
  `dfd7d47e928ebd7cbe5b6e7937a424de7ce91255`.

### Deployment evidence

- Candidate API and web images built successfully.
- API, web, and PostgreSQL containers reported healthy.
- API health: **200**.
- Central application shell `/`: **200**.
- Central application `/app/`: **200**.
- Protected bankroll API without session: **401**.
- Owner session route: **200**.
- Rollback snapshot retained at
  `/opt/laymatched-betting/.deployment-backups/20260914T201816Z-dfd7d47/`.
- Migration compatibility remained **unknown** because the Alembic revision
  was unchanged; no migration was required.
- Docker Compose warned that Buildx is unavailable; candidate images built and
  deployment completed successfully.

### Status

- **A-07 IMPLEMENTED:** YES.
- **A-07 TESTED:** YES.
- **A-07 DEPLOYED:** YES — resulting `main` SHA is deployed and healthy.
- **LIVE ACCEPTANCE:** PENDING OWNER DEVICE CHECK for the compact Account
  opened control and the previously listed My Money acceptance items.
- **PROUD-TO-RELEASE UX:** PENDING OWNER ACCEPTANCE.

The Floating Page Section Organiser remains out of scope and unimplemented.

NEXT TASK: Owner completes post-deployment iPad portrait/landscape acceptance
for grouping, search, Betfair presentation, responsive account form, and the
compact Account opened date picker; then record the result before marking
Proud-to-Release UX complete.

## 35. PR #250 merged and deployed — native date-picker activation fix (2026-09-14)

The follow-up fix for the compact Account opened calendar control was merged
and deployed after Owner approval. The native input is now a transparent,
real-size touch target over the calendar icon, while the explicit button keeps
the `showPicker()` path and fallback activation.

### Release identity

- PR: [#250](https://github.com/ibettison/layMatchedBetting/pull/250) — MERGED.
- Implementation HEAD: `95be87135adffcaf4c979042740e2b1d31619fcf`.
- Merge commit / resulting `main` SHA:
  `01f2113af5bdc6f0fecdb5c37f009084ecb28a82`.
- Deployment command: `sudo /opt/laymatched-betting/update.sh`.
- Deployed checkout SHA verified as
  `01f2113af5bdc6f0fecdb5c37f009084ecb28a82`.

### Deployment evidence

- Candidate API and web images built successfully.
- API, web, and PostgreSQL containers reported healthy.
- API health: **200**.
- Central application shell `/`: **200**.
- Central application `/app/`: **200**.
- Protected bankroll API without session: **401**.
- Owner session route: **200**.
- Rollback snapshot retained at
  `/opt/laymatched-betting/.deployment-backups/20260914T202701Z-01f2113/`.
- Migration compatibility remained **unknown** because the Alembic revision
  was unchanged; no migration was required.
- Docker Compose warned that Buildx is unavailable; candidate images built and
  deployment completed successfully.

### Status

- **A-07 IMPLEMENTED:** YES.
- **A-07 TESTED:** YES.
- **A-07 DEPLOYED:** YES — resulting `main` SHA is deployed and healthy.
- **LIVE ACCEPTANCE:** PENDING OWNER DEVICE CHECK that the calendar control
  opens on iPad, including portrait and landscape interaction.
- **PROUD-TO-RELEASE UX:** PENDING OWNER ACCEPTANCE.

The Floating Page Section Organiser remains out of scope and unimplemented.

NEXT TASK: Owner performs the post-deployment iPad acceptance of the compact
Account opened calendar button/date picker and records whether native date
selection opens and saves correctly. Do not mark Proud-to-Release UX complete
until that check is recorded.

## 36. A-08 customer MFA implementation — PR #251 (2026-09-14)

A-08 customer TOTP MFA is implemented on a new focused branch and submitted
for independent security review. It is not merged, deployed, or live accepted.

### Release identity

- Repository: `ibettison/layMatchedBetting`.
- Branch: `a-08-customer-mfa`.
- PR: [#251](https://github.com/ibettison/layMatchedBetting/pull/251) — OPEN,
  awaiting independent exact-SHA review.
- Implementation HEAD: `6509aaf9d840c5c95800f8617ab7f2c8fcf53afd`.
- Base main SHA at branch creation:
  `01f2113af5bdc6f0fecdb5c37f009084ecb28a82`.

### What was added

- Password-first login now creates a short-lived database challenge when MFA is
  enabled; it does not issue a fully authenticated customer session until a
  valid TOTP or recovery code is verified.
- Per-customer TOTP secrets use RFC-compatible SHA-1 TOTP with a ±1 30-second
  step window, replay-counter protection, and constant-time comparisons.
- Secrets are encrypted with AES-GCM using a key derived from the existing
  application session secret. Setup responses are explicit enrollment-only
  material and are marked `Cache-Control: no-store`.
- Enrollment is disabled until code verification succeeds. Ten recovery codes
  are generated securely, shown once, and stored only as salted PBKDF2 hashes.
- MFA authentication epochs invalidate prior sessions after enrollment/reset;
  protected API middleware checks the epoch and second-factor claim server-side.
- Reset/re-enrol requires the current authenticated MFA session, password
  re-authentication, and a current TOTP or recovery code. Reset clears the
  encrypted secret and signs the customer out.
- Customer-only responsive settings UI provides local QR setup, manual fallback,
  clear verification errors, recovery-code presentation, and reset guidance.

### Persistence / migration

- Added Alembic revision `0033_customer_mfa` with durable MFA state and
  password-first challenge tables. Existing users remain non-MFA by default.
- Migration head and upgrade from a database stamped at
  `0032_public_interest_recovery` passed. A full empty-database replay remains
  blocked by the pre-existing SQLite-incompatible foreign-key operation in
  migration `0014`; this is not introduced by A-08.

### Validation evidence

- Customer MFA/auth/customer-artifact backend tests: **31 passed**.
- MVP flow: **45 passed**.
- Canonical registry and owner operations: **28 passed**.
- Central frontend: **18 files / 139 tests passed**.
- Customer-profile frontend: **1 passed**.
- Central and customer production builds: **passed**.
- Python compileall, focused changed-file lint, and `git diff --check`:
  **passed**.
- Full frontend lint retains one pre-existing error in the A-07 account-date
  picker expression and four pre-existing warnings.
- Full backend suite: **INCONCLUSIVE**, not failed; it reached 62% and then
  produced no failure output through the ten-minute timeout in the previously
  observed slow region.
- Headless responsive evidence captured and inspected for desktop, iPad
  portrait, mobile enrollment/QR/manual key, mobile login challenge, invalid
  code, and iPad reset/re-authentication screens.

### A-08 status

- **IMPLEMENTED:** YES — exact implementation HEAD recorded above.
- **TESTED:** YES — focused and relevant broader validation recorded above;
  full backend suite remains inconclusive.
- **DEPLOYED:** NO.
- **ACCEPTED-PROVEN LIVE:** NO.

Outstanding acceptance items are independent exact-SHA security review, owner
approval, merge, deployment, and trusted-HTTPS customer-device verification.
No customer secret, MFA bypass, recovery token, credential, or deployment
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

#### Final v0.2.0 qualification closeout (2026-09-23)

The owner-leads handlers retain the path-scoped `asyncio.to_thread` execution
of owner authorization, SQLAlchemy work, and worker-session cleanup. The
standalone probe against the application ASGI stack observed the delayed
`marketing_leads` query start, `/health` return HTTP 200 while that query was
held, explicit delay release, query completion, worker-session close, and the
owner-leads response return HTTP 200 with the expected empty page. The
unauthenticated real application path returned HTTP 401; its worker SQLAlchemy
session was created and closed on the same worker thread, no SQLAlchemy object
crossed the thread boundary, and that path did not enter the delayed lead
query. The pytest owner-leads unauthenticated test reached **PASSED** and
fixture/client/database/engine cleanup completed, but pytest/AnyIO hung in
`asyncio.Runner.close` teardown. This is deferred as a **POST-RELEASE
TEST-INFRASTRUCTURE ISSUE**; it is not treated as a demonstrated production
defect. The standalone authenticated delayed-query probe is the release
responsiveness evidence.

The original PAD Welcome/MFA onboarding experience is retained at the customer
VPS hostname root: `https://<customer>.matched.laysports.co.uk/`. Customer `/`
serves the LayMatched Welcome/Login/MFA onboarding and application flow;
customer `/app`, `/app/`, and `/app/...` return 404. The customer artifact does
not include or serve the legacy/public marketing website. The separate owner
website build keeps its existing `/app/` routing and public-site assets; owner
and customer deployment profiles remain distinct.

Qualification results for this pass: standard frontend **139 passed**;
customer frontend artifact **3 passed**; customer artifact/root-routing
contract **7 passed**; frontend lint **0 errors, 4 existing warnings**;
customer build and owner build **passed**. The direct reset-module regression
passed (**3 tests**). Installer pytest suites **83 passed**; installer
unittest suite **65 passed**; release workflow contracts **11 passed**; the
approved-release identity rerun regression **1 passed**; relevant Bash syntax
and installer `git diff --check` **passed**. The complete backend suite did
qualify earlier with **491 passed, 4 skipped**. A later attempted rerun,
deselecting only `backend/tests/test_owner_leads_api.py::test_owner_auth_is_required_for_every_lead_operation`, was incomplete:
pytest reported an unidentified failure at approximately 61%, then stalled
without producing the failure report and was stopped. This run is not claimed
as passing. Application `git diff --check` passed after cleanup.

The reset direct-module and approved-release identity/rerun review findings
remain fixed and their existing regressions pass. The two old GitHub review
threads remain open but are satisfied by these fixes and tests; they are not
new release scope. Production approval remains **v0.1.1**. No merge, release
workflow dispatch, candidate creation, AWS access, or production change was
performed.

## 46. Product Experience & Connected Architecture — agreed direction (2026-09-24)

This section records the Owner's agreed product direction so that the application,
central services, Founding 100 collaboration, recognition, monitoring, and Owner
Portal are designed as one LayMatched system. It is an architecture and product
experience decision, not authority to interrupt the current installation/MFA
release gate or to begin implementation without the normal review process.

### One product journey

LayMatched must feel like one coherent product from:

`Website → Installation → Welcome/Login/MFA → Customer App → Community → Owner Portal`.

The customer application is not a collection of calculators. It is a guided
matched-betting working environment whose Dashboard answers three questions:

1. What should I do now?
2. What offers have I got underway?
3. How am I doing?

The same product serves both PAD audiences: new customers who need guidance and
experienced matched bettors who need organisation. Complexity should reveal
itself progressively rather than through a separate expert mode.

### Customer application information architecture

The agreed primary customer navigation direction is a space-efficient top
navigation rather than a permanent left sidebar. The working information
architecture is:

- Dashboard
- Offer Finder
- My Offers
- My Money
- Calculators
- Community
- Profile

Bookmaker/exchange account and balance management should be integrated naturally
with the money/account experience rather than consuming unnecessary permanent
navigation space where this improves tablet usability.

The Dashboard is deliberately restrained. It surfaces only the highest-priority
actions, a concise view of active offers, and quiet progress information.
Detailed workflow belongs in My Offers; financial truth belongs in My Money;
offer discovery belongs in Offer Finder. A first-login Dashboard should avoid
empty tables and zero-value noise and instead guide the member through setting
up money/accounts, finding a first offer, and following it through.

### Unified visual identity

The legacy green-and-cream application treatment is to be retired. The agreed
application direction is light, welcoming and professional: subtle blues,
white cards, generous whitespace, navy text, and stronger electric blue for
primary actions and active states. Dark/navy brand treatment may be concentrated
in a shallow hero/banner and selected brand elements; the application as a whole
must not become a dark theme.

The design system must cover typography, backgrounds, cards, borders, buttons,
navigation, icons, spacing, status colours, forms, tables, calculators, empty
states, financial information, and responsive desktop/tablet/mobile behaviour.
Tablet fit is an explicit acceptance concern.

Use the actual LayMatched website visual language and recognition artwork rather
than invented substitutes. Do not introduce greyhound imagery into the
application identity.

### Privacy boundary — “Central collaboration, private betting”

This is an architectural invariant.

**Private customer VPS**

The following remain private to the customer's installation and must not become
Owner Portal or central collaboration data:

- bets and selections;
- bookmaker/exchange balances;
- liabilities and committed stakes;
- offer activity and matched-betting workflow detail;
- profits, returns, and personal matched-betting financial records;
- bookmaker-specific customer activity and credentials.

**Central LayMatched services**

Central services may hold the minimum shared/operational information required
for the LayMatched service, including:

- installation/activation identity and lifecycle;
- installation health/check-in state;
- application version and update state;
- onboarding and MFA completion state;
- actionable operational/error state needed to support the installation;
- Founding Member identity;
- Community discussions, replies, suggestions, support/interest and submitted
  discussion attachments;
- Owner responses and discussion/work status;
- recognition/achievement records.

Central services enhance and support the private customer application. Loss of
central collaboration/recognition availability should not unnecessarily make
ordinary local matched-betting functionality unusable.

### Installation and ongoing monitoring

Installation monitoring already forms part of the activation lifecycle and
must remain connected to Owner operations. The operational model should continue
beyond installation with privacy-preserving customer-installation check-ins.

The Owner Portal should be able to identify, without exposing private betting
data:

- installation/activation state;
- onboarding/MFA completion;
- last successful check-in / apparent installation health;
- installed application version and whether an update is available;
- relevant operational errors requiring Owner attention.

The customer application should expose a quiet service-status indication where
appropriate (for example connected/current version/last check) rather than
frightening users with intrusive monitoring language.

### LayMatched Community and collaboration

Community is a product pillar, not a generic forum or social-media clone. The
Founding 100 establish its initial culture, but Community is a **LayMatched-wide
capability** for eligible members. Joining after the Founding 100 must never
prevent a member from contributing useful information, insight, ideas, support,
or product feedback, or from being recognised for a meaningful contribution.

Founding status and contribution recognition are deliberately separate. Pioneer
records the historical fact of being one of the original Founding 100; it is not
a prerequisite for participating in Community or earning contribution-based
recognition.

A member must be able to raise an idea, report something that is not working
well, ask a question, share a useful tip, or request discussion with Ian.
Other eligible LayMatched members may contribute where appropriate. Community
content is stored centrally and rendered natively inside the customer
application so that members on separate private VPS installations participate
in the same shared collaboration space.

The intended improvement loop is:

`Member raises something → Community discusses → Ian responds → Under consideration → Planned → Being worked on → Added to LayMatched`.

Members should be able to see the status of things they raise. The experience
must use natural product language and must not feel like an IT ticketing system.

The Dashboard should contain only a small Community indicator when useful; the
full discussion experience belongs in Community.

### Recognition and Profile

Recognition is centrally stored so that it follows the LayMatched member rather
than being trapped on one VPS. The Dashboard carries only a restrained
recognition/profile indicator; Profile is the proper home for the member's
recognition collection and account/security/preferences.

The established recognition identities are:

- Pioneer — permanent historical identity for the original Founding 100; it
  cannot be earned by later members;
- Improver — meaningful contribution that improves the product; available to
  eligible LayMatched members whether founding or later;
- Insighter — valuable experience, thinking, or use-case contribution; available
  to eligible LayMatched members whether founding or later;
- Champion — repeated meaningful contribution/help; available to eligible
  LayMatched members whether founding or later.

Recognition is not driven by post counts or engagement gaming. Awards are made
for meaningful contribution.

Earned recognition must also be visible **within Community collaboration**, not
confined to Profile. A member's earned shields form part of their Community
identity and should be displayed in a restrained way alongside their name on
discussions and replies. This lets other LayMatched members see that useful
contributions are noticed and valued.

When a contribution directly results in recognition, LayMatched should be able
to acknowledge that within Community and, where appropriate, associate the
award with the contribution that earned it. Profile remains the member's full
recognition history, including useful context such as why an award was made and
a link back to the relevant Community contribution when appropriate.

The intended recognition incentive loop is:

`Contribute useful information or insight → Community discusses → LayMatched
benefits → meaningful contribution is acknowledged → earned recognition is
visible in Community → further useful contribution is encouraged`.

This visibility is intended to encourage quality participation, not competition
for activity. Posting frequency, reactions, or raw engagement must never by
themselves qualify a member for a shield.

A later joining member must have the same opportunity as a Founding Member to
earn Improver, Insighter, or Champion through meaningful contribution. Founding
status may retain its own permanent identity and appropriate founding-specific
benefits, but it must not create a closed class that owns product discussion or
contribution recognition.

**Founding Patron is exceptional and unique to the Owner's friend. It is not
part of the normal recognition progression, is not attainable by other members,
and must never be displayed to ordinary members as a locked or future award.**

### Owner Portal connection

The Owner Portal is the operating view over central LayMatched information, not
a window into customers' private matched-betting records.

In addition to installation/customer operational monitoring, it should provide
a Founding 100 collaboration inbox showing, as appropriate:

- new ideas/issues/discussions;
- conversations awaiting an Owner response;
- suggestions attracting useful member support;
- items moving through consideration/planning/delivery;
- contributions that may merit recognition.

The Owner should be able to respond, update the collaboration status, connect a
discussion to a planned/delivered LayMatched improvement, and administer
recognition. When an improvement ships, the originating collaboration can show
that it was added to LayMatched and, where appropriate, in which version.

This creates a closed product-learning loop:

`Customer App ↔ Central Collaboration/Recognition/Monitoring ↔ Owner Portal`

while preserving the one-way privacy boundary around customer betting and money
data.

### Implementation and release boundary

This section records agreed architecture and product direction. It does **not**
supersede the current release process or authorise implementation ahead of the
remaining installation/MFA acceptance gate.

Current order remains:

`Finish installer/MFA acceptance → lock/reconcile customer journey and design
system → implement the core customer experience consistently → Profile and
recognition → central Community/collaboration → Owner Portal integration →
Founder #001 rehearsal → Founding Beta`.

Where implementation reveals a necessary contract change between the customer
VPS, central services, and Owner Portal, that contract must preserve the privacy
boundary above and be reviewed before implementation.



## 47. RC5 Customer Installation, UX Acceptance & Failure Recovery — 2026-09-24

### Acceptance objective and candidate

A completely clean Ubuntu 24.04 AWS customer VPS was used to experience the
customer installation as a real customer rather than as a source-level test.
The installation used immutable candidate `v0.2.0-rc.5` with the existing
candidate manifest and the approved application source
`23f49ef427570bda7e45fa103452236cca09358f`.

The exercise was deliberately treated as customer-experience acceptance. The
installer was allowed to perform its normal Docker, registry, DNS, HTTPS,
application-health, activation-profile and MFA journey. The revised installer
started central hostname/DNS work early enough to overlap it with useful local
installation work. A visible blocking DNS wait still remained; the observed
final wait line was 482 seconds before HTTPS proceeded. This is a future
experience/performance improvement rather than a release-blocking functional
failure.

HTTPS then completed successfully, Certbot obtained the customer certificate,
Nginx validation passed, and the customer login page was verified at the
customer hostname.

### Customer-facing installer experience accepted

The revised activation-profile wording explains that full name, town/city and
two-letter country code are collected for the LayMatched activation record and
are not added to the customer server configuration.

The MFA handoff presents a dedicated `ONE LAST STEP` screen with the customer
URL and simple instructions to sign in, configure Authenticator, enter the
verification code and save recovery codes. The terminal automatically waits
for completion and does not require the customer to press a key.

After verified MFA the installer displays `ACCOUNT SECURED`, completes central
activation, enables the recognition heartbeat scheduler, and presents the
customer-focused `ALL DONE! / WELCOME TO LAYMATCHED` completion screen. Detailed
technical installation information is kept separately in
`/opt/laymatched/installation-support.txt`.

The Owner accepted this customer-facing installation experience.

### Real interruption and recovery proof

During the MFA browser handoff the installer was accidentally interrupted with
Ctrl+C while the customer attempted to copy the displayed URL. This created a
realistic recovery scenario rather than a synthetic failure test.

The first retry exposed a defect: the Release Candidate clean-install guard
rejected every RC invocation that found existing configuration, despite the
installation having durable resumable state. The recovery implementation was
changed so that an RC retry is permitted only when evidence proves it is the
same interrupted immutable candidate and installation. Candidate identity,
source SHA, image digests, registry/release identity, installation ID, customer
hostname, activation journal and authenticated activation session must agree,
and the permitted MFA-handoff recovery state must be proven. Missing,
mismatched, unrelated or completed state remains fail-closed.

The preserved AWS installation was then used to prove this change. The installer
reported that it had verified the interrupted Release Candidate installation
and was resuming at the MFA handoff.

That genuine retry exposed a second recovery defect. HTTPS had already been
successfully proven during the original run, but the retry attempted to replay
the one-time central HTTPS challenge. Central correctly rejected the consumed
challenge. Recovery was amended so that an authenticated same-installation
resume can reuse an already recorded central HTTPS verification only when
durable local and central state agree on activation ID, installation ID and
hostname, central HTTPS is recorded as verified with a verification timestamp,
and the expected activation/profile state is present. Fresh HTTPS installation
continues to require the normal challenge and inconsistent or downgraded state
fails closed. The customer login route is still independently verified.

The same preserved RC5 installation was run again with the corrected installer.
It safely passed the RC identity recovery checks, reused the previously verified
HTTPS state, independently verified the customer login route, returned to
`ONE LAST STEP`, automatically detected completed MFA and recovery codes,
completed central activation, enabled the heartbeat scheduler, and reached the
final `WELCOME TO LAYMATCHED` screen.

### Acceptance conclusion

The RC5 customer exercise therefore provides direct acceptance evidence for:

- clean customer installation through DNS, HTTPS, login and MFA;
- customer-facing installer/MFA/completion experience;
- durable same-candidate recovery after terminal interruption at the MFA handoff;
- fail-closed protection against mismatched/unrelated RC state;
- recovery after a previously consumed one-time HTTPS challenge using
  authenticated durable verification state rather than bypassing HTTPS proof;
- automatic continuation from verified MFA through central activation and
  heartbeat enablement.

Installer recovery is therefore accepted for the exercised interruption path.
This does not imply that every possible server, network, disk or operating-system
failure mode has been proven. The remaining visible DNS delay may be improved
later without reopening this accepted functional recovery path.

### Follow-up customer-onboarding considerations

The next installer/onboarding review should explicitly exercise customer input
mistakes, especially an invalid Installer Token and a password/confirmation
mismatch, and confirm that errors are clear, safe, retryable and do not leave
ambiguous partial state.

The subscription journey already has an email identity available before VPS
installation. A post-purchase welcome pack should be considered as part of the
customer onboarding/communications design. It should use the authoritative
subscription/customer email rather than asking the installer to collect the
address again, and should avoid sending installer tokens, passwords, MFA
secrets, recovery codes or other reusable credentials by ordinary email.
