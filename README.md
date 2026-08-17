# LayMatched Installer

Public installation and update tooling for **LayMatched**.

This repository is the customer-facing installer for LayMatched. It is intentionally separate from the private LayMatched application source repository and must not contain proprietary application source code, credentials, API keys, passwords, private keys, or customer-specific configuration.

## Status

The installer is currently under development. Do not use it for a production installation until a tested release is published.

## Intended installation

The target installation process for a fresh supported Ubuntu server is:

```bash
git clone https://github.com/ibettison/laymatched-install.git
cd laymatched-install
sudo ./install.sh
```

The installer will prepare the host, install the required runtime dependencies, obtain the appropriate LayMatched release, configure its services, and perform post-install health checks.

## Updating

The intended update process is:

```bash
cd laymatched-install
git pull
sudo ./update.sh
```

Updates must preserve customer configuration and persistent application data.

## Security

Never commit secrets to this repository. Customer credentials and configuration containing secrets must be stored outside Git with restrictive permissions.

The installer must not expose databases, internal APIs, the Docker daemon, or other backend services directly to the public internet.

## Development

Implementation work is tracked through GitHub issues. Changes should be developed on feature branches and reviewed before merging to `main`.

See Issue #1 for the initial one-step Ubuntu installer specification.
