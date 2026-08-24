# Owner Action Plan: GHCR Bootstrap Image Transfer & Cleanup

## Security Model

**laymatched-deploy user on VPS has NO Docker access** — not in docker group, no docker sudo permissions.
All GHCR interactions are performed by the OWNER locally, never by the deployment user.

## One-Time GHCR Bootstrap Image Transfer (During Bootstrap Phase)

### Prerequisites
- Owner has GHCR Personal Access Token (PAT) with `read:packages` scope
- Auth API bootstrap image published to GHCR via workflow: `ghcr.io/ibettison/laymatched-auth-api:v1.0.0`
- Owner has SSH access to VPS as a privileged user (not laymatched-deploy)

### Owner Local Commands (Run on OWNER machine)

```bash
# 1. Login to GHCR (PAT via stdin - not logged)
echo "<GHCR_PAT>" | docker login ghcr.io -u ibettison --password-stdin

# 2. Pull bootstrap Auth API image locally
docker pull ghcr.io/ibettison/laymatched-auth-api:v1.0.0

# 3. Save image to tarball
docker save ghcr.io/ibettison/laymatched-auth-api:v1.0.0 -o laymatched-auth-api-v1.0.0.tar

# 4. Verify tarball
docker load -i laymatched-auth-api-v1.0.0.tar
docker images ghcr.io/ibettison/laymatched-auth-api:v1.0.0

# 5. Transfer tarball to VPS (secure copy - Owner's privileged SSH)
scp laymatched-auth-api-v1.0.0.tar <privileged-user>@<VPS>:/tmp/

# 6. Logout from GHCR locally
docker logout ghcr.io
```

### VPS Load Command (Run as PRIVILEGED USER on VPS, NOT laymatched-deploy)

```bash
# 1. Load image into Docker daemon
docker load -i /tmp/laymatched-auth-api-v1.0.0.tar

# 2. Retag for bootstrap compose (bootstrap compose references ghcr.io/ibettison/laymatched-auth-api:v1.0.0 directly)
# No retag needed if bootstrap compose uses GHCR reference, OR:
docker tag ghcr.io/ibettison/laymatched-auth-api:v1.0.0 ghcr.io/ibettison/laymatched-auth-api:v1.0.0

# 3. Verify image available to Docker daemon
docker images ghcr.io/ibettison/laymatched-auth-api:v1.0.0

# 4. Remove tarball
rm /tmp/laymatched-auth-api-v1.0.0.tar
```

## GHCR Credential Cleanup (After Private Registry Transition)

### Owner Local Verification

```bash
# 1. Verify no GHCR credentials remain locally
cat ~/.docker/config.json | grep -v ghcr.io || echo "No GHCR credentials found"

# 2. Verify no credential helper cached GHCR
docker-credential-gcr list 2>/dev/null | grep ghcr.io || echo "No GHCR in credential helper"
```

### VPS Verification (Run as PRIVILEGED USER)

```bash
# 1. Verify no GHCR credentials in Docker config
cat /root/.docker/config.json 2>/dev/null | grep -v ghcr.io || echo "No GHCR credentials on VPS"

# 2. Verify image not pulled from GHCR by deployment user
# (laymatched-deploy cannot run docker commands - this is enforced)
```

## Security Verification Checklist

After cleanup, verify:
- [ ] Owner local `docker logout ghcr.io` succeeded
- [ ] No `ghcr.io` entry in Owner's `~/.docker/config.json`
- [ ] No GHCR PAT in Owner's environment variables
- [ ] No GHCR PAT in Owner's shell history (PAT entered via stdin)
- [ ] VPS Docker daemon has the bootstrap image loaded (not pulled by laymatched-deploy)
- [ ] laymatched-deploy user has NO docker group membership
- [ ] laymatched-deploy user has NO docker sudo permissions
- [ ] Private registry images used for all subsequent production operations

## Production Image Reference

After transition, all production references use:
- `registry.matched.laysports.co.uk/laymatched-auth-api:v1.0.0`
- `registry.matched.laysports.co.uk/laymatched-registry:v1.0.0`

**GHCR is never used by customer installations.**
**laymatched-deploy never authenticates to GHCR.**