#!/usr/bin/env bash
# Build (and optionally push) the GCP Marketplace deployer image.
#
# WHY THIS SCRIPT EXISTS: the Marketplace deployer renders with
#     helm template "$NAME" <chart> --values=<(print_config.py --output=yaml)
# and print_config.py emits ONLY the properties declared in schema.yaml. There is no `-f` layer.
# So values-marketplace-gcp.yaml cannot be "applied at deploy time" the way it is for our own
# helmfile deploys — it has to BE the chart's values.yaml inside the deployer image. That merge is
# the main job here; the rest is staging the build context the way deployer/Dockerfile expects.
#
# Usage:
#   GAR_REPO=us-docker.pkg.dev/<PROJECT_ID>/windyflo-public \
#   VERSION=3.0.13 \
#   ./build-deployer.sh [--push]
#
# Requires: docker, helm 3, yq v4.
set -euo pipefail

GAR_REPO="${GAR_REPO:?set GAR_REPO=<location>-docker.pkg.dev/<project>/<repo> (no trailing slash)}"
VERSION="${VERSION:?set VERSION=<x.y.z> — strict SemVer WITH patch; the deployer rejects \"3.0\"}"
# Pin the tools tag: the deployer_helm base bakes in whatever helm/kubectl were latest when IT was
# built, so :latest silently changes the renderer. Bump deliberately, then re-run mpdev verify.
# Tag scheme changed from 0.x.y to 13.x.y (GCP versioning update, Sep 2026). 13.0.11 = latest.
# To check available tags: gcloud container images list-tags gcr.io/cloud-marketplace-tools/k8s/deployer_helm
MARKETPLACE_TOOLS_TAG="${MARKETPLACE_TOOLS_TAG:-13.0.12}"

if ! [[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "!! VERSION='$VERSION' is not strict SemVer with a patch component." >&2
  echo "   schema.yaml's publishedVersion and the Application CR's spec.descriptor.version are" >&2
  echo "   string-compared by the deployer; both derive from this. '3.0' is rejected." >&2
  exit 1
fi
# GCP wants both a release-track tag and the exact version on every image. Per Google's tagging
# guidance the DEPLOYER's track tag drops the patch (3.0.13 -> 3.0) while app images keep both.
TRACK_TAG="${VERSION%.*}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_SRC="$SCRIPT_DIR/../../charts/windyflo"
STAGE="$SCRIPT_DIR/deployer/chart/windyflo"

for tool in docker helm yq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "!! $tool not found on PATH" >&2; exit 1; }
done
if ! yq --version 2>&1 | grep -qE 'v?4\.'; then
  echo "!! yq v4 required (mikefarah/yq). Found: $(yq --version 2>&1)" >&2
  exit 1
fi

echo ">> Staging chart and schema into the deployer build context"
rm -rf "$SCRIPT_DIR/deployer/chart"
mkdir -p "$STAGE"
# Usage-based (paid) profile declares the ubbagent image + REPORTING_SECRET; BYOL must not.
case "${MARKETPLACE_VALUES_FILE:-values-marketplace-gcp.yaml}" in
  *paid*) SCHEMA_SRC="$SCRIPT_DIR/schema-paid.yaml" ;;
  *)      SCHEMA_SRC="$SCRIPT_DIR/schema.yaml" ;;
esac
echo ">> Using $(basename "$SCHEMA_SRC")"
cp "$SCHEMA_SRC" "$SCRIPT_DIR/deployer/schema.yaml"
# Copy everything EXCEPT the per-environment values files — they are meaningless inside the deployer
# (no -f layer exists) and would just be dead weight a certification reviewer has to ask about.
tar -C "$CHART_SRC" -cf - \
    --exclude='values-*.yaml' \
    --exclude='charts/*.tgz' \
    . | tar -C "$STAGE" -xf -

# Which marketplace values profile to bake in. Override for the paid listing:
#   MARKETPLACE_VALUES_FILE=values-marketplace-gcp-paid.yaml
MARKETPLACE_VALUES_FILE="${MARKETPLACE_VALUES_FILE:-values-marketplace-gcp.yaml}"

