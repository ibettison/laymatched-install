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
POST https://api.laymatched.com/installer/authorize
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
  "registry_token": "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9...",
  "approved_version": "v0.1.1",
  "registry_url": "registry.laymatched.io"
}
```

### Response (Error)

```json
{
  "error": "invalid credentials"
}
```

### Health Check

```
GET https://api.laymatched.com/health
```

### JWKS Endpoint

```
GET https://api.laymatched.com/.well-known/jwks.json
```

## Private Registry

- **URL**: `https://registry.laymatched.io`
- **Auth**: Bearer token (JWT from Auth API)
- **Scope**: `repository:laymatched-api:pull,repository:laymatched-web:pull`
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
Only the bcrypt hash is stored in the database.
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
- Domains: `api.laymatched.com`, `registry.laymatched.io` pointing to VPS IP
- Let's Encrypt certificates for both domains

### Directory Structure on VPS

```
/opt/laymatched-auth/
├── data/              # SQLite DB, RSA keys, approved_version.txt
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
curl https://api.laymatched.com/health
curl https://registry.laymatched.io/v2/
```

### TLS Certificates

Place Let's Encrypt certificates in:

```
/opt/laymatched-auth/certs/api.laymatched.com/fullchain.pem
/opt/laymatched-auth/certs/api.laymatched.com/privkey.pem
/opt/laymatched-auth/certs/registry.laymatched.io/fullchain.pem
/opt/laymatched-auth/certs/registry.laymatched.io/privkey.pem
```

Or use certbot with nginx:

```bash
certbot certonly --nginx -d api.laymatched.com -d registry.laymatched.io
```

## CI/CD: Approved Release Publication

The workflow `.github/workflows/release-to-private-registry.yml` publishes approved releases:

1. Triggers manually with version tag and SHA
2. Pulls images from GHCR (staging)
3. Retags for private registry
4. Pushes to `registry.laymatched.io`
5. Updates `approved_version.txt` on VPS via SSH

Required GitHub Secrets:
- `PRIVATE_REGISTRY_USER` - Registry username
- `PRIVATE_REGISTRY_TOKEN` - Registry password/token
- `VPS_HOST` - VPS hostname/IP
- `VPS_USER` - SSH username
- `VPS_SSH_KEY` - SSH private key

## Security Model

- **Installer Tokens**: Stored as bcrypt hashes only, never plaintext
- **Registry Tokens**: JWT (RS256), 1-hour TTL, pull-only scope, audience-bound
- **Rate Limiting**: 50 req/min per IP on Auth API
- **Logging**: Structured JSON, tokens redacted to prefix only (`lm_inst_****`)
- **Network**: Internal Docker network, only nginx exposed on 80/443
- **Keys**: RSA 2048-bit, auto-generated on first run, stored in `/data/`

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | 8443 | Auth API internal port |
| `DB_PATH` | /data/auth-tokens.db | SQLite database path |
| `APPROVED_VERSION` | v0.1.0 | Current approved release version |
| `REGISTRY_URL` | registry.laymatched.io | Registry hostname |
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