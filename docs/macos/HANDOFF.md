# macOS — catching up with the Windows app (handoff, 2026-11-23)

Read `CLAUDE.md` first (working rules, EDG_Lab etiquette, dev aids). This file lists what the Windows app
gained since v1.0.0 that the macOS app still lacks, with the design already used on Windows so both stay
in step. Answer the maintainer in Italian.

State at handoff: macOS `v1.0.0` released (both DMGs, sources). Windows `windows-v1.0.1` released with
everything below. All work is on `main`.

## 1. SPICE through a Cloudflare Tunnel (no client software)

**Why:** the maintainer publishes Proxmox with `cloudflared` (outbound tunnel). Only the 8006 web UI is
reachable from outside, over HTTPS; SPICE needs the spiceproxy on TCP 3128, which a Cloudflare HTTP
hostname can't carry (it's an HTTP `CONNECT` proxy followed by raw TLS). WARP or `cloudflared` on the
client are not allowed on the maintainer's work machine.

**How it works:** the tunnel publishes the spiceproxy as a TCP service on its own hostname
(`service: tcp://localhost:3128`, e.g. `spice.example.com`). Cloudflare carries TCP services as
**WebSocket streams over HTTPS** — what `cloudflared access tcp` does on the client. Chili does it itself:

- a listener on `127.0.0.1:<random port>`;
- each accepted TCP connection → its own WebSocket to `wss://<host>/` (no special headers), raw bytes in
  **binary** frames both ways; when one side ends, close the other;
- the `.vv` config gets `proxy=http://127.0.0.1:<port>` instead of `http://<server>:3128`.
  SPICE opens one connection per channel (4–6), so several WebSockets at once.

Windows reference: `windows/src/Chili.Core/Proxmox/TcpOverWebSocket.cs` (≈130 lines) and its tests in
`windows/tests/Chili.Core.Tests/CoreTests.cs` (`TcpOverWebSocketTests`).

**macOS work:**
- `ServerProfile.spiceTunnelHost: String` (Codable, default `""`; decode missing key as empty).
- A `TcpOverWebSocket` class: `NWListener` (Network.framework) on loopback, port 0, and
  `URLSessionWebSocketTask` per connection (`.data` messages). Accept `spice.example.com`, `https://…`,
  `wss://…`, `ws://…` (→ `wss://host/` by default). Keep `lastError` for diagnostics.
- `ServerSession`: create the tunnel lazily when `spiceTunnelHost` is set, tear it down on logout / profile
  change; a helper that gets the SPICE config and rewrites `proxy`. Use it both in `connect` and in the
  console's **reconnect** closure (fresh ticket each time). Works for the built-in console and for the
  classic remote-viewer (it reads the proxy from the `.vv`).
- `ServerEditor`: a "SPICE tunnel" text field (prompt `spice.example.com`) with the caption below.
- Console disconnected overlay: append `"Cloudflare Tunnel (%@): %@"` with the tunnel error when there is one.
- README already documents the server side (section *Network requirements → Through a Cloudflare Tunnel*):
  change its heading from "(Windows app)" to cover both apps.

**Test:** Windows has a debug action `spicetunnel:<vmid>` (`windows/src/Chili/DebugActions.cs`): an
in-process WebSocket↔TCP bridge to `<server>:3128` plays cloudflared, and an in-memory copy of the profile
points `spiceTunnelHost` at `ws://localhost:<port>/`; then it opens a running VM's console. Do the same in
`DebugActions.swift` and check the console connects (log: bridged connections ≥ 4, state connected).
Only open consoles of VMs that are already running; never start the maintainer's VMs.

## 2. Automatic updates from GitHub releases

**Windows design (keep the same behaviour):** at launch (after ~15 s) and every 12 h, query
`https://api.github.com/repos/edgarfraus/Chili/releases?per_page=30` (needs a `User-Agent`), take the newest
release that is not a draft or pre-release, whose tag matches this platform, and is newer than the running
version. Show a banner at the top of the main window: "Chili %@ is available" / "You have version %@." with
**Update Now** and **What's New** (opens the release page). Update Now downloads the asset, checks it against
the release's `.sha256` (sha256sum format: `<hex>  <file>`), installs, restarts Chili. A preference
`checkForUpdates` (default on). Dev builds stop after download + verification. Env
`CHILI_DEBUG_UPDATE_CURRENT=0.9.0` pretends an older version (to test against real releases); debug action
`update` runs check + Update Now. Reference: `windows/src/Chili.Core/Updates.cs`,
`windows/src/Chili/Services/Updater.cs`, `MainWindow.xaml.cs` (`ShowUpdate`, `OnUpdateNow`).

**macOS specifics:**
- Tags: macOS releases are `v<version>` (exactly `^v\d+(\.\d+)*$`); **ignore `windows-v*`**. Asset:
  `Chili-<version>-<arch>.dmg` with `arch` = `arm64` or `x86_64` (`#if arch(arm64)`), plus `.dmg.sha256`.
  Current version: `CFBundleShortVersionString`.
- Install: `hdiutil attach -nobrowse -readonly` the DMG, copy `Chili.app` next to the running bundle
  (`ditto`), detach. Then a small helper (shell script launched with `Process`, detached) waits for Chili's
  PID to exit, swaps the bundles (move old aside, move new in, delete old), removes quarantine
  (`xattr -dr com.apple.quarantine`; a download through URLSession normally has none, verify), and runs
  `open` on the new bundle. Chili then quits (disconnect consoles first; ask if any are open).
- If the bundle's folder isn't writable (e.g. /Applications owned by root), fall back to an
  `osascript … with administrator privileges` swap, or just open the DMG in Finder and tell the user.
- The app is ad-hoc signed (no Developer ID): the replaced bundle must still launch; test it — Gatekeeper
  should not complain because it was not downloaded by a browser. Sparkle was considered and dropped for
  now (EdDSA keys + appcast to maintain); the GitHub-API approach mirrors Windows.
- Test end to end on the Mac: install the DMG of v1.0.0, run a build that thinks it is 0.9.0 against the
  real `v1.0.0` release, and once v1.0.1 exists, update 1.0.0 → 1.0.1 for real.

## 3. Strings

Italian translations for both features already exist in
`windows/src/Chili.Core/Strings/it.windows.strings` (section *Cloudflare Tunnel*, *Updates*): copy them into
`launcher/Resources/it.lproj/Localizable.strings` (the Windows app reads that file too, so they can then be
removed from the Windows file).

## 4. Release

Bump `VERSION` to `1.0.1`, commit, tag `v1.0.1`, push, then start the build by hand —
`gh workflow run build.yml --ref v1.0.1` — because commits carry `[skip ci]` and GitHub applies it to tag
pushes too. `build.yml` already ignores `windows/**` changes. Verify both DMGs and the sources tar on the
release, and that the macOS release stays "Latest".

## 5. Also useful to know

- Windows-only things that macOS already has natively: single instance, `.vv`/`spice://` handling, noVNC and
  shells embedded (Windows still opens them in the browser).
- The maintainer will test keyboard, mouse, clipboard and audio of the Windows console by hand.
- Test installs on Windows must use another installer AppId (see `CLAUDE.md`).
