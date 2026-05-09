# syntax=docker/dockerfile:1.7
FROM ghcr.io/nesquena/hermes-webui:latest AS webui_source
FROM nousresearch/hermes-agent:latest

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
USER root

ARG BUILD_DATE
ARG VCS_REF
ARG VERSION=latest
ARG HERMES_AGENT_SOURCE=nousresearch/hermes-agent:latest
ARG HERMES_WEBUI_SOURCE=ghcr.io/nesquena/hermes-webui:latest
ARG HERMES_AGENT_DIGEST=unknown
ARG HERMES_WEBUI_DIGEST=unknown
ARG HERMES_AGENT_COMMIT=unknown
ARG HERMES_WEBUI_COMMIT=unknown

LABEL org.opencontainers.image.title="Hermes Suite"
LABEL org.opencontainers.image.description="Single-container Hermes Agent, Dashboard, and WebUI image for Unraid"
LABEL org.opencontainers.image.source="https://github.com/julesdg6/hermes-unraid"
LABEL org.opencontainers.image.url="https://github.com/julesdg6/hermes-unraid"
LABEL org.opencontainers.image.documentation="https://github.com/julesdg6/hermes-unraid/blob/main/README.md"
LABEL org.opencontainers.image.version="$VERSION"
LABEL org.opencontainers.image.revision="$VCS_REF"
LABEL org.opencontainers.image.created="$BUILD_DATE"
LABEL io.hermes.agent.source="$HERMES_AGENT_SOURCE"
LABEL io.hermes.agent.digest="$HERMES_AGENT_DIGEST"
LABEL io.hermes.agent.commit="$HERMES_AGENT_COMMIT"
LABEL io.hermes.webui.source="$HERMES_WEBUI_SOURCE"
LABEL io.hermes.webui.digest="$HERMES_WEBUI_DIGEST"
LABEL io.hermes.webui.commit="$HERMES_WEBUI_COMMIT"

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates locales rsync \
    && rm -rf /var/lib/apt/lists/*

RUN localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8

RUN if ! getent group hermeswebui >/dev/null; then groupadd -g 10001 hermeswebui; fi \
    && if ! id -u hermeswebui >/dev/null 2>&1; then useradd -u 10001 -d /home/hermeswebui -g hermeswebui -G users -s /bin/bash -m hermeswebui; fi \
    && mkdir -p /opt/hermes-webui /home/hermeswebui/workspace /home/hermes/.hermes \
    && touch /.within_container

COPY --from=webui_source /apptoo/ /opt/hermes-webui/
COPY docker/entrypoint.sh /usr/local/bin/hermes-suite-entrypoint
COPY docker/healthcheck.sh /usr/local/bin/hermes-suite-healthcheck

RUN chmod 755 /usr/local/bin/hermes-suite-entrypoint /usr/local/bin/hermes-suite-healthcheck \
    && source /opt/hermes/.venv/bin/activate \
    && uv pip install --python /opt/hermes/.venv/bin/python -r /opt/hermes-webui/requirements.txt \
    && chown -R hermes:hermes /home/hermes /home/hermeswebui /opt/hermes-webui

# Create a reference copy of /opt/hermes for migration compatibility.
# If a user mounts the legacy hermes_shared_volume at /opt/hermes, the entrypoint
# uses this bundle to seed the mounted volume with the current Hermes install.
RUN touch /opt/hermes/.hermes-suite-bundled \
    && cp -a /opt/hermes /opt/hermes.image-bundle

ENV LANG=en_US.utf8 \
    LC_ALL=C \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HERMES_HOME=/home/hermes/.hermes \
    HERMES_GATEWAY_URL=http://127.0.0.1:8642 \
    HERMES_WEBUI_AGENT_DIR=/opt/hermes \
    HERMES_WORKSPACE=/home/hermeswebui/workspace \
    HERMES_WEBUI_DEFAULT_WORKSPACE=/home/hermeswebui/workspace \
    HERMES_WEBUI_STATE_DIR=/home/hermeswebui/.hermes/webui \
    HERMES_WEBUI_HOST=0.0.0.0 \
    HERMES_WEBUI_PORT=8787 \
    WEBUI_HOST=0.0.0.0 \
    WEBUI_PORT=8787 \
    DASHBOARD_HOST=0.0.0.0 \
    DASHBOARD_PORT=9119

EXPOSE 8642 9119 8787

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=5 CMD ["/usr/local/bin/hermes-suite-healthcheck"]
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/hermes-suite-entrypoint"]
