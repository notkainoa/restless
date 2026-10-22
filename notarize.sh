#!/usr/bin/env bash
# Notarize and staple dist/Restless.app. Run after a signed ./build.sh.
#
# notarytool needs credentials. Two ways, pick one:
#
#   1) Keychain profile (easiest locally). The password is an app-specific
#      password from appleid.apple.com → Sign-In & Security → App-Specific
#      Passwords, NOT your Apple ID password:
#
#        xcrun notarytool store-credentials "Restless" \
#          --apple-id "you@example.com" --team-id VW9NDM428H --password "xxxx-xxxx-xxxx-xxxx"
#
#      Then set NOTARY_PROFILE=Restless in .env.
#
#   2) App Store Connect API key (headless / CI). Create a key at
#      appstoreconnect.apple.com → Users and Access → Integrations → App Store
#      Connect API, then set in .env (or the CI env):
#
#        NOTARY_KEY=/path/to/AuthKey_XXXXXXXXXX.p8
#        NOTARY_KEY_ID=XXXXXXXXXX        # the key's Key ID
#        NOTARY_ISSUER=xxxxxxxx-xxxx-... # the Issuer ID shown above the keys
set -euo pipefail
cd "$(dirname "$0")"

[[ -f .env ]] && { set -a; source ./.env; set +a; }

# Build the notarytool auth args from whichever credential set is present.
NOTARY_AUTH=()
if [[ -n "${NOTARY_KEY:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
  NOTARY_AUTH=( --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" )
elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_AUTH=( --keychain-profile "$NOTARY_PROFILE" )
else
  echo "✗ No notarytool credentials. Set NOTARY_PROFILE, or NOTARY_KEY + NOTARY_KEY_ID + NOTARY_ISSUER (see this file's header)."; exit 1
fi

APP="dist/Restless.app"
ZIP="dist/Restless.zip"

[[ -d "$APP" ]] || { echo "✗ $APP not found — run a signed ./build.sh first."; exit 1; }
if codesign -dvv "$APP" 2>&1 | grep -q "Signature=adhoc"; then
  echo "✗ $APP is ad-hoc signed. Set a Developer ID identity in .env and rebuild."; exit 1
fi

echo "▸ Zipping for submission…"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "▸ Submitting to the Apple notary service (waits for the result)…"
xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait

echo "▸ Stapling the ticket onto the app…"
xcrun stapler staple "$APP"

echo "▸ Verifying…"
xcrun stapler validate "$APP"
spctl -a -vvv --type exec "$APP"

rm -f "$ZIP"
echo "✅ Notarized & stapled: $APP"
