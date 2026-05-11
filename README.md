# Hermes Suite for Unraid

Hermes Suite packages **Hermes Agent**, **Hermes Dashboard**, and **Hermes WebUI** into one Unraid-friendly container image so you can install a single Community App instead of managing three linked containers and a shared Docker volume.

## Installing on Unraid

### Unraid 7 (current)

Unraid 7 no longer auto-discovers Community Applications templates from GitHub URL entries the same way as v6. The recommended method is to `curl` the template directly into your user-templates folder and then use the **Add Container** screen in the Docker tab.

Run the following in the Unraid terminal (or via SSH):

```bash
curl -L https://raw.githubusercontent.com/julesdg6/hermes-unraid/main/unraid/hermes-suite.xml \
  -o /boot/config/plugins/dockerMan/templates-user/hermes-suite.xml
```

After the download completes, go to **Docker → Add Container** in the Unraid web UI, click **Select a template**, and choose **hermes-suite** from the list.

### Unraid 6

On Unraid 6 with the Community Applications plugin installed, paste the template URL into the **Template URL** field under **Apps → Install Application → Add custom template**:

```
https://raw.githubusercontent.com/julesdg6/hermes-unraid/main/unraid/hermes-suite.xml
```

Then click **Apply** and configure the container as normal.

## Why this image exists

The existing three-container setup works, but it depends on startup order and a shared `/opt/hermes` Docker named volume. This repository removes that extra moving part by extending the official `nousresearch/hermes-agent:latest` image and layering the latest `ghcr.io/nesquena/hermes-webui:latest` application files into the same container.

That keeps the upstream Hermes Agent runtime intact while still preserving the Unraid-compatible paths, ports, and variables people already use.

## What the container does

On startup the container:

- bootstraps `HERMES_HOME` if it is empty
- reuses your existing Hermes data directory without overwriting user data
- starts the Hermes Agent gateway on port `8642`
- starts the Hermes Dashboard on port `9119`
- starts Hermes WebUI on port `8787`
- sends logs for all three services to container stdout/stderr
- fails fast if any service exits during startup

## Default ports

- Gateway: `8642`
- Dashboard: `9119`
- WebUI: `8787`

Access them at:

- WebUI: <http://server-ip:8787>
- Dashboard: <http://server-ip:9119>
- Gateway: <http://server-ip:8642>

## Default paths

- Hermes data: `/home/hermes/.hermes`
- Persisted SSH keys: `/home/hermes/.hermes/.ssh` (available at `/home/hermes/.ssh`)
- Persisted user launcher scripts: `/home/hermes/.hermes/bin` (included in `PATH`)
- WebUI workspace: `/home/hermeswebui/workspace`
- WebUI state/config/cache: `/home/hermeswebui/.hermes/webui`
- Hermes install (internal): `/opt/hermes`

Recommended Unraid host paths:

- `/mnt/user/appdata/hermes-agent/hermes-home` -> `/home/hermes/.hermes`
- `/mnt/user/appdata/hermes-agent/workspace` -> `/home/hermeswebui/workspace`

The `/opt/hermes` install path is kept internally by the image. The legacy `hermes_shared_volume` mapping is compatibility-only and experimental. It is usually the Hermes source/runtime tree, not guaranteed user config. Leave that field blank for fresh installs.

## Compatibility with the existing three-template setup

This container is designed to preserve compatibility with mmartial's Hermes templates:

- `HERMES_UID` default `99`
- `HERMES_GID` default `100`
- `WANTED_UID` default `99`
- `WANTED_GID` default `100`
- `HERMES_HOME` default `/home/hermes/.hermes`
- gateway port `8642`
- dashboard port `9119`
- webui port `8787`
- existing Hermes home path `/mnt/user/appdata/hermes-agent/hermes-home`
- existing workspace path `/mnt/user/appdata/hermes-agent/workspace`

The old named shared volume mounted at `/opt/hermes` is supported only as an optional experimental compatibility path. In many installs it is only Hermes source/runtime content, not user data. Do not assume `/opt/hermes` or `hermes_shared_volume` contains your user config.

## Migration from the three-container setup

### Migration warning

Hermes Suite is currently safest for fresh installs.

Migration from the older three-container setup is experimental. The old templates used a mix of appdata folders and Docker named volumes. Depending on install history, your real user data may be in a different location than expected.

