# codebase-memory-mcp — container image built from source at https://github.com/DeusData/codebase-memory-mcp
#
# Stage 1 builds the native binary with CBM Lens (the web UI) embedded.
# Stage 2 creates an HTTP bridge to communicate over stdio.
# Stage 2 is a slim runtime: the binary needs no Node.js, no language runtime and no network at run time.

ARG UBUNTU_IMAGE=ubuntu:24.04
ARG NODE_IMAGE=node:22-bookworm-slim

FROM ${NODE_IMAGE} AS node

# ── build ────────────────────────────────────────────────────────────────────
FROM ${UBUNTU_IMAGE} AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc g++ make pkg-config zlib1g-dev \
        python3 git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && node --version && npm --version

WORKDIR /src
COPY . .

# Stamped into the binary (`codebase-memory-mcp --version`). Leave empty for a
# "dev" stamp, or pass e.g. --build-arg CBM_VERSION=0.11.0.
ARG CBM_VERSION=""
# Cap parallel compile jobs on small machines / Docker Desktop VMs (0 = all).
ARG BUILD_JOBS=0

# onnxruntime-node (a transitive UI dev dependency) otherwise downloads the CUDA 12 execution provider from api.nuget.org in its postinstall on linux/x64.
# The browser bundle never uses it; We don't need it. Skipping saves the download and removes a non-npm host from the build's network requirements.

ENV ONNXRUNTIME_NODE_INSTALL=skip \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

# The npm cache mount keeps repeat UI builds fast without baking it into a layer.
RUN --mount=type=cache,target=/root/.npm \
    set -eux; \
    if [ "$BUILD_JOBS" != "0" ]; then \
        # scripts/env.sh derives -j from `nproc` unconditionally; shim it.
        mkdir -p /tmp/jobs && printf '#!/bin/sh\necho %s\n' "$BUILD_JOBS" > /tmp/jobs/nproc; \
        chmod +x /tmp/jobs/nproc; export PATH="/tmp/jobs:$PATH"; \
    fi; \
    CBM_NO_CCACHE=1 scripts/build.sh --with-ui ${CBM_VERSION:+--version "$CBM_VERSION"}; \
    install -Dm755 build/c/codebase-memory-mcp /out/codebase-memory-mcp; \
    /out/codebase-memory-mcp --version
# streamable http server


# Streamable-HTTP bridge.
ARG MCP_PROXY_VERSION=0.13.0
RUN python3 -m venv /opt/mcp-proxy \
    && /opt/mcp-proxy/bin/pip install --no-cache-dir "mcp-proxy==${MCP_PROXY_VERSION}" \
    && /opt/mcp-proxy/bin/mcp-proxy --version

COPY --from=build /out/codebase-memory-mcp /usr/local/bin/codebase-memory-mcp
COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/cbm-entrypoint
 

# Runtime 
FROM ${UBUNTU_IMAGE} AS runtime

# Installs:
# zlib1g, libstdc++6: the binary's shared-library dependencies besides libc.
# git:    the watcher and change detection shell out to it.
# socat:  forwards the published UI port to the loopback-only UI listener.
# tini:   PID 1 reaps the detached daemon and index workers, forwards signals.
# procps: pgrep, used by the entrypoint's shutdown path.

RUN apt-get update && apt-get install -y --no-install-recommends zlib1g libstdc++6 git socat tini procps ca-certificates && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/codebase-memory-mcp /usr/local/bin/codebase-memory-mcp
COPY --chmod=755 entrypoint.sh /usr/local/bin/cbm-entrypoint

ENV HOME=/data \
    CBM_CACHE_DIR=/data/cache \
    CBM_UI_PORT=9749 \
    CBM_UI_PUBLISH_PORT=19749

# Mounted repositories are owned by the host user, not the container user; without this every git call will return the infamous "dubious ownership" warning.

RUN git config --system --add safe.directory '*' \
    && mkdir -p /data && chmod 1777 /data

VOLUME ["/data"]
EXPOSE 19749

ENTRYPOINT ["/usr/bin/tini", "--", "cbm-entrypoint"]
