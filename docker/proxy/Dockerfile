# TLS reverse proxy in front of CBM Lens. Configured entirely from the environment (see docker/.env.example):
# the startup scripts below generate the certificate, Origin allowlist and auth from PROXY_HOSTS / PROXY_PORT / PROXY_AUTH_*,
# and the stock nginx entrypoint renders default.conf.template with envsubst.
FROM nginx:1.27-alpine

RUN apk add --no-cache openssl

# Only substitute our own variables, so nginx's $host, $http_origin, ... survive envsubst.
ENV NGINX_ENVSUBST_FILTER="^(CBM_|PROXY_)" \
    CBM_UI_PORT=9749 \
    PROXY_PORT=8443

# The stock entrypoint runs /docker-entrypoint.d/* in order; 20-envsubst-on-templates.sh renders the template after these.
COPY --chmod=755 10-self-signed-cert.sh 15-cbm-proxy-conf.sh /docker-entrypoint.d/
COPY default.conf.template /etc/nginx/templates/default.conf.template

EXPOSE 8443
