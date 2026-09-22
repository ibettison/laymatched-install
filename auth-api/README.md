# LayMatched Auth API & Private Registry

Owner-side infrastructure for the LayMatched installer authorization and private Docker registry.

## Components

| Component | Directory | Purpose |
|-----------|-----------|---------|
| Auth API | `auth-api/` | Validates installer tokens, issues short-lived registry JWTs |
| Private Registry | `registry/` | Docker Distribution registry with token auth |
| Token Management CLI | `tools/token-tool/` | Admin CLI for issuing/revoking tokens |
| Deployment | `deployment/` | Docker Compose, nginx config, CI/CD workflow |

## Auth API

### Endpoint

```
POST https://auth.matched.laysports.co.uk/installer/authorize
```

### Request

```json
{
  "installer_token": "lm_inst_abcdef123456..."
}
```

### Response (Success)

```json
{
  "registry_token": "lm_inst_abcdef123456...",
  "approved_version": "v0.1.1",
  "registry_url": "registry.matched.laysports.co.uk"
}
```

### Response (Error)

```json
{
  "error": "invalid credentials"
}
```

`registry_token` is the validated Installer Token returned for the subsequent
Docker Registry token exchange; it is not itself the short-lived registry JWT.
Docker sends it to the registry token service, which returns a scoped JWT for
image pulls. The installer keeps Docker authentication in a temporary
credential directory and removes it when the operation exits.

### Health Check

```
GET https://auth.matched.laysports.co.uk/health
```

### JWKS Endpoint

```
GET https://auth.matched.laysports.co.uk/.well-known/jwks.json
```

## Private Registry

- **URL**: `https://registry.matched.laysports.co.uk`
- **Auth**: Bearer token (JWT from Auth API)
- **Installer scope**: `repository:laymatched-api:pull,repository:laymatched-web:pull`
- **Release flow**: candidates are published to owner-only `laymatched-api-staging`
  and `laymatched-web-staging` repositories. They are promoted to the
  customer-visible repositories only after approval. Installer credentials are
  never granted staging access.
- **TTL**: 1 hour

## Token Management

### Issue New Token

```bash
# Build the tool
cd tools/token-tool
go build -o token-tool .

# Issue token (expires in 365 days by default)
./token-tool issue customer-123 "Founding member beta" --expire-days 365
```

Output:
```
=== NEW INSTALLER TOKEN ===
Customer ID: customer-123
Token:       lm_inst_abcdef1234567890abcdef12
Expires:     2025-08-19
Notes:       Founding member beta

IMPORTANT: Save this token now. It cannot be retrieved again.
Only one-way bcrypt and SHA-256 hashes are stored in the database.
```

### List Tokens

```bash
./token-tool list
```

### Revoke Token

```bash
./token-tool revoke 1
```

### Delete Token (Permanent)

```bash
./token-tool delete 1
```

## Deployment

### Prerequisites

- Existing VPS with Docker and Docker Compose
- Domains: `auth.matched.laysports.co.uk`, `registry.matched.laysports.co.uk` pointing to VPS IP
- Let's Encrypt certificates for both domains

### Directory Structure on VPS

```
/opt/laymatched-auth/
├── data/              # Auth API SQLite DB and generated runtime keys
├── approval/          # root-controlled approved_version.txt (read-only to Auth API)
├── docker-compose.yml
└── .env               # From deployment/.env.example

/opt/laymatched-registry/
└── data/              # Registry image storage
```

### Deploy

```bash
# On VPS
mkdir -p /opt/laymatched-auth/data /opt/laymatched-registry/data
cp deployment/.env.example /opt/laymatched-auth/.env
# Edit .env with your values

# Build images
docker build -t laymatched-auth-api:latest ./auth-api
docker build -t laymatched-registry:latest ./registry

# Deploy
cd /opt/laymatched-auth
docker compose up -d

# Verify
curl https://auth.matched.laysports.co.uk/health
curl https://registry.matched.laysports.co.uk/v2/
```

### TLS Certificates

Place Let's Encrypt certificates in:

```
/opt/laymatched-auth/certs/auth.matched.laysports.co.uk/fullchain.pem
/opt/laymatched-auth/certs/auth.matched.laysports.co.uk/privkey.pem
/opt/laymatched-auth/certs/registry.matched.laysports.co.uk/fullchain.pem
/opt/laymatched-auth/certs/registry.matched.laysports.co.uk/privkey.pem
```

Or use certbot with nginx:

```bash
certbot certonly --nginx -d auth.matched.laysports.co.uk -d registry.matched.laysports.co.uk
```

## CI/CD: Approved Release Publication

The workflow `.github/workflows/release-to-private-registry.yml` publishes approved releases:

1. Triggers manually with version tag and SHA
2. Builds exact-SHA API/Web images into owner-only private staging repositories
3. Pushes and pulls both staging images with the scoped Owner token for verification
4. Updates the root-controlled `approval/approved_version.txt` on the VPS via the privileged release path
5. Promotes the verified images into the customer-visible API/Web repositories
6. Pulls both promoted images with the pull-only Installer Token

The Owner token used by this workflow has explicit push/pull scopes for the two
staging repositories and explicit push/pull scopes for the two customer-visible
repositories. It is not a registry administrator credential. Because Docker
Distribution repository scopes do not express an approved-tag policy, keeping
unapproved tags out of the customer-visible repositories is the registry-level
release control.

Required GitHub Secrets:
- `PRIVATE_REGISTRY_USER` - Registry username
- `PRIVATE_REGISTRY_TOKEN` - Registry password/token
- `VPS_HOST` - VPS hostname/IP
- `VPS_USER` - SSH username
- `VPS_SSH_KEY` - SSH private key

## Security Model

- **Installer Tokens**: Stored as bcrypt and SHA-256 hashes, never plaintext
- **Registry Tokens**: JWT (RS256), 1-hour TTL, pull-only scope, audience-bound
- **Rate Limiting**: 50 req/min per IP on Auth API
- **Logging**: Structured JSON, tokens redacted to prefix only (`lm_inst_****`)
- **Network**: Internal Docker network, only nginx exposed on 80/443
- **Keys**: RSA 2048-bit, auto-generated on first run, stored in `/data/`
- **Release approval**: Owner registry tokens remain available for scoped release publication; Installer-Token pull credentials require a valid approval record. The record is mounted read-only from the root-controlled approval path.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | 8443 | Auth API internal port |
| `DB_PATH` | /data/auth-tokens.db | SQLite database path |
| `APPROVED_VERSION_PATH` | `/data/approved_version.txt` | Trusted approved release record; installer authorization and registry pull-token issuance fail closed when missing, empty, or invalid |
| `REGISTRY_URL` | registry.matched.laysports.co.uk | Registry hostname |
| `ACTIVATION_SERVICE_URL` | empty | Central activation API URL returned to installers; production is `https://matched.laysports.co.uk` and must be configured before DNS/HTTPS onboarding |
| `PRIVATE_KEY_PATH` | /data/private.pem | RSA private key |
| `PUBLIC_KEY_PATH` | /data/public.pem | RSA public key |
| `RATE_LIMIT_PER_MIN` | 50 | Auth API rate limit per IP |
| `LOG_LEVEL` | info | Log level (debug/info) |

## Testing

```bash
cd auth-api
go test -v ./...
```

Tests cover:
- Valid token authorization
- Unknown/revoked/expired token rejection
- Malformed request handling
- Health & JWKS endpoints
- Token redaction in logs
- Registry token TTL (1 hour)
- Approved version changes
- Registry URL in response
- Rate limiting
- Token entropy
- Concurrent validation
