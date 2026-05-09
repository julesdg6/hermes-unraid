# Changelog

## Unreleased

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