Before migrating, back up all Hermes-related appdata and volumes. Do not delete your old containers, appdata, or Docker volumes until you have confirmed Hermes Suite is reading your previous config, sessions, kanban database, settings, memory, and workspace.

The legacy `/opt/hermes` mapping is for compatibility only. It is not guaranteed to contain your user config. In many installs, `/opt/hermes` is only the Hermes source/runtime tree.

Do **not**:

- delete old Hermes containers, appdata folders, or Docker volumes before backup and verification
- run `rm -rf` against any Hermes appdata path during migration
- assume `/opt/hermes` contains your user data
- assume `hermes_shared_volume` contains your user config

### Safe backup commands

```bash
mkdir -p /mnt/user/backups/hermes-migration-$(date +%F)
cp -a /mnt/user/appdata/hermes-agent /mnt/user/backups/hermes-migration-$(date +%F)/ 2>/dev/null || true
cp -a /mnt/user/appdata/hermes-dashboard /mnt/user/backups/hermes-migration-$(date +%F)/ 2>/dev/null || true
cp -a /mnt/user/appdata/hermes-webui /mnt/user/backups/hermes-migration-$(date +%F)/ 2>/dev/null || true
docker run --rm -v hermes_shared_volume:/old -v /mnt/user/backups/hermes-migration-$(date +%F):/backup alpine sh -c "cp -a /old /backup/hermes_shared_volume" 2>/dev/null || true
```

### Verification commands

```bash
find /mnt/user/appdata -iname 'config.yaml' -o -iname 'kanban.db' -o -iname 'state.db'
docker volume ls | grep hermes
docker inspect HermesSuite --format '{{range .Mounts}}{{println .Type "|" .Source "|" .Destination}}{{end}}'
```

### Migration steps

1. Stop the old **Hermes Agent**, **Hermes Dashboard**, and **Hermes WebUI** containers.
2. Leave `/mnt/user/appdata/hermes-agent/hermes-home` in place.
3. Leave `/mnt/user/appdata/hermes-agent/workspace` in place.
4. Install **Hermes Suite** and point it at those same two host paths.
5. Keep `HERMES_UID`, `HERMES_GID`, `WANTED_UID`, and `WANTED_GID` aligned unless you have a specific reason not to.
6. Keep the legacy `/opt/hermes` field blank unless you have already backed up and verified that you need it.
7. Start the new container and verify ports `8642`, `9119`, and `8787` respond.

## Security warning

Hermes Dashboard and Hermes WebUI may expose sensitive settings and API key configuration.

Do **not** expose them directly to the public internet unless you put them behind strong authentication.

Safer options:

- LAN-only access
- Tailscale
- a VPN
- a reverse proxy with authentication in front of the app

Hermes Agent now requires an API key for non-loopback gateway binding on current upstream builds. Hermes Suite will generate and persist one automatically in `HERMES_HOME/api-server.key` if you do not provide `API_SERVER_KEY` yourself.

## Running Hermes CLI inside the container

To open a shell:

```bash
docker exec --user 99:100 -it Hermes-Suite bash
```

To run the Hermes CLI inside the container:

```bash
hermes model
hermes doctor
hermes chat
```

## Updating

GitHub Actions in this repository publish image tags to GHCR using:

- `latest`
- `YYYY.MM.DD`
- git SHA tags

The repo also includes workflows for:

- manual builds
- scheduled daily rebuilds
- push-triggered builds
- upstream digest checks for `nousresearch/hermes-agent:latest`
- upstream digest checks for `ghcr.io/nesquena/hermes-webui:latest`
- Unraid template validation
- optional Trivy scanning

## Smoke testing

A basic smoke test script is included:

```bash
./scripts/smoke-test.sh
```

It builds the image, starts a container, checks all three ports, and verifies the gateway, dashboard, and WebUI endpoints.

## Known limitations

- The combined image targets `linux/amd64` first, which is the primary Unraid target.
- `WANTED_UID` and `WANTED_GID` are accepted for compatibility, but the combined container runs the suite with the Hermes runtime user, so keep them aligned with `HERMES_UID` and `HERMES_GID`.
- Dashboard and WebUI internal ports should stay at their defaults unless you also update the matching container port mappings.

## How to report issues

- Container, template, workflow, or packaging issues: <https://github.com/julesdg6/hermes-unraid/issues>
- Upstream Hermes Agent issues: <https://github.com/NousResearch/hermes-agent/issues>
- Upstream Hermes WebUI issues: <https://github.com/nesquena/hermes-webui/issues>
