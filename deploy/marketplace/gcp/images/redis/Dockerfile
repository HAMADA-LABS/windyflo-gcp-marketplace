# Patched Redis for the GCP Marketplace plain data layer. Official image + OS security updates;
# gosu removed (see postgres/Dockerfile).
FROM redis:7-alpine
RUN apk upgrade --no-cache && rm -f /usr/local/bin/gosu
