# Chili — notes for Claude

Chili is an unofficial SPICE client and Proxmox VE companion. The macOS app is done and in this repo;
a **Windows version is next** — read [`docs/windows/PLAN.md`](docs/windows/PLAN.md) before starting it.

## Working with the maintainer

- The maintainer (GitHub `edgarfraus`) writes in **Italian**: answer in Italian. Code, comments,
  commit messages and docs are in English; user-facing strings are English with Italian translations.
- They test on a real Proxmox VE server, **EDG_Lab** (single node `pve01`). Rules agreed for it:
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

## Status (2026-11-22)

- macOS app feature-complete for v1.0.0 and tested on EDG_Lab (Intel Mac, macOS 26).
- Pending: maintainer makes the repo public → run the GitHub Actions build (never run yet; arm64 never
  built) → fix → tag `v1.0.0`.
- Next: Windows version, per `docs/windows/PLAN.md`.
