#!/usr/bin/env bash
# Build, sign, notarize and publish a Restless release, with the Sparkle appcast.
#
#     ./release.sh 1.0.0
#
# Needs, once (see docs/RELEASING.md):
#   - .env with DEVELOPMENT_TEAM, CODE_SIGN_IDENTITY="Developer ID Application" and NOTARY_PROFILE
#   - the notarytool keychain profile named by NOTARY_PROFILE
#   - the Sparkle signing key in the login keychain (account "restless")
#   - gh signed in with push access to notkainoa/restless
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version>, e.g. ./release.sh 1.0.0}"
REPO="notkainoa/restless"

[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || { echo "✗ Release from main."; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "✗ Commit or stash your changes first."; exit 1; }
# The build number is the commit count, which a shallow clone undercounts; Sparkle would then skip the update.
[[ "$(git rev-parse --is-shallow-repository)" == "false" ]] || { echo "✗ This is a shallow clone. Run: git fetch --unshallow"; exit 1; }
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "✗ main isn't in sync with origin/main."; exit 1; }
if gh release view "v${VERSION}" -R "$REPO" >/dev/null 2>&1; then
  echo "✗ v${VERSION} already exists."; exit 1
fi

# Sparkle compares build numbers, so each release needs a higher one; the commit count only grows on main.
export MARKETING_VERSION="$VERSION"
export CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)"

./build.sh
./notarize.sh

SPARKLE_BIN=".build/SourcePackages/artifacts/sparkle/Sparkle/bin"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ZIP="Restless-${VERSION}.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent dist/Restless.app "$STAGE/$ZIP"

echo "▸ Writing the appcast…"
"$SPARKLE_BIN/generate_appcast" \
  --account restless \
  --download-url-prefix "https://github.com/${REPO}/releases/download/v${VERSION}/" \
  -o "$STAGE/appcast.xml" \
  "$STAGE"

echo "▸ Publishing v${VERSION}…"
gh release create "v${VERSION}" "$STAGE/$ZIP" "$STAGE/appcast.xml" \
  -R "$REPO" \
  --target "$(git rev-parse HEAD)" \
  --title "Restless ${VERSION}" \
  --generate-notes

echo "✅ Released Restless ${VERSION} (build ${CURRENT_PROJECT_VERSION})"
