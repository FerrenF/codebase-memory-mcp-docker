#!/bin/sh
# Writes the parts of the nginx config that envsubst cannot express (lists and on/off switches) into /etc/nginx/cbm/:
#   origins.map  every https://<PROXY_HOSTS entry>:<PROXY_PORT> origin, rewritten to the loopback origin CBM Lens accepts.
#   auth.conf    basic auth when PROXY_AUTH_USER and PROXY_AUTH_PASSWORD are set, otherwise off.
set -eu

out=/etc/nginx/cbm
me="15-cbm-proxy-conf"
port="${PROXY_PORT:-8443}"
lens="http://localhost:${CBM_UI_PORT:-9749}"

mkdir -p "$out"

# Only listed origins are rewritten. Anything else reaches CBM unchanged and is rejected by its DNS-rebinding guard.
{
    for h in localhost 127.0.0.1 $(printf '%s' "${PROXY_HOSTS:-}" | tr ',' ' '); do
        case "$h" in *:*) h="[$h]" ;; esac
        printf '"https://%s:%s" "%s";\n' "$h" "$port" "$lens"
        if [ "$port" = 443 ]; then printf '"https://%s" "%s";\n' "$h" "$lens"; fi
    done
} > "$out/origins.map"
echo "$me: allowing origins $(cut -d'"' -f2 "$out/origins.map" | tr '\n' ' ')"

if [ -n "${PROXY_AUTH_USER:-}" ] && [ -n "${PROXY_AUTH_PASSWORD:-}" ]; then
    printf '%s:%s\n' "$PROXY_AUTH_USER" "$(printf '%s\n' "$PROXY_AUTH_PASSWORD" | openssl passwd -apr1 -stdin)" > "$out/htpasswd"
    chmod 640 "$out/htpasswd"
    chgrp nginx "$out/htpasswd"
    printf 'auth_basic "codebase-memory";\nauth_basic_user_file %s/htpasswd;\n' "$out" > "$out/auth.conf"
    echo "$me: basic auth enabled for $PROXY_AUTH_USER"
else
    echo 'auth_basic off;' > "$out/auth.conf"
fi
