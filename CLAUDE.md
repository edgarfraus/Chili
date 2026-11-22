# Chili — notes for Claude

Chili is an unofficial SPICE client and Proxmox VE companion. The macOS app is released (v1.0.0); the
**Windows version** is in progress in `windows/` — see [`docs/windows/PLAN.md`](docs/windows/PLAN.md) and
the status at the end.

## Working with the maintainer

- The maintainer (GitHub `edgarfraus`) writes in **Italian**: answer in Italian. Code, comments,
  commit messages and docs are in English; user-facing strings are English with Italian translations.
- They test on a real Proxmox VE server, **EDG_Lab** (single node `lab`, API at 192.168.250.104:8006). Rules agreed for it:
  - You may create test machines, always named `chili-test-*` (VMs: `name`, containers: `hostname`),
    small (≤ 4 GB disk, ≤ 1 GB RAM unless needed), and delete them when done.
  - Before deleting anything, read the machine's **config** (`name` / `hostname`) and refuse unless it
    starts with `chili-test-`. The cluster list can lag right after creation (names show as `VM 102`).
  - Never touch any other VM/container (their own machines, e.g. VMs 100–105, change over time).
  - Opening consoles and reading logs is fine; anything else on their machines needs asking first.
- **Verify UI visually before handing it over.** SwiftUI layouts broke twice in ways only visible on
  screen (see PLAN.md, "Lessons"). Use the demo mode / previews and look at the result.
- While the GitHub repo is private, CI minutes cost money (macOS runners count 10×): put `[skip ci]` in
  commit messages unless a CI run is wanted. Once public, CI is free.
- End commit messages with the attribution lines given by the harness.

## Repository layout (macOS)

| Path | What |
|---|---|
| `launcher/Sources/` | SwiftUI app (macOS 12+): Proxmox client, models, views, wizards, logs |
| `launcher/SpiceKit/` | Objective-C native SPICE console on spice-client-glib (`ChiliSpice.h` is the Swift-facing API) |
| `launcher/Resources/*.lproj` | Localizations (`it.lproj/Localizable.strings`, keys = English text) |
| `scripts/build-stack.sh` | Builds ~30 libraries from pinned sources into `build/<arch>/prefix` (no Homebrew) |
| `scripts/bundle-app.sh`, `relocate.py`, `make-dmg.sh`, `smoke-test.sh` | App bundle, @rpath relocation, DMG, checks |
| `scripts/dev/` | Test SPICE server that logs input (`build-test-server.sh`) |
| `patches/` | Patches to upstream (GTK quartz event loop, spice-gtk relative mouse, virt-viewer locale dir) |
| `.github/workflows/build.yml` | arm64 + x86_64 DMGs; release on `v*` tags |
| `docs/screenshots/` | README images, made with `CHILI_DEMO=1` |

Build: `make` (first run 30–90 min). Dev loop for the launcher only: `scripts/build-launcher.sh <exe>`,
then relocate + re-sign (see `bundle-app.sh`).

Dev aids (env vars, harmless in production): `CHILI_DEMO=1` (sample server, no network, saved servers
untouched), `CHILI_DEBUG_NO_LOGIN=1`, `CHILI_DEBUG_SNAPSHOT=<dir>` (PNG of the app's windows every 3 s;
needs no screen-recording permission), `CHILI_DEBUG_ACTION=…` (see `runDebugAction` in `main.swift`:
`inventory`, `create:<variant>`, `ctcreate`, `cleanup`, `tasklog:<id>`, `journal`, `wizard[-win][-custom]`,
`ctwizard`, `logs`, `syslog`, `opentest`, `closetest`, `quickdump`, `novnc:<id>`, `spice:<id>`, `shell`).

## Repository layout (Windows)

| Path | What |
|---|---|
| `windows/src/Chili.Core/` | net10.0 library: Proxmox client, VM/CT drafts, `.vv` parsing, localization (reads the macOS `Localizable.strings` + `Strings/it.windows.strings`) |
| `windows/src/Chili/` | WinUI 3 app, unpackaged + self-contained: views, wizards, logs, built-in SPICE console (`Spice/`) |
| `windows/native/chili-spice.{h,c}` | C shim over spice-client-glib (port of SpiceKit), called through P/Invoke |
| `windows/scripts/bundle-viewer.sh` | Run in MSYS2 UCRT64: builds `chili-spice.dll`, collects remote-viewer + GTK/GStreamer into `windows/build/viewer` (the app build copies it to `viewer\`) |
| `windows/tests/Chili.Core.Tests/` | xUnit: parameter sets, `.vv`, host parsing, form encoding, every UI string has Italian |

Tools on the Windows machine: .NET 10 SDK, MSYS2 (`mingw-w64-ucrt-x86_64-{virt-viewer,ntldd,gst-plugins-good,gst-plugins-bad}`), `gh`.
Build: `dotnet build windows/src/Chili/Chili.csproj -p:Platform=x64`; tests: `dotnet test windows/tests/Chili.Core.Tests`.
Same dev aids as on macOS: `CHILI_DEMO`, `CHILI_LANG=it|en`, `CHILI_DEBUG_SNAPSHOT` (rendered from the XAML
tree, so it works in a disconnected RDP session), `CHILI_DEBUG_ACTION` (`editor`, `edit`, `quick`, `login`,
`cert`, `alert`, `wizard[-custom|-win]`, `ctwizard`, `logs`, `syslog`, `spice:<id>` with optional
`CHILI_DEBUG_CLOSE_AFTER=<s>`, live tests `create:<linux,win11,win11-nodrivers,custom>`, `ctcreate`, `cleanup`;
see `MainWindow.RunDebugAction` and `DebugActions.cs`).

## Status (2026-11-22)

- macOS: v1.0.0 tagged; CI builds the arm64 and x86_64 DMGs (first full run: 31 and 63 min).
- Windows, done and tested on EDG_Lab: login (password/TOTP/token), certificate pinning, VM list with
  dials, power actions, built-in SPICE console (display and guest resize verified; keyboard, mouse,
  clipboard and audio still to be tried by the maintainer), remote-viewer fallback, VM and container
  wizards, history & logs, node journal.
- Windows releases are separate: tags `windows-v*` → `build-windows.yml` (MSYS2 bundle, tests, publish,
  smoke test, Inno Setup installer `windows/installer/Chili.iss`, MSYS2 source packages) → a release that
  is not marked Latest (macOS keeps it). First one: `windows-v1.0.0`. Single instance + `.vv` / `spice://`
  associations work; the installer is per user, unsigned (SmartScreen: More info → Run anyway).
- Windows, next: WebView2 for noVNC/xterm.js/node shell (opened in the browser for now), settings page
  (classic viewer, resize guest, clipboard…; now only in settings.json), Windows key / Alt+Tab capture
  (keyboard hook), arm64 build (MSYS2 CLANGARM64), code signing.
- CI gotcha: GitHub applies `[skip ci]` to tag pushes too (it reads the tagged commit's message). Start a
  release build with `gh workflow run build.yml --ref v<version>`.
