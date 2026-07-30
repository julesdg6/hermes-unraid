# Changelog

## Unreleased

- Fixed dashboard unreachable on port 9119: changed `DASHBOARD_HOST` default from `127.0.0.1` (loopback-only) to `0.0.0.0` so the dashboard accepts connections forwarded through Docker's port mapping. Previously the dashboard bound only to the container's loopback interface, making port 9119 inaccessible from the host or LAN even when correctly mapped.

- Container healthcheck now verifies all three services — gateway (`/health`), dashboard (port 9119), and WebUI (`/health`) — so the container is marked unhealthy and eligible for restart if the dashboard or WebUI goes down after initial startup. Previously only the gateway was monitored, allowing port 9119 to remain closed without Docker detecting the failure.
- Entrypoint dashboard readiness check now includes HTTP basic-auth credentials when `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` and `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` are set, preventing the startup health check from timing out (and killing the whole container) when basic auth is enabled on the dashboard.
- Unraid template now exposes `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` and `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` as optional advanced config variables so users can enable HTTP basic auth on the dashboard directly from the Community Applications UI.

- Added debugging utilities (`nano`, `less`, `procps`, `iproute2`, `curl`) to the container image for easier in-container inspection and emergency recovery.
- Virtual environment now includes `pip`, `setuptools`, and `wheel`, enabling manual package installation (e.g. `pip install python-telegram-bot`) without needing system Python or ensurepip.
- Image build now installs `python-telegram-bot` into `/opt/hermes/.venv` by default, and entrypoint startup still auto-recovers missing installs when Telegram is configured via environment, `.env`, or `config.yaml`.
- Entrypoint now emits an explicit warning when `config.yaml` ownership cannot be fixed, so users are alerted instead of silently falling back to `.env` values.
- Suppressed gateway "No user allowlists configured" startup warning by defaulting `GATEWAY_ALLOW_ALL_USERS=true` in the generated `.env`. Override with `-e GATEWAY_ALLOW_ALL_USERS=false` and set platform allowlists if you need per-user access control.
- Suppressed gateway "SQLite session store unavailable, falling back to JSONL: database is locked" startup warnings by: (1) removing stale SQLite WAL/journal files (`state.db-wal`, `state.db-shm`, `state.db-journal`) on container start to handle unclean-shutdown restarts, and (2) starting the gateway first and waiting for it to become ready before launching the dashboard, so the gateway initialises its SQLite database before the dashboard also tries to open it.

## 2026-05-09 (2)

- Added legacy `hermes_shared_volume` mount support for `/opt/hermes` migration compatibility.
- Dockerfile now stores an image bundle at `/opt/hermes.image-bundle` and a sentinel file at `/opt/hermes/.hermes-suite-bundled` to support seeding externally-mounted volumes.
- Entrypoint now detects when `/opt/hermes` is externally mounted and automatically seeds it from the image bundle on startup.
- Unraid template now includes an optional advanced Docker named volume config for `/opt/hermes` (Hermes Shared Source Volume - Legacy Migration).
- Updated README migration notes and default paths section to reflect the optional `hermes_shared_volume` mapping.

## 2026-05-09

- Added README section explaining Unraid 7 curl-based template installation and Unraid 6 Community Applications method.
- Added the first Hermes Suite combined container image for Unraid.
- Added a startup supervisor that launches Hermes Agent, Hermes Dashboard, and Hermes WebUI together.
- Added Unraid Community Applications XML for the combined app.
- Added smoke tests, template validation, GHCR publishing workflows, upstream rebuild checks, and Trivy scanning.
