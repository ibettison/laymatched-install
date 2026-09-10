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