echo ">> Merging $MARKETPLACE_VALUES_FILE INTO the staged values.yaml (deep merge, marketplace wins)"
yq eval-all '. as $item ireduce ({}; . * $item)' \
    "$CHART_SRC/values.yaml" "$CHART_SRC/$MARKETPLACE_VALUES_FILE" \
    > "$STAGE/values.yaml"

# Keep dead-looking URLs out of the baked values: in-cluster service names (…svc:9000) and comment
# examples are not real links, but a link checker run over the deployer image reports them as
# "page not found". Backup is off in this profile, so its endpointURL default is unused.
yq -i '.data.postgres.backup.endpointURL = ""' "$STAGE/values.yaml"
sed -i -E '/^[[:space:]]*#.*https?:\/\//d' "$STAGE/values.yaml"

# publishedVersion must match schema.yaml's, which envsubst stamps from $TAG at docker-build time.
# Set it in the baked values so templates/application.yaml renders the identical string.
yq -i ".gcpMarketplace.publishedVersion = \"$VERSION\"" "$STAGE/values.yaml"

if grep -v '^\s*#' "$STAGE/values.yaml" | grep -q 'REPLACE_ME'; then
  echo "!! The staged values.yaml still contains REPLACE_ME placeholders:" >&2
  grep -v '^\s*#' "$STAGE/values.yaml" | grep -n 'REPLACE_ME' >&2
  echo "   Set gcpMarketplace.partnerId / productId in $MARKETPLACE_VALUES_FILE to the real" >&2
  echo "   Producer Portal identifiers first — they go into the deploy-info annotation the deployer" >&2
  echo "   validates, and a mismatch fails certification." >&2
  echo "   On the PAID profile, gcpMarketplace.ubbagent.{image,reportingSecretName,serviceName," >&2
  echo "   metricName} must also be set — the Marketplace team mints serviceName/metricName when the" >&2
  echo "   pricing model is submitted. Without them usage is never reported and you are not paid." >&2
  exit 1
fi

# This listing's profile uses NO subcharts: data.plain=true (own StatefulSets), data.redis.subchart=false,
# and every operators.* flag off. Shipping the vendored third-party subcharts anyway adds nothing but
# attack surface and URLs from their Chart.yaml (icon/home/sources) — three of which are 404 today
# (bitnami redis icon, MinIO operator icon, CNPG grafana-dashboards), and Marketplace's container
# image review flags dead links found inside the deployer image. Strip them, but only when the merged
# values prove none is enabled, so a profile that does need one fails loudly instead of silently
# losing it.
echo ">> Stripping unused subcharts (profile enables none; deployer runs 'helm template' only)"
for k in .data.plain; do
  [[ "$(yq "$k" "$STAGE/values.yaml")" == "true" ]] || { echo "!! $k is not true in $MARKETPLACE_VALUES_FILE; refusing to strip subcharts" >&2; exit 1; }
done
for k in .data.redis.subchart .operators.cnpg.enabled .operators.minioOperator.enabled .operators.certManager.enabled .operators.externalSecrets.enabled; do
  v="$(yq "$k" "$STAGE/values.yaml")"
  [[ "$v" == "false" || "$v" == "null" ]] || { echo "!! $k=$v in $MARKETPLACE_VALUES_FILE but its subchart would be stripped" >&2; exit 1; }
done
yq -i 'del(.dependencies)' "$STAGE/Chart.yaml"
rm -rf "$STAGE/charts" "$STAGE/Chart.lock"

echo ">> Sanity: chart must render with ONLY the baked values (no -f, no --set beyond name/namespace)"
if ! helm template wf "$STAGE" --namespace wf-test >/dev/null; then
  echo "!! The staged chart does not render standalone. The deployer would fail the same way" >&2
  echo "   inside the buyer's cluster. Fix values-marketplace-gcp.yaml before packaging." >&2
  exit 1
fi

