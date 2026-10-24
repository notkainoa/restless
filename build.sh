#!/usr/bin/env bash
# Build Restless.app locally and drop it in ./dist.
# Requires: Xcode and xcodegen (brew install xcodegen).
#
# Local (ad-hoc) build — helper inactive, lid mode falls back to a password prompt:
#     ./build.sh
#
# Signed, notarization-ready build (helper works) — set in .env:
#     DEVELOPMENT_TEAM=XXXXXXXXXX
#     CODE_SIGN_IDENTITY="Developer ID Application"
#     ./build.sh        # then: ./notarize.sh
set -euo pipefail
cd "$(dirname "$0")"

# Optional local config (git-ignored): DEVELOPMENT_TEAM, CODE_SIGN_IDENTITY, NOTARY_PROFILE.
# A version passed in by release.sh wins over anything .env sets.
PASSED_MARKETING_VERSION="${MARKETING_VERSION:-}"
PASSED_PROJECT_VERSION="${CURRENT_PROJECT_VERSION:-}"
if [[ -f .env ]]; then
  set -a
  # shellcheck source=/dev/null
  source ./.env
  set +a
fi
[[ -n "$PASSED_MARKETING_VERSION" ]] && MARKETING_VERSION="$PASSED_MARKETING_VERSION"
[[ -n "$PASSED_PROJECT_VERSION" ]] && CURRENT_PROJECT_VERSION="$PASSED_PROJECT_VERSION"

SIGN_ID="${CODE_SIGN_IDENTITY:--}"
SIGN_ARGS=( "CODE_SIGN_IDENTITY=${SIGN_ID}" )
if [[ "$SIGN_ID" == "-" ]]; then
  SIGN_ARGS+=( "CODE_SIGNING_REQUIRED=NO" )
else
  # Real Developer ID build: pin the team, add a secure timestamp, and don't
  # inject base entitlements (which would add get-task-allow=true and fail
  # notarization). Hardened Runtime is on in project.yml. The app needs no
  # entitlements of its own.
  [[ -n "${DEVELOPMENT_TEAM:-}" ]] && SIGN_ARGS+=( "DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}" )
  SIGN_ARGS+=( "OTHER_CODE_SIGN_FLAGS=--timestamp" "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO" )
fi

# CI stamps the release version/build from the git tag. Locally we stamp a
# "-local" version instead, so the menu tells you which build you are running.
# Command-line build settings win over the project.
if [[ -z "${MARKETING_VERSION:-}" ]]; then
  MARKETING_VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo dev)-local"
fi
SIGN_ARGS+=( "MARKETING_VERSION=${MARKETING_VERSION}" )
[[ -n "${CURRENT_PROJECT_VERSION:-}" ]] && SIGN_ARGS+=( "CURRENT_PROJECT_VERSION=${CURRENT_PROJECT_VERSION}" )

echo "▸ Generating Xcode project…"
xcodegen generate

echo "▸ Building (Release)…  signing identity: ${SIGN_ID}"
xcodebuild \
  -project Restless.xcodeproj \
  -scheme Restless \
  -configuration Release \
  -derivedDataPath .build \
  "${SIGN_ARGS[@]}" \
  build

APP=".build/Build/Products/Release/Restless.app"

# Sparkle ships its nested helpers (the XPC services, Autoupdate and
# Updater.app) ad-hoc signed, and Xcode leaves them that way, so notarization
# rejects them. Re-sign them with our identity, innermost first, then re-seal
# the framework and the app. Not --deep: that would also re-sign the helper and
# the Control Center extension and could drop their entitlements.
if [[ "$SIGN_ID" != "-" ]]; then
  echo "▸ Re-signing Sparkle's nested helpers…"
  resign() {
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
      --preserve-metadata=entitlements "$1"
  }
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  resign "$SPARKLE/XPCServices/Installer.xpc"
  resign "$SPARKLE/XPCServices/Downloader.xpc"
  resign "$SPARKLE/Autoupdate"
  resign "$SPARKLE/Updater.app"
  resign "$APP/Contents/Frameworks/Sparkle.framework"
  resign "$APP"
  codesign --verify --deep --strict "$APP"
fi

mkdir -p dist
rm -rf "dist/Restless.app"
cp -R "$APP" "dist/Restless.app"

echo ""
if [[ "$SIGN_ID" == "-" ]]; then
  echo "✅ Built dist/Restless.app  (ad-hoc — helper inactive, password fallback)"
else
  echo "✅ Built dist/Restless.app  (Developer ID, hardened runtime, secure timestamp)"
  echo "   Notarize: ./notarize.sh"
fi
echo "   Launch:   open dist/Restless.app"
echo "   Install:  cp -R dist/Restless.app /Applications/"
