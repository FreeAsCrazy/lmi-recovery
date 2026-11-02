#!/usr/bin/env bash
# Publish the recovery image directly as a release asset.
# Keep exactly one release in the repository; every build replaces it.
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN not set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"
: "${GITHUB_SHA:?GITHUB_SHA not set}"

TAG=${RELEASE_TAG:-fox16.0-lmi}
TITLE=${RELEASE_TITLE:-OrangeFox 16.0 (lmi)}
DIST=${DIST_DIR:-$GITHUB_WORKSPACE/dist}

IMG=$(find "$DIST" -maxdepth 1 -type f -name '*.img' -print -quit)
[ -n "$IMG" ] && [ -s "$IMG" ] || {
    echo "recovery image not found in $DIST" >&2
    exit 1
}

echo "publishing: $IMG"
echo "repository: $GITHUB_REPOSITORY"
echo "tag: $TAG"

# Remove every existing release so the repository always has exactly one.
mapfile -t TAGS < <(
    gh release list --repo "$GITHUB_REPOSITORY" --limit 100 \
        --json tagName --jq '.[].tagName'
)
for old in "${TAGS[@]}"; do
    [ -n "$old" ] || continue
    echo "deleting old release: $old"
    gh release delete "$old" --repo "$GITHUB_REPOSITORY" --yes --cleanup-tag || true
done

# The uploaded asset is the .img file itself (not a zip).
gh release create "$TAG" "$IMG" \
    --repo "$GITHUB_REPOSITORY" \
    --title "$TITLE" \
    --notes "OrangeFox 16.0 for Xiaomi lmi/lmipro.

- BusyBox 1.36.1 static aarch64 (topjohnwu + osm0sis applet union)
- Build commit: $GITHUB_SHA
- Build run: https://github.com/$GITHUB_REPOSITORY/actions/runs/${GITHUB_RUN_ID:-}" \
    --latest

echo "release published:"
gh release view "$TAG" --repo "$GITHUB_REPOSITORY" --json url,assets \
    --jq '{url: .url, assets: [.assets[] | {name, size}]}'