echo ">> Building $GAR_REPO/deployer:{$VERSION,$TRACK_TAG}"
# --pull: always refresh golang:1-alpine (helm/kubectl are rebuilt on it) and the other bases; Go ships
# stdlib CVE fixes every few weeks and a cached older toolchain reintroduces them.
docker build \
  --pull \
  --provenance=false \
  --build-arg "MARKETPLACE_TOOLS_TAG=$MARKETPLACE_TOOLS_TAG" \
  --build-arg "REGISTRY=$GAR_REPO" \
  --build-arg "TAG=$VERSION" \
  -t "$GAR_REPO/deployer:$VERSION" \
  -t "$GAR_REPO/deployer:$TRACK_TAG" \
  "$SCRIPT_DIR/deployer"

# NOTE: validate_schema.py in deployer_helm 13.x checks `default.startswith('gcr.io')` and
# rejects GAR (us-docker.pkg.dev) paths — it predates GAR. Since the IMAGE property is for
# GCP image tracking only (baked values.yaml controls actual deployment), skip local validation.
# The real gate is: mpdev verify --deployer=$GAR_REPO/deployer:$VERSION (runs in a real cluster)
echo ">> Skipping local schema validator (gcr.io-only check rejects GAR paths — use mpdev verify)"

if [[ "${1:-}" == "--push" ]]; then
  echo ">> Pushing both tags"
  docker push "$GAR_REPO/deployer:$VERSION"
  docker push "$GAR_REPO/deployer:$TRACK_TAG"

  # GCP's certification scanner looks for windyflo/windyflo:$VERSION (the publishedVersion).
  # The mirror script tags the app image at its own upstream version (e.g. 3.0.19), not the
  # deployer version. Re-tag so the scanner finds it. Get the upstream tag from images.txt.
  # APP_SOURCE_TAG = tag of the already-pushed, annotated app image to expose as $VERSION.
  # Required: the old images.txt lookup re-pointed $VERSION at a stale (vulnerable) image.
  APP_SOURCE_TAG="${APP_SOURCE_TAG:?set APP_SOURCE_TAG=<existing tag of windyflo/windyflo to publish as $VERSION>}"
  echo ">> Re-tagging app image ($APP_SOURCE_TAG) as $VERSION (GCP scanner expects windyflo/windyflo:$VERSION)"
  GODEBUG=http2client=0 crane tag "$GAR_REPO/windyflo/windyflo:$APP_SOURCE_TAG" "$VERSION"
  # Only the paid listing declares windyflo/ubbagent in schema.yaml; tag it only when asked to.
  if [[ -n "${UBBAGENT_SOURCE_TAG:-}" ]]; then
    GODEBUG=http2client=0 crane tag "$GAR_REPO/windyflo/ubbagent:$UBBAGENT_SOURCE_TAG" "$VERSION"
  fi

  # The deployer image itself also requires the GCP service-name annotation (same Jan-2025 rule
  # that applies to all images). crane mutate changes the digest — update both tags after.
  # dropempty = annotate + remove empty layers. A Docker step that changes nothing (e.g. the openssl
  # `--only-upgrade` once the base already ships the fixed version) leaves a 29-byte empty layer, and
  # Google's image copier rejects it: "Manifest references unknown blob(s)" -> "Unable to start
  # verification". Run on every push so no future Dockerfile edit can reintroduce it.
  echo ">> Annotating deployer image + removing empty layers"
  command -v go >/dev/null || { echo "!! go is required to run tools/dropempty" >&2; exit 1; }
  DROPEMPTY="$(mktemp -d)/dropempty"
  ( cd "$SCRIPT_DIR/tools/dropempty" && go build -o "$DROPEMPTY" . )
  SERVICE_NAME="${SERVICE_NAME:-windyflo.endpoints.windyflo-public.cloud.goog}" \
    GODEBUG=http2client=0 "$DROPEMPTY" "$GAR_REPO/deployer:$VERSION" "$GAR_REPO/deployer:$VERSION"
  GODEBUG=http2client=0 crane tag "$GAR_REPO/deployer:$VERSION" "$TRACK_TAG"
fi

cat <<EOF

Built: $GAR_REPO/deployer:$VERSION (and :$TRACK_TAG)

Next — run the SAME validation Marketplace certification runs, against a real cluster:
  mpdev verify --deployer=$GAR_REPO/deployer:$VERSION
  mpdev install --deployer=$GAR_REPO/deployer:$VERSION \\
    --parameters='{"name":"wf-test","namespace":"wf-test"}'
EOF
