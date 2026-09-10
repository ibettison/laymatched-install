# LAYMATCHED — PAD v7.6 Beta-Scope Reconciliation

Date: 2026-09-10

Investigation basis: PAD Issue #3 and its v7.1/v7.2 addenda, plus
`ibettison/layMatchedBetting` `origin/main` at commit
`c0fe3704ac722d5428101e3450eea31ef7635fec`.

This is a read-only investigation report. No application code was changed.

## 1. Executive summary

The smallest truthful beta scope is:

- A-07 is implemented and needs acceptance only.
- A-08 is genuinely not implemented for customers. Existing Owner/Admin MFA
  must not be counted.
- A-09a is implemented and needs explicit acceptance/testing only.
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
| A-07 New-bookmaker onboarding | 🟢 IMPLEMENTED — ACCEPTANCE ONLY | `backend/app/api/mvp.py`: `OperatorCreate`, `POST /api/operators`, `POST /api/offers`; `frontend/src/Workspace.tsx`: `AccountCreateForm`, `SetupPanel`, `PlanBet`; `Operator` model/migrations; backend/frontend tests | No material implementation gap found. Check friendly duplicate-slug handling | Customer journey on desktop/tablet/mobile using both bookmaker and exchange, then offer and first normal workflow |
| A-08 Customer MFA | 🔴 NOT IMPLEMENTED | `backend/app/auth.py` has password-only login; TOTP exists only in `backend/app/owner_auth.py` | Customer enrolment, QR/manual secret, activation verification, password+TOTP login, recovery, persistence, and tests | Full implementation and clean-install acceptance |
| A-09a Balance freshness | 🟢 IMPLEMENTED — ACCEPTANCE ONLY | `Operator.balance_updated_at`; migration `0002_bankroll_accounts.py`; reconciliation routes; seven-day `stale_balance` dashboard alert; freshness shown in `DashboardHome.tsx` and `Workspace.tsx` | Explicit automated boundary/restart tests are weak or absent | Verify recent/stale states, prompt, reconciliation update, restart/upgrade persistence, and responsive usability |
| B-08 Referral/VPS credit | 🟡 PARTIAL | Marketing `referral_code` capture in `central_models.py`, `campaign.js`, `interests.py`, and `metrics.py`; Owner Leads display | No member referral identity, paid-subscription qualification, abuse protection, reward state, manual VPS-credit workflow, or referral dashboard | End-to-end referral/subscription/reward acceptance after implementation |
| I-06 Automatic DNS/nickname provisioning | 🟡 PARTIAL | Activation OpenAPI/state contracts and `tools/local_activation.py`; installer README still describes HTTP-only/planned HTTPS | Central reservation, real DNS/ACME integration, collision/release handling, customer-facing install path, and HTTPS acceptance | Real customer-style installation on a VPS |
| I-10a Backup/restore | 🟡 PARTIAL | Application `update.sh` and backup documentation contain database backup/rollback logic; installer `update.sh` does not; installer README says automatic backups are not implemented | Protected backup in the actual customer update path, documented restore, and real loss/restore testing | Restore after simulated VPS/data loss |
| M-01 Analytics and Founding 100 interest | 🟢 COMPLETE + ACCEPTED | `campaign.js`; central funnel/lead models and APIs; Owner Leads; frontend/backend tests; v7.6 reports production interest/email path proven | No material beta implementation gap identified | No additional M-01 acceptance gate beyond normal final release checks |
| Founding Member Hub | 🔴 NOT IMPLEMENTED | Customer community routes cover bookmaker suggestions only; Owner feedback/communications are owner-only | Authenticated member hub, general bug/idea/feedback intake, history, announcements, and Owner follow-up | Full hub acceptance with a real founding member |
| R-01 Central Recognition | 🟡 PARTIAL | `Recognition.tsx` and `recognitionClient.ts` exist, but the client returns an empty/future profile; recognition contract calls the API future work | Central identity, numbering, contribution history, manual awards, audit/revocation, and authenticated member display | Central recognition acceptance |

## 3. Detailed findings

### A-07 — New-bookmaker onboarding improvements

A normal authenticated customer can currently:

1. Create an arbitrary bookmaker or exchange.
2. Supply a name, slug, balance, and optional HTTPS homepage.
3. Pass backend validation.
4. Immediately see the new operator in the normal workspace.
5. Add a manual offer and use the bookmaker/exchange in the normal planning workflow.

Relevant implementation:

- `backend/app/api/mvp.py`: `OperatorCreate`, operator routes, and offer route.
- `backend/app/models.py`: `Operator`.
- `frontend/src/Workspace.tsx`: `AccountCreateForm`, `SetupPanel`, and `PlanBet`.
- `backend/tests/test_mvp_flow.py`.
- `frontend/src/Workspace.test.tsx`.

The code distinguishes `bookmaker` and `exchange`. Exchange accounts are used
in planning; bookmaker accounts are tied to manually created offers. Responsive
layouts and CSS exist. No production or real-customer acceptance evidence was
found.

Classification: **🟢 IMPLEMENTED — ACCEPTANCE ONLY**.

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
- Existing previously accepted core application work A-01 through A-06,
  subject to the PAD's current acceptance record.
- Marketing attribution and production interest/email flow described in v7.6.

A-07 and A-09a should not be called fully accepted yet, but their
implementation should not be rebuilt.

## 5. IMPLEMENTED BUT NEEDS ACCEPTANCE

- A-07 customer bookmaker/exchange creation and immediate normal-workflow use.
- A-09a balance freshness, stale detection, visible vigilance prompt, and
  reconciliation timestamps.

Acceptance should be performed against a clean `origin/main` deployment,
including desktop, tablet, and mobile paths.

## 6. GENUINE IMPLEMENTATION GAPS

The smallest implementation slices are:

1. A-08 customer MFA enrolment, activation, login challenge, recovery, reset,
   throttling, persistence, and clean-install tests.
2. B-08 central referral identity, paid-subscription qualification, abuse
   controls, Owner-visible state, and manual VPS-credit workflow.
3. I-06 central nickname reservation, DNS/ACME integration, collision/release
   handling, and real customer install flow.
4. I-10a backup/restore behavior in the actual installer/update path, with
   protected backup storage and real restoration testing.
5. Founding Member Hub authenticated identity, submissions, history,
   announcements, and Owner follow-up.
6. R-01 authoritative central recognition records and authenticated member
   presentation.

## 7. PAD corrections

Issue #3 should be corrected as follows:

- Keep A-08 as a genuine implementation blocker and explicitly state that
  Owner/Admin MFA does not satisfy Customer MFA.
- Change A-07 to **implemented — acceptance only**.
- Change A-09a to **implemented — acceptance only**.
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

1. Accept A-07 and A-09a through focused clean-environment customer tests.
2. Implement Customer MFA.
3. Establish the central founding-member identity layer needed by the Hub,
   Recognition, and referral workflow.
4. Implement the minimum Hub and central Recognition workflow.
5. Complete I-06 and I-10a through real customer-style VPS installation and
   recovery tests.
6. Implement B-08 against the real customer/subscription identity and Stripe
   lifecycle.
7. Complete Stripe test-mode lifecycle acceptance, Owner realistic-data
   acceptance, and final clean-install/customer handoff.
8. Perform the final Founding Member Beta RC review.

## 9. Current release blockers

- Customer MFA is not implemented.
- A-07 and A-09a require acceptance.
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
