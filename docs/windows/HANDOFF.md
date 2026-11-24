# Windows — build and check after the macOS session (handoff, 2026-11-24)

Read `CLAUDE.md` first (working rules, EDG_Lab etiquette, dev aids). Answer the maintainer in Italian.
Everything is on `main`; pull it first.

## What changed since `windows-v1.0.4` (all already in the Windows code, written on the Mac without compiling)

1. **One release for both systems, from v1.1.0** (released, installed by the maintainer, works).
   `build.yml` calls `build-windows.yml` on `v*` tags; `Updates.cs` now looks for `v*` releases with a
   `-x64-setup.exe` and ignores `windows-v*`. Tests updated (`UpdateTests`). Nothing to do but keep it in
   mind: a release = bump `VERSION`, commit without `[skip ci]`, tag `v<version>`.
2. **SPICE tunnel is generic, not Cloudflare-only** (commit "SPICE tunnel: any WebSocket bridge…").
   The tunnel always was a plain WebSocket ↔ TCP pipe; only the wording changed:
   - `Views/ServerEditorDialog.cs`: section "SPICE tunnel (WebSocket)", row "Address" (was "Hostname"),
     new caption ("Only if the spiceproxy (port 3128) can't be reached directly: a WebSocket that leads to
     it, such as a Cloudflare Tunnel TCP service (spice.example.com) or websockify
     (ws://pve.example.com:8443/). Leave empty otherwise.").
   - `Services/Consoles.cs`: disconnected detail `"SPICE tunnel (%@): %@"` (was "Cloudflare Tunnel (%@): %@").
   - Italian for all of them is in `launcher/Resources/it.lproj/Localizable.strings` (section *SPICE tunnel*).
   - README (en/it): new section *Through a WebSocket, without Cloudflare (websockify)*.

## To do on the Windows machine

1. **Build and test:** `dotnet build windows/src/Chili/Chili.csproj -p:Platform=x64` and
   `dotnet test windows/tests/Chili.Core.Tests` (the "every UI string has Italian" test covers the new
   strings). CI on `main` builds it too; check its result first.
2. **Look at the server editor** in both languages, with the sections open:
   `CHILI_DEMO=1 CHILI_LANG=it CHILI_DEBUG_ACTION=edit-remote CHILI_DEBUG_SNAPSHOT=<dir>` (then `en`).
   The longer caption must wrap, not widen the dialog or get cut off.
3. **Regression:** `CHILI_DEBUG_ACTION=spicetunnel:<vmid>` on a VM that is **already running** (e.g. 103
   W11; never start the maintainer's VMs, send no input). Expect bridged websockets ≥ 4, console connected.
4. **websockify, never tried yet** (on the Mac, installing it from PyPI was not allowed). Open question:
   Chili's WebSocket offers **no subprotocol**; recent websockify should accept that as binary, but check.
   On Windows, with the maintainer's OK to install it:
   ```
   py -m venv %TEMP%\wsv && %TEMP%\wsv\Scripts\pip install websockify
   %TEMP%\wsv\Scripts\websockify 6080 192.168.250.104:3128
   ```
   Then point the tunnel at `ws://localhost:6080/`. Don't edit the maintainer's saved server for this:
   add an env var to `DebugSpiceTunnelAsync` (e.g. `CHILI_DEBUG_TUNNEL_URL`) that skips the in-process
   bridge and uses that URL instead, run `spicetunnel:<vmid>`, and check the console connects and
   websockify logs the connections. If websockify refuses the handshake, the fix is to offer the
   `binary` subprotocol in `TcpOverWebSocket` (`ClientWebSocket.Options.AddSubProtocol("binary")`) — and
   on macOS in `launcher/Sources/Tunnel.swift` (`webSocketTask(with:protocols:)` can't take a request with
   headers, so set the `Sec-WebSocket-Protocol` header on the URLRequest) — but only after checking that
   a Cloudflare Tunnel still accepts it (the in-process bridge doesn't care either way). Report what you
   find in this file.
5. Commit with `[skip ci]` unless a CI run is wanted; push to `main`.
