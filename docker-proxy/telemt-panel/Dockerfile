FROM debian:12-slim

ARG TARGETARCH
ARG TELEMT_PANEL_REPOSITORY=amirotin/telemt_panel
ARG TELEMT_PANEL_VERSION=latest

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl tar; \
    rm -rf /var/lib/apt/lists/*; \
    case "${TARGETARCH:-amd64}" in \
      amd64) asset_arch="x86_64" ;; \
      arm64) asset_arch="aarch64" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH:-}" >&2; exit 1 ;; \
    esac; \
    if [ "$TELEMT_PANEL_VERSION" = "latest" ]; then \
      release_url="https://github.com/${TELEMT_PANEL_REPOSITORY}/releases/latest/download/telemt-panel-${asset_arch}-linux-gnu.tar.gz"; \
    else \
      release_url="https://github.com/${TELEMT_PANEL_REPOSITORY}/releases/download/${TELEMT_PANEL_VERSION}/telemt-panel-${asset_arch}-linux-gnu.tar.gz"; \
    fi; \
    curl -fsSL "$release_url" -o /tmp/telemt-panel.tar.gz; \
    mkdir -p /tmp/telemt-panel; \
    tar -xzf /tmp/telemt-panel.tar.gz -C /tmp/telemt-panel; \
    panel_bin="$(find /tmp/telemt-panel -type f \( -name telemt-panel -o -name 'telemt-panel-*' \) | head -n 1)"; \
    test -n "$panel_bin"; \
    install -m 0755 "$panel_bin" /usr/local/bin/telemt-panel; \
    test -x /usr/local/bin/telemt-panel; \
    rm -rf /tmp/telemt-panel /tmp/telemt-panel.tar.gz

EXPOSE 8080
ENTRYPOINT ["telemt-panel"]
