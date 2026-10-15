#!/bin/sh
# Container PID-1 payload (runs under tini).
#
# codebase-memory-mcp has no foreground daemon mode: `daemon start` detaches a
# permanent daemon and returns. MCP clients reach that daemon by running
# `codebase-memory-mcp` (stdio) inside this container via `docker exec`.
#
# This script keeps the container's lifetime tied to the daemon's:
#   - starts the permanent daemon (with the CBM Lens UI),
#   - forwards CBM_UI_PUBLISH_PORT -> 127.0.0.1:CBM_UI_PORT, because the UI
#     only ever binds loopback and a published port cannot reach loopback,
#   - exits non-zero if the daemon dies (so `restart:` brings it back),
#   - on SIGTERM asks the daemon to stop cleanly before falling back to signals,
#   - if CBM_HTTP_PORT is set, serves MCP over Streamable HTTP (/mcp) and SSE
#     (/sse) through mcp-proxy, for clients that can't spawn a local process.
#
# Any arguments are run instead (e.g. `docker compose run --rm cbm --version`).
set -eu

BIN=codebase-memory-mcp

if [ "$#" -gt 0 ]; then
    case "$1" in
        -*|cli|daemon|config|update|install|uninstall) exec "$BIN" "$@" ;;
        *) exec "$@" ;;
    esac
fi

: "${CBM_UI_PORT:=9749}"
: "${CBM_UI_PUBLISH_PORT:=19749}"
: "${CBM_HEALTH_INTERVAL:=10}"
: "${CBM_STOP_TIMEOUT:=20}"

log() { printf 'cbm-entrypoint: %s\n' "$*" >&2; }

mkdir -p "${CBM_CACHE_DIR:-$HOME/.cache/codebase-memory-mcp}" 2>/dev/null || {
    log "cannot write ${CBM_CACHE_DIR:-$HOME/.cache/codebase-memory-mcp} as uid $(id -u):$(id -g)."
    log "fix ownership of the /data volume or the CBM_UID/CBM_GID setting."
    exit 1
}

daemon_pid() {
    "$BIN" daemon status 2>/dev/null | sed -n 's/^ *pid: *\([0-9][0-9]*\).*/\1/p' | head -n1
}

DAEMON_PID=""
FWD_PID=""
HTTP_PID=""

# One long-lived stdio session, shared by every HTTP client. Its working
# directory is only the session root; tools take explicit repo_path/project.
MCP_PROXY=/opt/mcp-proxy/bin/mcp-proxy
start_http() {
    [ -n "${CBM_HTTP_PORT:-}" ] || return 0
    # A missing bridge is a stale image, not a transient fault: say so once
    # and keep the rest of the container running instead of a restart loop.
    if ! "$MCP_PROXY" --version >/dev/null 2>&1; then
        log "CBM_HTTP_PORT is set but $MCP_PROXY does not run: this image predates"
        log "the HTTP bridge. Rebuild: docker compose -f docker/compose.yaml up -d --build"
        CBM_HTTP_PORT=""
        return 0
    fi
    if [ ! -d "${CBM_HTTP_CWD:-/}" ]; then
        log "CBM_HTTP_CWD=${CBM_HTTP_CWD} is not a directory in the container; using /"
        CBM_HTTP_CWD=/
    fi
    "$MCP_PROXY" --host 0.0.0.0 --port "$CBM_HTTP_PORT" \
        --cwd "${CBM_HTTP_CWD:-/}" --pass-environment -- "$BIN" &
    HTTP_PID=$!
    log "MCP over HTTP on :$CBM_HTTP_PORT (/mcp streamable, /sse), session root ${CBM_HTTP_CWD:-/}"
}

shutdown() {
    trap '' TERM INT
    log "stopping"
    [ -n "$FWD_PID" ] && kill "$FWD_PID" 2>/dev/null || true
    [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null || true

    # A clean stop lets the daemon flush SQLite and cancel index workers. It
    # refuses while MCP sessions are attached; those die with the container
    # anyway, so terminate them and retry until the deadline.
    deadline=$(( $(date +%s) + CBM_STOP_TIMEOUT ))
    while [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; do
        if ! "$BIN" daemon stop >/dev/null 2>&1; then
            # Frontend sessions are every CBM process except the daemon itself.
            # (-f: the 19-char name exceeds the kernel's 15-char comm field.)
            for p in $(pgrep -f "$BIN" 2>/dev/null || true); do
                [ "$p" = "$DAEMON_PID" ] || kill -TERM "$p" 2>/dev/null || true
            done
        fi
        [ "$(date +%s)" -ge "$deadline" ] && break
        sleep 1
    done
    if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
        log "daemon did not stop within ${CBM_STOP_TIMEOUT}s; sending SIGTERM"
        kill -TERM "$DAEMON_PID" 2>/dev/null || true
        sleep 3
        kill -KILL "$DAEMON_PID" 2>/dev/null || true
    fi
    exit 0
}
trap shutdown TERM INT

"$BIN" --version >&2 || true
if ! "$BIN" daemon start --port="$CBM_UI_PORT" >&2; then
    log "daemon start failed; logs: ${CBM_CACHE_DIR:-$HOME/.cache/codebase-memory-mcp}/logs"
    exit 1
fi
DAEMON_PID=$(daemon_pid)
if [ -z "$DAEMON_PID" ]; then
    log "daemon reported started but is not answering"
    exit 1
fi
log "daemon pid $DAEMON_PID; UI forwarded on :$CBM_UI_PUBLISH_PORT -> 127.0.0.1:$CBM_UI_PORT"

# TCP-level forward: Host/Origin headers pass through untouched, so the UI's
# DNS-rebinding guard still applies (only localhost:PORT / 127.0.0.1:PORT
# are accepted — which is why the host-side port must equal CBM_UI_PORT).
socat "TCP-LISTEN:${CBM_UI_PUBLISH_PORT},fork,reuseaddr" "TCP:127.0.0.1:${CBM_UI_PORT}" &
FWD_PID=$!
start_http

# `sleep & wait` keeps the shell interruptible so SIGTERM is handled promptly.
while :; do
    sleep "$CBM_HEALTH_INTERVAL" &
    wait $! || true
    if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
        log "daemon (pid $DAEMON_PID) exited; stopping container"
        kill "$FWD_PID" 2>/dev/null || true
        [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null || true
        exit 1
    fi
    if [ -n "$HTTP_PID" ] && ! kill -0 "$HTTP_PID" 2>/dev/null; then
        log "HTTP bridge exited; restarting it"
        start_http
    fi
    if ! kill -0 "$FWD_PID" 2>/dev/null; then
        log "UI forwarder exited; restarting it"
        socat "TCP-LISTEN:${CBM_UI_PUBLISH_PORT},fork,reuseaddr" "TCP:127.0.0.1:${CBM_UI_PORT}" &
        FWD_PID=$!
    fi
done