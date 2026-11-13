#!/usr/bin/env bash
# Publishes a new version: builds, zips, checksums, tags and creates a GitHub Release.
# Installed apps see it within hours ("Ember Mail x.y.z is available") and update with one click.
#   ./scripts/release.sh 1.1.0 ["release notes"]
# Optional env: EMBER_SIGN_ID (Developer ID identity), EMBER_NOTARY_PROFILE (notarytool keychain profile).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh X.Y.Z [notes]}"
NOTES="${2:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must look like 1.2.3"; exit 1; }
TAG="v$VERSION"

[ "$(git branch --show-current)" = "main" ] || { echo "Releases are cut from main."; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Commit your changes first (working tree is dirty)."; exit 1; }
git fetch -q origin && [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "Push main first (local and origin/main differ)."; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "Tag $TAG already exists."; exit 1; }

echo "▸ Tests"; ./scripts/test.sh | tail -1
echo "▸ Building $VERSION"; ./scripts/build-app.sh --version "$VERSION"

ZIP="build/Ember-Mail-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
if [ -n "${EMBER_NOTARY_PROFILE:-}" ]; then
  echo "▸ Notarizing (a few minutes)"
  ditto -c -k --keepParent "build/Ember Mail.app" "build/notarize.zip"
  xcrun notarytool submit build/notarize.zip --keychain-profile "$EMBER_NOTARY_PROFILE" --wait
  xcrun stapler staple "build/Ember Mail.app"
  rm -f build/notarize.zip
fi
ditto -c -k --keepParent "build/Ember Mail.app" "$ZIP"
( cd build && shasum -a 256 "Ember-Mail-$VERSION.zip" > "Ember-Mail-$VERSION.zip.sha256" )

echo "▸ Publishing $TAG"
if [ -n "$NOTES" ]; then NOTE_ARGS=(--notes "$NOTES"); else NOTE_ARGS=(--generate-notes); fi
gh release create "$TAG" "$ZIP" "$ZIP.sha256" --target main --title "Ember Mail $VERSION" "${NOTE_ARGS[@]}"
echo "✓ Released $TAG"
