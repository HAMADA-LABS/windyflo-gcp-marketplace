# Patched Postgres for the GCP Marketplace plain data layer. Official image + OS security updates.
# gosu (Go binary with old stdlib CVEs) is only used by the entrypoint when started as root; the chart
# runs the container as non-root, so it is removed to keep the image free of that finding.
FROM postgres:16-alpine
RUN apk upgrade --no-cache && rm -f /usr/local/bin/gosu
