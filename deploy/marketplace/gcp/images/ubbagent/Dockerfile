# Google's usage-based billing agent (ubbagent), built from upstream source on the CURRENT Go toolchain.
# Needed by the usage-based (paid) listing. Google publishes gcr.io/cloud-marketplace-tools/metering/
# ubbagent, but each release is built on a Go that is usually already one patch behind, and Marketplace's
# CHECK_PACKAGE_VULNERABILITIES flags GO_STDLIB findings in every declared image (0.2.15 and 0.2.17 both
# trip it). Same layout/entrypoint as the official image: /usr/local/bin/ubbagent + ubbagent-start.
# UBBAGENT_VERSION is an upstream git tag (https://github.com/GoogleCloudPlatform/ubbagent/tags).
ARG UBBAGENT_VERSION=0.2.17
FROM golang:1-alpine AS build
ARG UBBAGENT_VERSION
RUN apk add --no-cache git
WORKDIR /src
RUN git clone --depth 1 --branch ${UBBAGENT_VERSION} https://github.com/GoogleCloudPlatform/ubbagent.git .
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/ubbagent .

FROM alpine:3
RUN apk upgrade --no-cache \
    && apk add --no-cache ca-certificates libintl \
    && apk add --no-cache --virtual build_deps gettext \
    && cp /usr/bin/envsubst /usr/local/bin/envsubst \
    && apk del build_deps
COPY --from=build /out/ubbagent /usr/local/bin/ubbagent
COPY --from=build /src/docker/ubbagent-start /usr/local/bin/ubbagent-start
RUN chmod 0755 /usr/local/bin/ubbagent-start
CMD ["/usr/local/bin/ubbagent-start"]
