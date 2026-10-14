FROM nginx:1.27-alpine
 
RUN apk add --no-cache openssl
 
COPY --chmod=755 10-self-signed-cert.sh /docker-entrypoint.d/10-self-signed-cert.sh
 
