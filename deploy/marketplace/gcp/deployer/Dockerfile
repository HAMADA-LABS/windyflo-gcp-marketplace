# GCP Marketplace deployer image — the container Cloud Marketplace runs as a Job inside the buyer's
# cluster to install WindyFlo. Built with deploy/marketplace/gcp/build-deployer.sh (do NOT `docker build`
# this directory by hand — the build context must be staged first; see that script).
#
# Contract notes, all verified against marketplace-k8s-app-tools@master source (not just the docs),
# because every one of them was violated by the previous version of this file:
#
#   • Base is `deployer_helm` — that IS the Helm 3 deployer. There is no `deployer_helm3`. Pin
#     MARKETPLACE_TOOLS_TAG: the base installs *latest* helm+kubectl at ITS build time, so `:latest`
#     silently changes the helm binary under you.
#   • The entrypoint reads NOTHING from env for chart/values discovery. HELM_CHART / HELM_VALUES
#     (what this file used to set) are not read by anything — the previous image would have shipped
#     buyers the unmodified base chart. create_manifests.sh globs `/data/chart/*.tar.gz`.
#   • `.tgz` is SILENTLY IGNORED — the glob is literally `-name "*.tar.gz"`. A .tgz produces an empty
#     manifest and a baffling "Set of resources does not include an Application" failure.
#   • The tarball's root member must be a directory named exactly `chart` (helm is invoked on
#     `<extracted>/<tarball-basename>/chart`), regardless of the tarball's filename. The `ADD` below
#     renames windyflo/ -> chart/ to satisfy this.
#   • There is NO `-f extra-values.yaml` layer. Rendering is:
#         helm template "$NAME" "$chart/chart" --values=<(print_config.py --output=yaml)
#     where print_config.py emits ONLY schema.yaml properties. So Marketplace defaults must already
#     be the chart's own values.yaml — build-deployer.sh merges values-marketplace-gcp.yaml in before
#     staging. Anything not in schema.yaml and not in the baked values.yaml simply does not apply.
#   • Subcharts must be vendored (charts/ populated). Only `helm template` runs — no repo network access.

ARG MARKETPLACE_TOOLS_TAG

FROM marketplace.gcr.io/google/c2d-debian11 AS build
# gettext-base provides envsubst (all we need); gettext pulls libicu67/libxml2 from the
# now-404 bullseye-security repo. --fix-missing prevents 404s on optional transitive deps.
RUN apt-get update \
    && apt-get install -y --no-install-recommends --fix-missing gettext-base \
    && rm -rf /var/lib/apt/lists/*

# chart/windyflo is the merged chart staged by build-deployer.sh. Destination is /tmp/chart so the
# tarball's root member is `chart/` as the deployer requires.
ADD chart/windyflo /tmp/chart
RUN cd /tmp && tar -czf /tmp/windyflo.tar.gz chart

# $REGISTRY and $TAG are the only substitutions available (the tooling runs `env -i` with just those
# two), and they are how publishedVersion + the image prefix get stamped in at build time.
ADD schema.yaml /tmp/schema.yaml
ARG REGISTRY
ARG TAG
RUN cat /tmp/schema.yaml \
    | env -i "REGISTRY=$REGISTRY" "TAG=$TAG" envsubst \
    > /tmp/schema.yaml.new \
    && mv /tmp/schema.yaml.new /tmp/schema.yaml

# helm + kubectl rebuilt from their release tags with the CURRENT Go toolchain. Google's deployer_helm
# base already ships the newest releases (helm v4.3.0, kubectl v1.37.1), but they were compiled with
# Go 1.26.8 / 1.27.1, and Marketplace's CHECK_PACKAGE_VULNERABILITIES flags GO_STDLIB < 1.26.9 / 1.27.2
# (CVE-2026-56857, CVE-2026-78663) in the deployer image. Nothing newer exists to download, so rebuild.
# Keep the two versions below equal to what the pinned base ships (check: `docker run --rm --entrypoint
# sh <base> -c 'helm version --short; /opt/kubectl/default/kubectl version --client'`).
FROM golang:1-alpine AS tools
ARG HELM_VERSION=v4.3.0
ARG KUBECTL_VERSION=v1.37.1
RUN apk add --no-cache git
WORKDIR /src
RUN git clone --depth 1 --branch ${HELM_VERSION} https://github.com/helm/helm.git helm \
    && cd helm \
    && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X helm.sh/helm/v4/internal/version.version=${HELM_VERSION}" -o /out/helm ./cmd/helm
RUN git clone --depth 1 --branch ${KUBECTL_VERSION} https://github.com/kubernetes/kubernetes.git k8s \
    && cd k8s \
    && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X k8s.io/component-base/version.gitVersion=${KUBECTL_VERSION} -X k8s.io/component-base/version.gitMajor=1 -X k8s.io/component-base/version.gitMinor=37" -o /out/kubectl ./cmd/kubectl

FROM gcr.io/cloud-marketplace-tools/k8s/deployer_helm:$MARKETPLACE_TOOLS_TAG
# Google's base ships openssl 3.0.2-0ubuntu1.29 (CVE-2026-84782, HIGH); Artifact Analysis flags it.
# Upgrade ONLY openssl so the tooling Google baked into the base is left untouched.
RUN apt-get update \
    && apt-get install -y --only-upgrade openssl libssl3 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=tools /out/helm /usr/local/bin/helm
COPY --from=tools /out/kubectl /opt/kubectl/v1.37/kubectl
COPY --from=build /tmp/windyflo.tar.gz /data/chart/
COPY --from=build /tmp/schema.yaml /data/

# WindyFlo's data layer (Postgres + object storage + Valkey) is slower to go Ready than the 300s
# default, and a timeout here fails the buyer's install.
ENV WAIT_FOR_READY_TIMEOUT 1800
ENV TESTER_TIMEOUT 1800
