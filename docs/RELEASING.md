# Releasing Restless

Releases are built on a Mac, not in CI, because they need the Developer ID
certificate, Apple's notary service and the Sparkle signing key, all of which
live in the login keychain. CI (`.github/workflows/ci.yml`) only checks that an
unsigned build compiles.

## One-time setup

1. **Developer ID certificate.** "Developer ID Application" for team
   `VW9NDM428H` must be in the login keychain. Check with:
   ```sh
   security find-identity -v -p codesigning
   ```
2. **`.env`.** Copy it from `.env.example`. It sets the team, the signing
   identity and `NOTARY_PROFILE=Restless`.
3. **Notary credentials.** Create an app-specific password for the team's
   Apple ID at appleid.apple.com → Sign-In & Security → App-Specific Passwords.
   Then store it as the `Restless` keychain profile:
   ```sh
   xcrun notarytool store-credentials "Restless" \
     --apple-id "APPLE_ID_EMAIL" --team-id VW9NDM428H
   ```
   It prompts for the password, so it never lands in your shell history.
4. **Sparkle signing key.** The private EdDSA key is in the login keychain
   under the account `restless`; its public half is `SUPublicEDKey` in
   `project.yml`. Back it up somewhere safe:
   ```sh
   .build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account restless -x restless-sparkle-key.txt
   ```
   Without it, no future release can update existing installs.

## Every release

From an up-to-date, clean `main`:

```sh
./release.sh 1.1.0
```

It runs these steps:

1. Builds and signs `Restless.app` with version `1.1.0`. The build number is
   the commit count on `main`, which only grows, and that's what Sparkle
   compares.
2. Notarizes and staples the app.
3. Zips the app. Sparkle's `generate_appcast` then signs the zip and writes
   `appcast.xml`.
4. Publishes the GitHub release `v1.1.0` with both files attached.

The app's feed is
`https://github.com/notkainoa/restless/releases/latest/download/appcast.xml`,
so every installed copy sees the new release as soon as it's published.
