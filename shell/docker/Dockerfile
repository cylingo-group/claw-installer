# Bare Ubuntu 24.04 base — no Node/pnpm/fnm preinstalled.
# Mimics a fresh machine; install-openclaw.sh must bring all deps itself.
#
# Install runs at BUILD time so iterations of the gateway/test layer are fast.
# Re-test the installer end-to-end with: docker compose build --no-cache
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/root \
    INSTALLER_AGENTS=openclaw \
    INSTALLER_SERVICE_MODE=skip \
    INSTALLER_GATEWAY_BIND=lan \
    INSTALLER_GATEWAY_PORT=18789 \
    INSTALLER_NPM_REGISTRY=https://registry.npmmirror.com

WORKDIR /opt/installer

# Build context is the `installer/` directory (see docker-compose.yml).
COPY install.sh install-openclaw.sh install-hermes.sh /opt/installer/
COPY lib /opt/installer/lib
COPY steps /opt/installer/steps
COPY vendor /opt/installer/vendor
COPY docker/docker-entrypoint.sh /opt/installer/docker-entrypoint.sh

RUN chmod +x /opt/installer/install.sh \
              /opt/installer/install-openclaw.sh \
              /opt/installer/steps/*.sh \
              /opt/installer/docker-entrypoint.sh \
 && /opt/installer/install.sh

EXPOSE 18789

CMD ["/opt/installer/docker-entrypoint.sh"]
