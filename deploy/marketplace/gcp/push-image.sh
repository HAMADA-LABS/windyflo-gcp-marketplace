#!/usr/bin/env bash
# Build one of the support images in images/<dir> and publish it to Artifact Registry the way Cloud
# Marketplace needs it: tag $VERSION (+ release track), Marketplace service-name annotation, and no
# empty layers (Google's image copier rejects them). Same steps that were done by hand before.
#
#   ./push-image.sh ubbagent        # images/ubbagent  -> windyflo/ubbagent:3.1.3 (+3.1)
#   ./push-image.sh minio | postgres | redis
#   ./push-image.sh all      # postgres redis minio   (BYOL listing)
#   ./push-image.sh paid     # + ubbagent             (usage-based listing)
#
# Env: VERSION=3.1.3  GAR=us-docker.pkg.dev/windyflo-public/windyflo-marketplace
# Needs: docker, go, crane, gcloud (logged in). Rebuild + re-push whenever a base/Go CVE fix lands.
set -euo pipefail

VERSION="${VERSION:-3.1.3}"
GAR="${GAR:-us-docker.pkg.dev/windyflo-public/windyflo-marketplace}"
TRACK="${VERSION%.*}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GODEBUG=http2client=0

# images/<dir> -> repository name under $GAR/windyflo/
repo_for() { case "$1" in postgres) echo postgresql;; minio|redis|ubbagent) echo "$1";; *) echo "!! unknown image '$1'" >&2; exit 1;; esac; }

[[ $# -eq 1 ]] || { sed -n 2,12p "$0"; exit 2; }
for t in docker go crane gcloud; do command -v "$t" >/dev/null || { echo "!! missing $t" >&2; exit 1; }; done
gcloud auth print-access-token >/dev/null 2>&1 || { echo "!! gcloud auth expired: run 'gcloud auth login'" >&2; exit 1; }
gcloud auth configure-docker "${GAR%%/*}" -q >/dev/null 2>&1 || true

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
( cd "$HERE/tools/dropempty" && go build -o "$WORK/dropempty" . )

push_one() {
  local dir="$1" name ref
  name="$(repo_for "$dir")"; ref="$GAR/windyflo/$name"
  echo ">> [$dir] building"
  docker build --pull --provenance=false -t "wf-$dir:$VERSION" "$HERE/images/$dir"
  echo ">> [$dir] pushing $ref:$VERSION"
  docker tag "wf-$dir:$VERSION" "$ref:raw-$VERSION"
  docker push -q "$ref:raw-$VERSION" >/dev/null
  "$WORK/dropempty" "$ref:raw-$VERSION" "$ref:$VERSION"
  crane tag "$ref:$VERSION" "$TRACK"
  gcloud artifacts docker tags delete "$ref:raw-$VERSION" -q >/dev/null 2>&1 || true
  echo "   $name:$VERSION -> $(crane digest "$ref:$VERSION")"
}

if [[ "$1" == "all" ]]; then
  for d in postgres redis minio; do push_one "$d"; done          # BYOL set
elif [[ "$1" == "paid" ]]; then
  for d in postgres redis minio ubbagent; do push_one "$d"; done # usage-based set
else
  push_one "$1"
fi
