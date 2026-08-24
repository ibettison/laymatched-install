# Owner Action Plan: VPS GHCR Login & Cleanup

## One-Time VPS GHCR Login (During Bootstrap Phase)

### Prerequisites
- Owner has GHCR Personal Access Token (PAT) with `read:packages` scope
- Auth API bootstrap image published to GHCR via workflow: `ghcr.io/ibettison/laymatched-auth-api:v1.0.0`

### Exact Commands (Run as `laymatched-deploy` on VPS)

```bash
# 1. Login to GHCR (interactive - PAT not stored)
echo "<GHCR_PAT>" | docker login ghcr.io -u ibettison --password-stdin

# 2. Pull bootstrap Auth API image
docker pull ghcr.io/ibettison/laymatched-auth-api:v1.0.0

# 3. Verify image pulled
docker images ghcr.io/ibettison/laymatched-auth-api:v1.0.0

# 4. Retag for bootstrap compose (optional - compose references GHCR directly)
# No retag needed - bootstrap compose uses ghcr.io/ibettison/laymatched-auth-api:v1.0.0 directly
```

## GHCR Credential Cleanup (After Private Registry Transition)

### Exact Commands (Run as `laymatched-deploy` on VPS)

```bash
# 1. Logout from GHCR
docker logout ghcr.io

# 2. Verify no GHCR credentials remain
cat ~/.docker/config.json | grep -v ghcr.io || echo "No GHCR credentials found"

# 3. Verify no credential helper cached GHCR
docker-credential-gcr list 2>/dev/null | grep ghcr.io || echo "No GHCR in credential helper"

# 4. Optional: Remove entire Docker config if only GHCR was used
# rm ~/.docker/config.json  # Only if no other registries configured
```

## Security Verification

After cleanup, verify:
- [ ] `docker logout ghcr.io` succeeded
- [ ] No `ghcr.io` entry in `~/.docker/config.json`
- [ ] No GHCR PAT in environment variables
- [ ] No GHCR PAT in shell history (PAT entered via stdin, not command line)
- [ ] Private registry images used for all subsequent operations

## Production Image Reference

After transition, all production references use:
- `registry.matched.laysports.co.uk/laymatched-auth-api:v1.0.0`
- `registry.matched.laysports.co.uk/laymatched-registry:v1.0.0`

**GHCR is never used by customer installations.**