# Restless

A small, fully native macOS menu bar app that keeps your Mac awake, **even
with the lid closed**.

Website: [restless.kainoa.me](https://restless.kainoa.me) Close the lid and SSH sessions, downloads, builds and
AI agents keep running.

Restless began as a fork of [Amped](https://github.com/gustaferiksson/amped)
by Gustaf Eriksson and has since been rewritten around a new panel, separate
lid-closed screen settings, Sparkle updates and its own branding. Amped's MIT
license and copyright notice are kept in [`LICENSE`](LICENSE). The panel's
design and some of its code are adapted from
[OpenUsage](https://github.com/robinebers/openusage), also MIT; see
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). Restless isn't affiliated
with either project.

## Install

Download `Restless-<version>.zip` from the
[latest release](https://github.com/notkainoa/restless/releases/latest), unzip
it, and move `Restless.app` to `/Applications`. Requires macOS 26 (Tahoe) or
newer.

Releases are signed with a Developer ID and notarized by Apple, so the app
opens normally. Restless updates itself with
[Sparkle](https://sparkle-project.org): it checks for new releases in the
background (you can turn this off in Settings), and *Check for Updates* checks
right away.

## The panel

Click the icon in the menu bar to open the panel.

- **Status card:** what Restless is doing right now, and the battery level.
- **Groups by lid position:** hover or click the **?** next to a group for an
  explanation of its settings.
- **Options** (bottom corner): Settings (`⌘,`), Check for Updates, About and
  Quit (`⌘Q`).
- **Settings:** Launch at Login, Show in Menu Bar, the background helper's
  status, the version and updates.
- `Esc` closes the panel. Right-click the icon for Settings and Quit.

| Setting | What it does |
| --- | --- |
| **Lid Open → Keep Awake** | Prevents idle sleep and keeps the screen on while the lid is open, using IOKit power assertions (the same mechanism as `caffeinate`). No password needed. |
| **Lid Closed → Keep Awake** | Keeps the Mac running with the lid closed, using `pmset -a disablesleep 1`. When it's off, closing the lid sleeps the Mac. |
| **Lid Closed → Sleep Display** | Turns the display off when the lid closes. When it's off, the screen keeps drawing at zero brightness, so a computer-use agent can still see and control it. |
| **Lid Closed → Lock Screen** | Locks the Mac when the lid closes. Keeping the Mac from sleeping also stops the usual lock-on-sleep, so Restless locks it instead. When it's off, anyone who opens the lid can use the desktop. |
| **Battery → Auto-off at 20%** | A safety net: on battery at 20% or less, Restless releases everything so the Mac can sleep normally. Turning off lid-closed mode needs the helper; without it that part stays on, because turning it off would need your password. |
| **Launch at Login** (Settings) | Registers Restless as a login item (with `SMAppService`), so it's there every time you log in. |

*Sleep Display* and *Lock Screen* can be changed while lid-closed mode is off,
so you can set them up ahead of time. They only affect the laptop's own screen:
while an external display is connected they do nothing, so closing the lid and
working on the monitor behaves exactly as macOS normally does. With *Sleep Display* on and *Lock Screen* off, macOS can still
lock the Mac if your Lock Screen settings require a password when the display
turns off.

The menu bar icon shows the state at a glance:

| Icon | State |
| --- | --- |
| `eye.slash` | Sleep is allowed |
| `eye` | Awake while the lid is open |
| `eye.fill` | Awake even with the lid closed |

On launch Restless starts with keep-awake **off**, so it never surprises you by
blocking sleep or asking for a password. When it quits it always restores
normal sleep.

## Moving from Amped

Restless copies your Amped settings the first time it runs. Quit Amped and
delete it, then remove Amped's entries under **System Settings → General →
Login Items & Extensions**, including its background helper. Restless installs
its own helper, and only Amped's own app could remove Amped's.

## How lid-closed mode stays passwordless

Keeping a Mac awake with the lid shut means flipping the system
`disablesleep` flag, which only `root` can do. Restless does this through a
small **privileged helper**: a `root` LaunchDaemon embedded in the app bundle
that the app talks to over **XPC**. The XPC channel only accepts code signed by
the same Developer ID team, so nothing but Restless can reach the helper. The
helper does exactly one thing, which is to turn `pmset disablesleep` on or off.

The **first time** you turn on *Lid Closed → Keep Awake*, Restless offers to set
the helper up. Approve "Restless" once under **System Settings → General →
Login Items & Extensions**, and from then on the switch never asks for a
password. That also lets *Auto-off at 20%* turn off lid-closed mode while the
lid is shut and you're away.

If you'd rather not install the helper, choose *Just This Time*. That keeps the
Mac awake now with a single password prompt and installs nothing. You can
remove the helper anytime from the same System Settings pane, and the setup
offer comes back the next time you turn on lid-closed mode.

> **The helper only works in a signed build.** An unsigned local build can't be
> approved, so lid-closed mode asks for your password on every toggle.

## Build and run

You need Xcode and XcodeGen:

```sh
brew install xcodegen
./build.sh              # builds into ./dist
open dist/Restless.app
```

`build.sh` reads `.env`, which isn't committed (copy it from `.env.example`).
With `CODE_SIGN_IDENTITY="Developer ID Application"` set, the build is signed
for team `VW9NDM428H`, with Hardened Runtime and a secure timestamp, so the
helper works and the build is ready for notarization. Leave the identity unset
for an ad-hoc build.

To work in Xcode:

```sh
xcodegen generate && open Restless.xcodeproj
```

The `.xcodeproj` is generated from `project.yml` and isn't committed.

## Releasing

`./release.sh <version>` runs every step from `main`:

1. Builds and signs the app.
2. Notarizes and staples it.
3. Signs the update for Sparkle and writes the appcast.
4. Publishes the GitHub release.

See [`docs/RELEASING.md`](docs/RELEASING.md) for the one-time setup.

## The icon

The app icon is an open eye with a moon for its iris: dark purple on white in
light mode, light purple on dark purple in dark mode. It's an Icon Composer
file, `icon/AppIcon.icon`, built from the layer SVGs in its `Assets` folder, so
macOS switches it with the system appearance and can tint it. Open it in Icon
Composer to edit it. `icon/restless-light.svg` and `icon/restless-dark.svg` are
the flat versions, for anywhere else the icon is needed.

## The App Store

Lid-closed mode relies on `pmset disablesleep` and a privileged helper, which a
sandboxed App Store app can't use. Restless ships as a notarized Developer ID
app instead.

## Project layout

```
Sources/                 (the app)
  RestlessApp.swift       @main App (the Settings window)
  Panel/                  the menu bar icon and its panel
  SleepController.swift   state, battery polling, auto-off safety net
  Updater.swift           Sparkle updates
  PowerAssertion.swift    IOKit power assertion wrapper (idle sleep)
  Privileged.swift        routes pmset to the helper, else an admin prompt
  HelperClient.swift      registers and calls the helper (SMAppService + XPC)
  Battery.swift           battery % and on-battery via IOKit power sources
  LoginItem.swift         launch at login via SMAppService
  Prompts.swift           first-use helper setup dialogs
  AppDelegate.swift       restores normal sleep on quit
Helper/                  (the privileged root daemon)
  main.swift              XPC listener entry point
  HelperService.swift     runs pmset as root; pins the client by Team ID
  me.kainoa.Restless.Helper.plist   LaunchDaemon definition
RestlessControl/         Control Center controls
Shared/                  (compiled into the app and the helper)
  HelperProtocol.swift    the XPC contract
  HelperConstants.swift   identifiers and service names
  CodeSigning.swift       Team ID requirement helpers
icon/                    AppIcon.icon (Icon Composer) and flat SVGs
project.yml              XcodeGen project
build.sh                 local or signed build
notarize.sh              notarytool submit and stapler staple
release.sh               build, notarize and publish a release with its appcast
```
