# LayMatched Installer

Public installation and update tooling for **LayMatched**.

This repository is the customer-facing installer for LayMatched. It is intentionally separate from the private LayMatched application source repository and must not contain proprietary application source code, credentials, API keys, passwords, private keys, or customer-specific configuration.

## Architecture

The installer deploys LayMatched using three Docker services:

| Service | Image | Port | Description |
|---------|-------|------|-------------|
| **db** | `postgres:17-alpine` | `127.0.0.1:5432:5432` | PostgreSQL database (`laymatched_betting`) |
| **api** | `ghcr.io/ibettison/laymatched-api:<version>` | `127.0.0.1:8000:8000` | Python FastAPI backend with PBKDF2 auth |
| **web** | `ghcr.io/ibettison/laymatched-web:<version>` | `127.0.0.1:${APP_PORT:-8080}:80` | React+Nginx frontend |

All ports are bound to `127.0.0.1` only (private/loopback-only configuration). The API and Web images are versioned private releases pulled from GitHub Container Registry.

## Installation

The target installation process for a fresh supported Ubuntu server is:

```bash
git clone https://github.com/ibettison/laymatched-install.git
cd laymatched-install
sudo ./install.sh
```

The installer will:
1. Validate the Ubuntu release (20.04, 22.04, 24.04)
2. Install Docker Engine if needed
3. Collect configuration (GHCR token, app version)
4. Generate database and app secrets
5. Authenticate to GitHub Container Registry
6. Generate the docker-compose.yml
7. Pull and start services
8. Perform health checks

## Updating

The intended update process is:

```bash
cd laymatched-install
git pull
sudo ./update.sh
```

Updates preserve customer configuration and persistent application data (`postgres_data`, `bookmaker_icon_cache` volumes).

## Security

- Never commit secrets to this repository. Customer credentials and configuration containing secrets must be stored outside Git with restrictive permissions.
- All ports are bound to `127.0.0.1` only - databases, internal APIs, and backend services are not exposed to the public internet.
- GHCR token is used for registry authentication only; generated app secrets (POSTGRES_PASSWORD, AUTH_PASSWORD_HASH, etc.) are independently generated.
- `.env` file stored at `/opt/laymatched/.env` has permissions 600, owned by root:root.
- Persistent Docker volumes (postgres_data, bookmaker_icon_cache) are preserved during updates.

## Development

Implementation work is tracked through GitHub issues. Changes should be developed on feature branches and reviewed before merging to `main`.

See Issue #1 for the initial one-step Ubuntu installer specification.