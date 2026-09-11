# Founding Member Beta — Installation Proof Audit

Date: 2026-09-11  
Repository: `ibettison/laymatched-install`  
Audited branch: `main` at `149eb6ef009d07872da5b81935b434a97a24c6a6`  
PAD source: Issue #3  
Scope: read-only; customer MFA deliberately excluded.

## Verdict

**No.** A genuine customer cannot currently start from a clean Ubuntu 24.04 VPS and valid Installer Token and reach a working private LayMatched installation over a trusted customer HTTPS hostname without Owner/developer intervention.

The installer and private-image authorization foundations are substantially implemented. The decisive missing path is customer activation: nickname reservation, central DNS provisioning, local ACME certificate issuance, HTTPS configuration, and end-to-end browser proof.

## Current status

| Area | Status |
|---|---|
| Core installer architecture | 🟡 Implemented, not live-proven |
| Central Auth API | 🟡 Code implemented; deployment unknown |
| Private registry | 🟡 Code/config/workflow implemented; live pull unproven |
| Production Nginx/TLS integration | 🟡 Configuration exists; Fasthosts acceptance unknown |
| Installer-token/private-image flow | 🟡 Partial; credential persistence gap |
| Clean Ubuntu customer install | 🟡 HTTP mechanics exist; end-to-end proof absent |
| Safe rerun | 🟡 Static logic only; full rerun unproven |
| Failure/recovery | 🟡 Fail-fast behavior exists; cleanup is incomplete |
| DNS/customer HTTPS | 🔴 Not implemented at runtime |

## Proven by repository evidence

- Ubuntu validation, Docker/Compose setup, generated secrets, application Compose generation, and health checks exist in [`install.sh`](../install.sh).
- Local activation journal/key handling provides atomic recovery and rejects secret-bearing state in [`tools/local_activation.py`](../tools/local_activation.py).
- Auth API token hashing, invalid/revoked/expired-token rejection, rate limiting, and pull-only registry scopes exist in [`auth-api/main.go`](../auth-api/main.go).
- Registry JWTs are generated with a one-hour TTL.
- Release workflow builds application images from an exact application SHA and verifies both private pulls.
- Central Auth API and registry Compose services bind to loopback ports in [`deployment/docker-compose-production.yml`](../deployment/docker-compose-production.yml).
- Installer/local-activation tests passed: **10/10**.
- Activation contract tests passed: **19/19**.
- Shell syntax validation and `git diff --check` passed.

These are code/local-contract results, not production acceptance.

## Implemented but not proven live

- `auth.matched.laysports.co.uk` and `registry.matched.laysports.co.uk` behind the existing Fasthosts Nginx.
- Central Auth API and private registry deployment.
- Public TLS certificates and external HTTPS reachability.
- Auth API → registry credential exchange using a real controlled token.
- Private image publication, approval, and customer pull.
- Clean Ubuntu 24.04 installation and full installer rerun.

The activation contract explicitly states that runtime implementation and deployment are not authorized; it contains no licensing backend, DNS provider integration, or ACME implementation ([contract README](../contracts/activation/README.md), [architecture gate status](../docs/issue-6-activation-architecture.md#gate-status)).

## Actual gaps

### 1. Customer activation runtime is absent

The installer only calls:

```text
POST https://auth.matched.laysports.co.uk/installer/authorize
```

It does not call `/v1/activations`, reserve a nickname, poll activation state, or submit HTTPS proof.

### 2. Customer DNS and HTTPS are absent

The installer writes a catch-all `server_name _` Nginx site listening only on port 80 and proxying to `127.0.0.1:8080`. It does not configure port 443, certificates, ACME, customer hostnames, or DNS.

The README still describes HTTPS and custom hostnames as future work.

### 3. Installer credentials can persist through Docker login

`install.sh` and `update.sh` run `docker login --password-stdin`, but neither uses an ephemeral `DOCKER_CONFIG` nor runs `docker logout`. The supplied Installer Token can therefore remain in Docker's root credential configuration, contrary to the repository's claim that it is never stored on disk.

### 4. Approved-version handling is not fail-closed

If `/data/approved_version.txt` is missing or empty, the Auth API falls back to `v0.1.0` instead of rejecting authorization.

### 5. Auth API production data permissions conflict

The Auth API image runs as UID/GID `1000:1000`, while the production directory setup creates its data directory as `root:root` mode `750`. Without an additional ownership mechanism, the API may be unable to create its SQLite database and signing material.

### 6. Documentation/protocol mismatch

`auth-api/README.md` describes the `/installer/authorize` `registry_token` as a JWT, but the current handler returns the original Installer Token. The short-lived JWT is issued later by `/token`.

## Manual steps still present

Customer actions currently include obtaining a VPS, cloning the public repository, running `sudo ./install.sh`, and entering the Installer Token plus initial application credentials.

Owner/developer actions still required include central Auth/registry deployment, Fasthosts Nginx and certificate configuration, approved-release maintenance, private image publication, and manual customer DNS/certificate handling. The last group must be removed from the normal per-customer path before beta.

## Smallest next implementation slice

**PR title:** `fix: make Gate 1 Auth and registry pull path ephemeral and fail-closed`  
**Suggested branch:** `fix/gate-1-auth-registry-production-bootstrap`

Scope:

- Make installer/update Docker authentication ephemeral and remove credentials after pulls.
- Make missing/invalid approved release state fail closed.
- Correct Auth API production data-directory ownership.
- Correct the Auth API default registry hostname.
- Align deployment tests and documentation with the actual Nginx configuration.
- Add focused tests for credential cleanup, approval failure, and startup permissions.

Out of scope: customer MFA, `/v1/activations` runtime, DNS provider integration, customer ACME/HTTPS orchestration, production deployment, and backup/restore.

This slice improves the token → private-image → clean-VPS path, but cannot by itself close the trusted-HTTPS outcome.

## Acceptance plan

After that slice:

1. Run shell, unit, contract, and deployment tests.
2. Deploy Auth API/registry in a controlled non-customer environment using existing host Nginx only.
3. Verify external HTTPS health for both central hostnames and the expected registry challenge.
4. Test valid, invalid, revoked, and expired Installer Tokens.
5. Verify missing approval state fails closed.
6. Verify customer credentials are absent from Docker configuration after pulls.
7. Verify installer pull access is limited to approved API/Web repositories and pull actions.
8. Run the installer on a disposable clean Ubuntu 24.04 VPS.
9. Run it twice and verify persistent state and container identity.
10. Exercise Auth API outage, registry outage, image-pull failure, prerequisite failure, interruption, and startup failure.
11. Separately implement and prove:

```text
Installer
→ activation bootstrap
→ nickname reservation
→ DNS creation and resolution
→ local ACME certificate
→ HTTPS customer hostname
→ browser access
```

## Validation warnings

- No production, DNS, VPS, certificate, secret, commit, push, or deployment changes were made during this audit.
- Deployment tests currently have two failures caused by expectations that do not match the present final Nginx configuration.
- Go Auth API tests did not complete in the audit environment.
- No live Fasthosts, public DNS, registry, or ACME state was treated as proven.
