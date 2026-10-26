#!/bin/sh
# Generates a self-signed certificate for every name/IP in PROXY_HOSTS, unless one is already in PROXY_CERT_DIR.
# A certificate this script made is regenerated when PROXY_HOSTS changes; one you supplied yourself is never touched.
set -eu

dir="${PROXY_CERT_DIR:-/etc/nginx/certs}"
crt="$dir/fullchain.pem"
key="$dir/privkey.pem"
stamp="$dir/.generated-for"
me="10-self-signed-cert"

hosts=$(printf '%s' "${PROXY_HOSTS:?set PROXY_HOSTS in docker/.env (the names/IPs people will type)}" | tr ',' ' ')

cn=""
sans="DNS:localhost,IP:127.0.0.1"
for h in $hosts; do
    [ -n "$cn" ] || cn="$h"
    case "$h" in
        *:*)         sans="$sans,IP:$h" ;;   # IPv6
        *[!0-9.]*)   sans="$sans,DNS:$h" ;;
        *)           sans="$sans,IP:$h" ;;
    esac
done
[ -n "$cn" ] || { echo "$me: PROXY_HOSTS is empty" >&2; exit 1; }

if [ -s "$crt" ] && [ -s "$key" ]; then
    if [ ! -f "$stamp" ]; then
        echo "$me: using your certificate in $dir"
        exit 0
    fi
    if [ "$(cat "$stamp")" = "$sans" ]; then
        echo "$me: using existing certificate in $dir"
        exit 0
    fi
    echo "$me: PROXY_HOSTS changed; regenerating"
elif [ -e "$crt" ] || [ -e "$key" ]; then
    echo "$me: missing one of fullchain.pem / privkey.pem in $dir" >&2
    exit 1
fi

mkdir -p "$dir"
umask 077
openssl req -x509 -newkey rsa:2048 -nodes -days "${PROXY_CERT_DAYS:-825}" \
    -keyout "$key.tmp" -out "$crt.tmp" \
    -subj "/CN=$cn" -addext "subjectAltName=$sans" 2>/dev/null
chmod 644 "$crt.tmp"
mv "$key.tmp" "$key"
mv "$crt.tmp" "$crt"
printf '%s' "$sans" > "$stamp"

echo "$me: generated self-signed certificate for $sans"
openssl x509 -in "$crt" -noout -enddate -fingerprint -sha256 | sed "s/^/$me: /"
