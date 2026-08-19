# LayMatched Installer

Public installation and update tooling for **LayMatched**.

This repository is the customer-facing installer for LayMatched. It is intentionally separate from the private LayMatched application source repository and must not contain proprietary application source code, credentials, API keys, passwords, private keys, or customer-specific configuration.

## Status

The installer has been tested on AWS with clean Ubuntu 24.04 installations. It is ready for customer acceptance testing.

## Supported Platforms

- **Ubuntu 20.04 LTS (Focal)**
- **Ubuntu 22.04 LTS (Jammy)**
- **Ubuntu 24.04 LTS (Noble)**

Non-Ubuntu systems are explicitly rejected.

## System Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU      | 2 cores | 4+ cores    |
| RAM      | 2 GB    | 4+ GB       |
| Disk     | 2 GB free on /opt | 10+ GB |

The installer checks these on first run and warns/errors accordingly.

## Fresh Installation

```bash
git clone https://github.com/ibettison/laymatched-install.git
cd laymatched-install
sudo ./install.sh
```

The installer will:
1. Validate Ubuntu version and system resources
2. Install Docker Engine and Docker Compose plugin (if not present)
3. Prompt for configuration (see below)
4. Generate secure random secrets
5. Create docker-compose.yml with multi-service stack (PostgreSQL, API, Web)
6. Install and configure Nginx reverse proxy on port 80
7. Pull images from GHCR and start services
8. Run health checks

### What the Installer Asks For

| Prompt | Description | Stored |
|--------|-------------|--------|
| GHCR Token | GitHub Container Registry auth token (for pulling private images) | No (used once for docker login) |
| Login ID | LayMatched username for initial admin account | Yes (in .env) |
| Password | LayMatched password (min 12 chars, confirmed) | Yes (PBKDF2 hash in .env) |
| Version/Tag | Release tag to install (default: `latest`) | Yes (in .env as APP_VERSION) |

### Where Things Are Installed

| Component | Location |
|-----------|----------|
| Application data | `/opt/laymatched/` (owned by root, 750) |
| Configuration & secrets | `/opt/laymatched/.env` (600, root:root) |
| Docker Compose file | `/opt/laymatched/docker-compose.yml` |
| Update script | `/opt/laymatched/update.sh` |
| Nginx site config | `/etc/nginx/sites-available/laymatched` |
| Persistent volumes | Docker volumes: `postgres_data`, `bookmaker_icon_cache` |

### Browser Access

- **External**: HTTP on port 80 via Nginx reverse proxy
- **Internal**: Web container binds to `127.0.0.1:8080` only (never exposed directly)
- **Architecture**: Browser → Nginx:80 → 127.0.0.1:8080 → Web container

HTTPS and custom hostnames (e.g., `nickname.app.laymatched.co.uk`) are planned for a future release.

## Logs and Status Commands

```bash
# View live logs
docker logs -f laymatched-web
docker logs -f laymatched-api
docker logs -f laymatched-db

# Container status
docker ps

# Health status
docker inspect --format='{{.State.Health.Status}}' laymatched-web
docker inspect --format='{{.State.Health.Status}}' laymatched-api
docker inspect --format='{{.State.Health.Status}}' laymatched-db

# Nginx status
systemctl status nginx
nginx -t
```

## Updating

```bash
cd /opt/laymatched
sudo ./update.sh                # Re-pull current version
sudo ./update.sh v0.1.1         # Upgrade to specific version
```

The update script:
- Authenticates to GHCR (prompts for token if not in environment)
- Pulls the specified or current version
- Restarts services
- Runs health checks
- **Only persists new version to .env after health checks pass**
- Preserves all other secrets and persistent volumes

### Version Override Behaviour

| Command | Behaviour |
|---------|-----------|
| `./update.sh` | Uses current APP_VERSION from .env |
| `./update.sh v0.1.1` | Pulls v0.1.1; updates .env only on success |
| `./update.sh latest` | Pulls latest; updates .env only on success |

Failed updates leave the previous APP_VERSION intact.

## Safe Rerun Behaviour

The installer is idempotent:
- Re-running `install.sh` on an existing installation skips resource checks, Docker install, and configuration prompts
- Only re-authenticates to GHCR and pulls/starts services
- Nginx config is re-applied safely
- No secrets are regenerated or lost

## Troubleshooting

### GHCR / Image Pull Failure
```
Error: Failed to authenticate to GitHub Container Registry
```
- Verify your GHCR token has `read:packages` scope
- Token must belong to a user with access to `ghcr.io/ibettison/laymatched-*`
- Re-run installer/update with a valid token

### Docker / Compose Unavailable
```
Error: Docker Compose plugin not available
```
- Run: `apt-get update && apt-get install -y docker-compose-plugin`
- Verify: `docker compose version`

### Containers Unhealthy
```bash
# Check specific container logs
docker logs laymatched-web
docker logs laymatched-api
docker logs laymatched-db

# Check health status
docker inspect --format='{{.State.Health.Status}}' laymatched-web
```

Common causes:
- Database not ready: API depends on healthy DB (wait longer)
- GHCR auth expired: Re-run with valid token
- Port conflict: Ensure 80, 8080, 5432, 8000 are free

### Browser Cannot Connect / Port 80
```bash
# Check Nginx
systemctl status nginx
nginx -t
curl -I http://127.0.0.1:8080  # Should return 200 from Web container
curl -I http://<SERVER_IP>      # Should return 200 via Nginx
```

- Verify AWS Security Group allows inbound TCP 80 (and 443 for future HTTPS)
- Check Nginx is running and `laymatched` site is enabled in `/etc/nginx/sites-enabled/`

### Login Failure
```
Invalid credentials
```
- Verify AUTH_USERNAME and AUTH_PASSWORD_HASH in `/opt/laymatched/.env`
- Password hash must be valid PBKDF2-SHA256 with 600,000 iterations
- The installer generates this correctly; corruption only occurs if .env is manually edited

## Recovery Guidance

| Scenario | Recovery |
|----------|----------|
| Config lost | Re-run `install.sh` with same credentials; data volumes persist |
| Container crash | `docker compose -f /opt/laymatched/docker-compose.yml restart` |
| Nginx broken | Re-run `install.sh` (Nginx phase is idempotent) |
| Version rollback | `cd /opt/laymatched && sudo ./update.sh <previous_version>` |
| Full reset | `docker compose -f /opt/laymatched/docker-compose.yml down -v` then re-run `install.sh` |

## Known Limitations / Pre-Launch Items

1. **GHCR Token Required**: Customers must provide a valid GHCR token. Future: licence-based auth.
2. **Manual Version Selection**: Installer prompts for version. Future: auto-select approved release.
3. **HTTP Only**: External access is HTTP on port 80. HTTPS and custom hostnames (`nickname.app.laymatched.co.uk`) coming soon.
4. **No Automatic Backups**: PostgreSQL data in Docker volume; implement backup strategy for production.
5. **Single-Server Only**: No clustering or HA configuration.

## Security Notes

- All secrets generated independently (never derived from GHCR token)
- `.env` permissions: 600, owned by root
- Database, API, and Docker daemon never exposed publicly
- Nginx acts as reverse proxy with security headers
- Passwords stored as PBKDF2-SHA256 hashes (600k iterations)

## Development

Implementation work is tracked through GitHub issues. Changes should be developed on feature branches and reviewed before merging to `main`.

See Issue #1 for the initial one-step Ubuntu installer specification.