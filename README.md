# Amped ⚊

A tiny, completely native macOS menu bar app that keeps your Mac awake — an
Amphetamine-style alternative whose party trick is keeping the Mac awake **with
the lid closed**, using `pmset disablesleep` rather than `caffeinate` alone.

No window, no settings sheet, no Dock icon. Just a pill in your menu bar and a
handful of settings.

## Install

Download `Amped.app` from the [latest release](https://github.com/notkainoa/amped/releases/latest),
unzip it, and move it to `/Applications`. macOS 26 (Tahoe) or newer.

The build is not notarized. The first time you open it, right-click the app and choose Open.

Check for Updates looks at that releases page and, when a newer build exists, opens it so you can download and replace the app.

## The menu

Click the pill in the menu bar. Settings are grouped by lid position; the two
*Keep Awake* rows are switches and the rest are checkmarks, and changing any of
them leaves the menu open. Hover or click the **?** next to a group for an
explanation of its settings.

| Setting | What it does |
| --- | --- |
| **Lid Open → Keep Awake** | Prevents idle sleep, and keeps the screen on, while the lid is open. Uses IOKit power assertions (same mechanism as `caffeinate`). No password needed. |
| **Lid Closed → Keep Awake** | Keeps the Mac running with the lid closed, using `pmset -a disablesleep 1`. Off lets the lid sleep the Mac. |
| **Lid Closed → Sleep Display** | Turns the display off when the lid closes. Off keeps the screen drawing at zero brightness, so a computer-use agent can still see and control it. |
| **Lid Closed → Lock Screen** | Locks the Mac when the lid closes. Suppressing sleep also suppresses the usual lock-on-sleep, which is why Amped locks instead. Off leaves the desktop usable by anyone who opens the lid. |
| **Auto-off at 20% Battery** | Safety net: when on battery and the charge drops to 20% or below, Amped releases everything so the Mac can sleep normally. Remembered between launches. |
| **Launch at Login** | Registers Amped as a login item (via `SMAppService`) so the pill is there every time you log in. |

*Sleep Display* and *Lock Screen* can be changed while lid-closed mode is
off, so you can set them up ahead of time, and do nothing while an external
display is connected. With *Sleep Display* on and *Lock Screen* off, macOS can
still lock the Mac if Lock Screen settings require a password when the display
turns off.

The menu bar pill reflects the state at a glance:

- `pill` — sleep allowed (off)
- `pill.fill` — awake (lid open)
- `pills.fill` — awake with the lid closed

A status line shows the current state and battery level. `⌘Q` quits.

> On launch Amped starts with everything **off** (so it never surprises you by
> blocking sleep or prompting). Only the *Auto-off* preference is remembered.
> When it quits it always restores normal sleep behaviour.

## How lid-closed mode stays passwordless

Keeping a Mac awake with the lid shut requires flipping the system
`disablesleep` flag, which only `root` can do. Amped does this through a small
**privileged helper** — a `root` LaunchDaemon embedded in the app bundle that
the app talks to over **XPC**. The XPC channel is locked to Amped's own
Developer-ID **Team ID** (`setCodeSigningRequirement`), so nothing but Amped's
signed app can reach the helper, and the helper does exactly one thing:
`pmset disablesleep` on/off.

The **first time** you choose *Keep Awake but Lock the Screen* or *Keep Awake and Keep Screen Unlocked*, Amped offers to set the helper
up. Approve "Amped" once under **System Settings → General → Login Items &
Extensions**, and from then on that choice is silent — which also lets
*Auto-off at 20%* drop clamshell mode while the lid is shut and you're away.
Prefer not to? *Just This Time* keeps the Mac awake now with a single password
prompt and installs nothing. Remove the helper anytime from that same System
Settings pane (it's visible there, unlike a hidden sudoers rule); the setup
offer reappears the next time you enable lid-closed mode.

> **The helper only runs in a properly signed build.** In an unsigned local
> build it can't be approved, so lid mode falls back to a password prompt on
> every toggle. Build signed (below) to exercise the real path.

## Build & run

Requires Xcode, plus two Homebrew tools:

```sh
brew install xcodegen librsvg
./build.sh           # ad-hoc local build → ./dist (helper inactive; password fallback)
open dist/Amped.app  # the pill appears in your menu bar
```

### Signed build (helper works)

Signing config lives in `.env` (git-ignored; copy from `.env.example`):

```sh
DEVELOPMENT_TEAM=82K3YC8HVF
CODE_SIGN_IDENTITY="Developer ID Application"
```

Then `./build.sh` produces a build that meets Apple's notarization requirements:
**Developer ID** signing, **Hardened Runtime** on both the app and the helper, a
**secure timestamp**, and no `get-task-allow` entitlement. Install and try it:

```sh
cp -R dist/Amped.app /Applications/        # run from a stable location
open /Applications/Amped.app
```

Then: choose *Keep Awake but Lock the Screen* → *Set Up Helper…* → approve **Amped** in System
Settings → choose it again — it's now silent. (No Team ID is
hard-coded: the app reads its own at runtime to pin the XPC channel to the same
team.)

### Notarize & ship

One-time: create a `notarytool` keychain profile (the password is an
*app-specific password* from appleid.apple.com, not your Apple ID password):

```sh
xcrun notarytool store-credentials "Amped" \
  --apple-id "you@example.com" --team-id 82K3YC8HVF --password "xxxx-xxxx-xxxx-xxxx"
```

Set `NOTARY_PROFILE=Amped` in `.env`, then after a signed `./build.sh`:

```sh
./notarize.sh    # ditto-zips, notarytool submit --wait, stapler staple, verifies
```

Distribute the stapled `dist/Amped.app` (zip or DMG). `altool` is dead since
Nov 2023 — this uses `notarytool`.

Pushing to `main` publishes an unsigned GitHub Release. See [`docs/RELEASING.md`](docs/RELEASING.md).
Notarization is separate, and it is not part of that release yet.

To work on it in Xcode:

```sh
./icon/generate-icons.sh && xcodegen generate && open Amped.xcodeproj
```

(The `.xcodeproj` is generated from `project.yml` and is git-ignored.)

## The icon

- **Menu bar:** an SF Symbol (`pill` family) — Apple permits SF Symbols in your
  own UI, and they adapt to light/dark and the focus state automatically.
- **App icon:** `icon/amped.svg` (a two-tone capsule). `icon/generate-icons.sh`
  renders it into the asset catalog at all macOS sizes. To make a proper Liquid
  Glass icon, open `amped.svg` in **Icon Composer**, refine the layers, and
  export an `.icon` to drop into the project.

## A note on the App Store

The lid-closed feature relies on `pmset disablesleep` / a privileged helper,
which a sandboxed App Store build cannot do. Ship it as a notarized
**Developer ID** app. An App Store version would have to drop the clamshell
feature.

## Project layout

```
Sources/                 (the app)
  AmpedApp.swift          @main App (the Settings window)
  StatusMenu.swift        the menu bar pill and its menu (switches, checkmarks, ? panels)
  SleepController.swift   state, battery polling, auto-off safety net
  PowerAssertion.swift    IOKit power assertion wrapper (idle sleep)
  Privileged.swift        routes pmset to the helper, else an admin prompt
  HelperClient.swift      registers/calls the helper (SMAppService + XPC)
  Battery.swift           battery % + on-battery via IOKit power sources
  LoginItem.swift         launch-at-login via SMAppService
  Prompts.swift           first-use helper-setup dialogs
  AppDelegate.swift       restores normal sleep on quit
Helper/                  (the privileged root daemon)
  main.swift              XPC listener entry point
  HelperService.swift     runs pmset as root; pins the client by Team ID
  dev.gustaf.Amped.Helper.plist   LaunchDaemon definition
Shared/                  (compiled into both targets)
  HelperProtocol.swift    the XPC contract
  HelperConstants.swift   identifiers / service names
  CodeSigning.swift       Team-ID requirement helpers
icon/                     amped.svg + render script
project.yml               XcodeGen project (app + helper targets)
build.sh                  one-shot local / signed build
notarize.sh               notarytool submit + stapler staple
.env.example              signing / notary config template
```
