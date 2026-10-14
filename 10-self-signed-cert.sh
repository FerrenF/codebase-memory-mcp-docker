#!/bin/sh
set -eu

dir="${PROXY_CERT_DIR:-/etc/nginx/certs}"
crt="$dir/fullchain.pem"
key="$dir/privkey.pem"
me="10-self-signed-cert"

if [ -s "$crt" ] && [ -s "$key" ]; then
    echo "$me: using existing certificate in $dir"
    exit 0
fi
if [ -e "$crt" ] || [ -e "$key" ]; then
    echo "$me: missing one of fullchain.pem / privkey.pem in $dir;" >&2
    exit 1
fi

cn="${PROXY_CERT_CN:?set PROXY_CERT_CN (the hostname or IP people will type)}"
sans="${PROXY_CERT_SANS:-DNS:$cn}"

mkdir -p "$dir"
umask 077
openssl req -x509 -newkey rsa:2048 -nodes -days "${PROXY_CERT_DAYS:-825}" \
    -keyout "$key.tmp" -out "$crt.tmp" \
    -subj "/CN=$cn" -addext "subjectAltName=$sans" 2>/dev/null
chmod 644 "$crt.tmp"
mv "$key.tmp" "$key"
mv "$crt.tmp" "$crt"

echo "$me: generated self-signed certificate for $sans"
openssl x509 -in "$crt" -noout -enddate -fingerprint -sha256 | sed "s/^/$me: /"