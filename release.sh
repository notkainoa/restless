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
SPARKLE_BIN=".build/SourcePackages/artifacts/sparkle/Sparkle/bin"
STEP="checking"

# Name the step that failed, so a stop is never silent.
trap 'echo "✗ Release stopped while ${STEP} (line ${LINENO}: ${BASH_COMMAND})." >&2' ERR

[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || { echo "✗ Release from main."; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "✗ Commit or stash your changes first."; exit 1; }
# The build number is the commit count, which a shallow clone undercounts; Sparkle would then skip the update.
[[ "$(git rev-parse --is-shallow-repository)" == "false" ]] || { echo "✗ This is a shallow clone. Run: git fetch --unshallow"; exit 1; }
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "✗ main isn't in sync with origin/main."; exit 1; }
if gh release view "v${VERSION}" -R "$REPO" >/dev/null 2>&1; then
  echo "✗ v${VERSION} already exists."; exit 1
fi

# Check every credential before the slow build, so a missing one fails in
# seconds, and any keychain prompt shows up now while you're at the keyboard.
[[ -f .env ]] || { echo "✗ No .env. Copy .env.example and fill it in (see docs/RELEASING.md)."; exit 1; }
set -a; source ./.env; set +a
[[ "${CODE_SIGN_IDENTITY:-}" == "Developer ID Application"* ]] \
  || { echo "✗ .env must set CODE_SIGN_IDENTITY=\"Developer ID Application\"."; exit 1; }
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || { echo "✗ No Developer ID Application certificate in the keychain."; exit 1; }
xcrun notarytool history --keychain-profile "${NOTARY_PROFILE:?.env must set NOTARY_PROFILE}" >/dev/null 2>&1 \
  || { echo "✗ The notarytool profile \"${NOTARY_PROFILE}\" is missing or its password no longer works."; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "✗ gh isn't signed in."; exit 1; }
if [[ -x "$SPARKLE_BIN/generate_keys" ]]; then
  echo "▸ Checking the Sparkle signing key (allow keychain access if asked)…"
  KEY="$("$SPARKLE_BIN/generate_keys" --account restless -p)" \
    || { echo "✗ Couldn't read the Sparkle key from the keychain."; exit 1; }
  grep -qF "SUPublicEDKey: ${KEY}" project.yml \
    || { echo "✗ The keychain's Sparkle key doesn't match SUPublicEDKey in project.yml."; exit 1; }
fi

# Sparkle compares build numbers, so each release needs a higher one; the commit count only grows on main.
export MARKETING_VERSION="$VERSION"
export CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)"

STEP="building"
./build.sh
STEP="notarizing"
./notarize.sh

# Stage in dist/ (git-ignored), not a temp folder, so the notarized zip
# survives if a later step fails.
STEP="writing the appcast"
STAGE="dist/release-${VERSION}"
rm -rf "$STAGE"; mkdir -p "$STAGE"
ZIP="Restless-${VERSION}.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent dist/Restless.app "$STAGE/$ZIP"

echo "▸ Writing the appcast…"
"$SPARKLE_BIN/generate_appcast" \
  --account restless \
  --download-url-prefix "https://github.com/${REPO}/releases/download/v${VERSION}/" \
  -o "$STAGE/appcast.xml" \
  "$STAGE"
grep -q "<sparkle:version>${CURRENT_PROJECT_VERSION}</sparkle:version>" "$STAGE/appcast.xml" \
  && grep -q "sparkle:edSignature=" "$STAGE/appcast.xml" \
  || { echo "✗ The appcast is missing build ${CURRENT_PROJECT_VERSION} or its signature. Files are in ${STAGE}."; exit 1; }

STEP="publishing"
echo "▸ Publishing v${VERSION}…"
gh release create "v${VERSION}" "$STAGE/$ZIP" "$STAGE/appcast.xml" \
  -R "$REPO" \
  --target "$(git rev-parse HEAD)" \
  --title "Restless ${VERSION}" \
  --generate-notes

rm -rf "$STAGE"
echo "✅ Released Restless ${VERSION} (build ${CURRENT_PROJECT_VERSION})"
