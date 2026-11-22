# Chili for Windows — plan and handoff

This document is the starting point for building the Windows version of Chili. It records what the
macOS version does, how it talks to Proxmox (everything below was verified against a real Proxmox VE
server), what went wrong along the way, and the plan agreed with the maintainer.

The maintainer will continue the work from a Windows machine. Read `CLAUDE.md` first (working rules,
test server etiquette).

---

## 1. Goal

Feature parity with the macOS app, as a native Windows app:

| Feature | macOS implementation | Windows |
|---|---|---|
| Saved Proxmox servers (password + TOTP 2FA, or API token), Keychain | `Store.swift`, `Proxmox.swift` | Credential Manager |
| Self-signed certificate: trust on first use, SHA-256 fingerprint pinned per host:port | `ProxmoxClient` delegate, `TrustStore` | `HttpClientHandler.ServerCertificateCustomValidationCallback` |
| VM + container list, refresh every 5 s, CPU/RAM dials, network rate | `Views.swift` (`VMRow`, `UsageView`, `Dial`) | custom control |
| SPICE console | native (SpiceKit) in tabs/windows; classic remote-viewer as fallback | **phase 1:** remote-viewer.exe; **phase 2:** embedded |
| noVNC / xterm.js consoles, node shell | WKWebView with ticket cookie | WebView2 |
| `.vv` files and `spice://` links | Info.plist document/URL types | file association + URL protocol |
| Quick Connect | `QuickConnectView` | same |
| New VM wizard (Recommended / Custom) | `VMDraft.swift`, `VMWizard.swift` | port the logic 1:1 |
| New container wizard | `ContainerWizard.swift` | port 1:1 |
| VM actions (shutdown, reboot, stop, delete with confirmation) | `ServerSession.power/delete` | same |
| History & logs (tasks + log), node system log | `LogsView.swift` | same |
| English + Italian UI | `it.lproj/Localizable.strings` (293 strings, keys = English) | `.resw` |
| Settings (console placement, full screen, resize guest, clipboard, classic viewer…) | `SettingsView` | same |

Non-goals for the first Windows release: USB redirection, smart cards, folder sharing (also missing on
macOS).

## 2. Recommended stack

- **C# / .NET 10 (LTS)** with **WinUI 3** (Windows App SDK), **unpackaged** app (no Store/MSIX needed),
  published self-contained for `win-x64` and `win-arm64`.
  - Why: native look on Windows 10/11, first-class WebView2, easy P/Invoke to spice-glib for phase 2,
    straightforward CI on `windows-latest`. WPF would also work; WinUI 3 matches the macOS app's look.
  - Alternative if WinUI 3 tooling gets in the way without Visual Studio: WPF on .NET 10 (same code
    structure, `Microsoft.Web.WebView2.Wpf`).
- **MVVM** with `CommunityToolkit.Mvvm` (observable properties, relay commands) — mirrors the SwiftUI
  `ObservableObject` models almost 1:1.
- **Installer:** Inno Setup or WiX. It must register the `.vv` file type
  (`application/x-virt-viewer`) and the `spice:` URL protocol, and install remote-viewer (phase 1).
- **Repo layout:** add a `windows/` folder (`windows/Chili.sln`, `windows/src/Chili/…`,
  `windows/installer/…`). Leave the macOS tree where it is for now; a later reorg into `macos/` is
  optional. Add a separate workflow `.github/workflows/build-windows.yml` with `paths:` filters so
  macOS and Windows builds don't trigger each other.

## 3. Proxmox API — exactly what Chili uses

Base URL `https://<host>:<port>` (default port 8006). All JSON responses are `{"data": …}`.

### Authentication

| Purpose | Request | Notes |
|---|---|---|
| Realms (login form) | `GET /api2/json/access/domains` | no auth; fails silently until the certificate is trusted |
| Password login | `POST /api2/json/access/ticket` form `username=root@pam`, `password`, `new-format=1` | returns `ticket`, `CSRFPreventionToken`; if `NeedTFA: 1` the ticket is a TFA challenge |
| TOTP step | same endpoint, form `username`, `tfa-challenge=<ticket>`, `password=totp:<code>` (`recovery:<key>` for recovery keys) | |
| Ticket renewal | same endpoint with `password=<current ticket>` | tickets expire after 2 h; Chili renews when (re)loading web consoles |
| Using a ticket | header `Cookie: PVEAuthCookie=<ticket>`; for non-GET also `CSRFPreventionToken: <token>` | |
| API token | header `Authorization: PVEAPIToken=<user@realm!id>=<secret>` | no CSRF; validate with `GET /api2/json/version` |

**Form encoding gotcha (cost us a day):** Proxmox splits form bodies on `;` as well as `&`. Values like
`boot=order=scsi0;ide2;net0` then silently lose `ide2`/`net0` (errors: "unable to parse drive options",
"net0 … got undefined value"). **Percent-encode every key and value strictly**: only
`A–Z a–z 0–9 - . _ ~` stay literal. `application/x-www-form-urlencoded`.

**Error messages:** on HTTP 4xx/5xx the body has `message` and, for "Parameter verification failed.",
an `errors` object with one entry per parameter. Show both. Some failures only have the reason in the
HTTP status line (e.g. spiceproxy on a non-SPICE VM): detect those yourself (see below).

### Inventory and VM list

| Purpose | Request |
|---|---|
| All VMs and containers + live usage | `GET /api2/json/cluster/resources?type=vm` → keep `type` `qemu`/`lxc`, drop `template==1`. Fields: `vmid name node status type maxmem maxcpu cpu (0–1) mem netin netout (cumulative bytes) …` |
| Nodes | `GET /api2/json/nodes` (`node`, `status`) |
| Next free ID | `GET /api2/json/cluster/nextid` — `data` is a **string** on most versions, a number on some |
| Node status (cores, RAM, CPU flags) | `GET /api2/json/nodes/{node}/status` → `cpuinfo.cpus`, `cpuinfo.flags`, `memory.total` |
| Storages by content | `GET /api2/json/nodes/{node}/storage?content=images|iso|rootdir|vztmpl&enabled=1` |
| ISOs / templates on a storage | `GET /api2/json/nodes/{node}/storage/{storage}/content?content=iso` (or `vztmpl`) → `volid` like `local:iso/x.iso` |
| Bridges | `GET /api2/json/nodes/{node}/network?type=any_bridge` |
| Template catalogue | `GET /api2/json/nodes/{node}/aplinfo` (keep `section == "system"`) |
| Download template | `POST /api2/json/nodes/{node}/aplinfo` form `storage`, `template` → UPID |

Network rate = delta of `netin`/`netout` between two refreshes ÷ elapsed seconds. Proxmox updates the
counters about every 10 s, so rates are coarse.

### Consoles

| Purpose | Request |
|---|---|
| SPICE ticket as a `.vv` file | `POST /api2/spiceconfig/nodes/{node}/qemu/{vmid}/spiceproxy` form `proxy=<the host you connect to>` → body is an INI `[virt-viewer]` file (`host`, `tls-port`, `password`, `proxy=http://host:3128`, `ca` with literal `\n`, `host-subject`, `delete-this-file`, …). The ticket is valid ~30 s and single-use. |
| Does the VM have SPICE? | on a 5xx from spiceproxy, `GET /api2/json/nodes/{node}/qemu/{vmid}/config` → `vga` starting with `qxl` means SPICE. Otherwise fall back to noVNC. |
| noVNC (VM) page | `https://host:port/?console=kvm&novnc=1&vmid=…&vmname=…&node=…&resize=scale` |
| xterm.js (container) | `/?console=lxc&xtermjs=1&vmid=…&vmname=…&node=…` |
| Node shell | `/?console=shell&xtermjs=1&node=…` |

The web pages need the cookie `PVEAuthCookie=<ticket, percent-encoded>` (domain = host, path `/`,
secure). **API tokens cannot log these pages in** — tell the user. Self-signed certificate: accept only
if its fingerprint is pinned (same store as the API client).

Ports: TCP 8006 (API, web consoles), TCP 3128 (spiceproxy, carries SPICE).

### Power, delete, tasks, logs

| Purpose | Request |
|---|---|
| Power | `POST /api2/json/nodes/{node}/{qemu|lxc}/{vmid}/status/{start|shutdown|reboot|stop|reset|suspend|resume}` → UPID |
| Delete (must be stopped) | `DELETE /api2/json/nodes/{node}/{type}/{vmid}?purge=1&destroy-unreferenced-disks=1` → UPID |
| Wait for a task | poll `GET /api2/json/nodes/{node}/tasks/{UPID}/status` until `status=stopped`; `exitstatus == "OK"` is success; otherwise show `exitstatus` + last lines of the log |
| Task log | `GET /api2/json/nodes/{node}/tasks/{UPID}/log?limit=5000` → `[{n, t}]` |
| Task history of a VM | `GET /api2/json/nodes/{node}/tasks?vmid={id}&limit=100&source=all` |
| Node journal (latest lines) | `GET /api2/json/nodes/{node}/journal?lastentries=1000` → array of strings. Drop the cursor lines (`s=…;i=…;b=…`) and `-- …` markers. **Don't use `/syslog`**: it pages from the oldest entry. |
| VM/CT config | `GET /api2/json/nodes/{node}/{type}/{vmid}/config` (containers: `hostname`, VMs: `name`) |

Always **wait for the start task** before waiting for `running`: a failed start ("QEMU exited with
code 1") otherwise looks like a timeout. URL-encode the UPID in paths.

### Creating a VM — `POST /api2/json/nodes/{node}/qemu`

Port `VMDraft.parameters` and `applyChiliPreset()` (`launcher/Sources/VMDraft.swift`) 1:1. Verified
parameter set (Windows 11, "Recommended for Chili", with drivers ISO):

```
vmid=106 name=… ostype=win11 machine=q35 bios=ovmf
efidisk0=local-lvm:1,efitype=4m,pre-enrolled-keys=1   tpmstate0=local-lvm:1,version=v2.0
scsihw=virtio-scsi-single  scsi0=local-lvm:64,discard=on,iothread=1,ssd=1
ide2=<windows iso volid>,media=cdrom   ide0=<virtio-win iso volid>,media=cdrom
sockets=1 cores=4 cpu=x86-64-v2 memory=8192
net0=virtio,bridge=vmbr0,firewall=1[,tag=<vlan>]
vga=qxl  audio0=device=ich9-intel-hda,driver=spice  agent=enabled=1
boot=order=scsi0;ide2;net0
```

Preset rules:
- Linux/other: `bios=seabios`, no TPM, SCSI + VirtIO NIC, `ssd` off.
- Windows 10: OVMF, no TPM. Windows 11: OVMF + TPM.
- Windows **without** the VirtIO ISO: disk `sata0`, NIC `e1000e` (setup recognises them without drivers).
- `iothread=1` only for `virtio` disks or SCSI with `virtio-scsi-single`; `ssd=1` not on `virtio`.
- Audio only with the SPICE display. `qxl2..4` for multiple monitors.
- **CPU type default `x86-64-v2`** (or `host` when the node lacks the v2 flags
  `cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3`). Proxmox' default `x86-64-v2-AES` fails to start on hosts
  without AES-NI — the maintainer's server is one of them. The maintainer asked for v2/host explicitly.
- Validation before enabling *Create*: node, disk storage, bridge chosen; VM ID ≥ 100; name matches
  `^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$`.
- After creation: wait for the task, reload the list, optionally start (wait for the task) and open the
  console. Use the name from the form for the console title (the list may still say `VM 106`).

### Creating a container — `POST /api2/json/nodes/{node}/lxc`

Port `ContainerDraft.parameters` (`launcher/Sources/ContainerWizard.swift`). Verified:

```
vmid=106 hostname=… ostemplate=<volid> unprivileged=1 features=nesting=1
cores=1 memory=256 swap=512 rootfs=local-lvm:2
net0=name=eth0,bridge=vmbr0[,tag=<vlan>],ip=dhcp|<cidr>[,gw=<gw>],ip6=auto|dhcp,firewall=1
password=… and/or ssh-public-keys=…   onboot=1 (optional)
```

If the chosen template comes from the catalogue, download it first (task, can take minutes), then use
`<storage>:vztmpl/<template>`. Validation: template chosen, password ≥ 5 chars and confirmed, or an SSH
key; static IPv4 must contain `/`.

## 4. SPICE on Windows

### Phase 1 — remote-viewer (ship this first)

On Windows, `remote-viewer.exe` (virt-viewer) is mature: none of the macOS problems (crashes on
clipboard, erratic mouse, GTK quirks) apply. Chili writes the `.vv` from spiceproxy to
`%TEMP%\chili-<guid>.vv` (ACL: current user only), with `delete-this-file=1`, and starts
`remote-viewer.exe <file>`; remote-viewer deletes it after reading. Optional keys Chili adds:
`title`, `fullscreen=1`.

Getting remote-viewer:
- **MSYS2** (`mingw-w64-ucrt-x86_64-virt-viewer` and its dependencies), copied into the app folder with
  the DLLs it needs (`ldd`/`ntldd` to collect them), plus `share/` data (icons, GSettings schemas,
  GStreamer plugins). Reproducible in CI on `windows-latest` with `msys2/setup-msys2`. Preferred.
- Or the official `virt-viewer-x64-11.0-1.0.msi` from virt-manager.org (older, 2021).
- GPL: ship the corresponding sources (the macOS release already attaches a sources tarball; do the same).

`.vv` double-click and `spice://` links: the installer registers them to Chili, which either opens
remote-viewer directly (bare console, like macOS) or adds a tab.

### Phase 2 — embedded console (later, if wanted)

Same design as SpiceKit (`launcher/SpiceKit/CSConnection.m`, `CSDisplayView.m`), with spice-glib from
MSYS2 via P/Invoke (or a thin C shim DLL exposing a flat API, which is easier than marshalling GObject
signals from C#):
- Run `g_main_loop_run` on a dedicated thread; marshal every call with `g_main_context_invoke`.
- Display: `display-primary-create` (format, width, height, stride, pointer), `display-invalidate`,
  `display-primary-destroy`, `display-mark`. Copy the frame **under a lock** that `primary-destroy` also
  takes. Format `SPICE_SURFACE_FMT_32_xRGB` = BGRX little-endian → `WriteableBitmap`/`SwapChainPanel`.
- Keyboard: Windows already uses PC set-1 scancodes. Take the scancode from the key event (`lParam`
  bits 16–23) and OR `0x100` for extended keys (`lParam` bit 24) → `spice_inputs_channel_key_press`.
- Mouse: client mode (agent or tablet) → `spice_inputs_channel_position`; server mode (e.g. Windows
  setup without drivers) → capture with `ClipCursor` + raw input deltas, release with Ctrl+Alt.
- Clipboard: `main-clipboard-selection-grab/-request/` signals + `spice_main_channel_clipboard_selection_*`
  (text `VD_AGENT_CLIPBOARD_UTF8_TEXT`, images `IMAGE_PNG`; CRLF handling via
  `VD_AGENT_CAP_GUEST_LINEEND_CRLF`).
- Audio: `spice_audio_get(session, NULL)` — **transfer none**, do not unref it.
- Resize: `spice_main_channel_update_display_enabled` + `update_display(…, TRUE)`.

## 5. Windows-specific pieces

- **Credentials:** Windows Credential Manager (`CredWriteW`/`CredReadW` via P/Invoke, target
  `Chili/<server id>`), or `Windows.Security.Credentials.PasswordVault`. Read once per launch; write
  only when the secret changes. (No equivalent of the macOS Keychain prompts.)
- **Settings and server list:** `%APPDATA%\Chili\settings.json` (servers without secrets, pinned
  fingerprints `host:port → SHA-256`, preferences).
- **Certificate pinning:** `HttpClientHandler.ServerCertificateCustomValidationCallback`: accept if the
  chain is valid, else compute SHA-256 of the leaf (`cert.GetCertHash(HashAlgorithmName.SHA256)`) and
  accept only if pinned; otherwise surface "untrusted certificate" with the fingerprint (formatted
  `AA:BB:…`) for the user to compare with *Node → System → Certificates → View Certificate*.
- **WebView2:** set the cookie with `CoreWebView2.CookieManager.CreateCookie("PVEAuthCookie", …)`;
  handle `ServerCertificateErrorDetected` with the same pin check; open new-window requests in the
  default browser. One `CoreWebView2Environment` per server keeps cookies separate.
- **Localization:** convert `launcher/Resources/it.lproj/Localizable.strings` to `.resw` (keys are the
  English strings; a small script can do it).
- **Demo mode** (`CHILI_DEMO=1`) and **debug snapshots**: worth reproducing early — they made UI work
  verifiable without bothering the maintainer.

## 6. UI

Mirror the macOS layout (screenshots in `docs/screenshots/`):
- Left pane (`NavigationView` in WinUI): **Consoles** (open sessions, status dot), **Quick Connect**,
  **Proxmox Servers**, *Add Server…* at the bottom.
- Server page: toolbar with **New** (VM / Container), **Node** (shell, system log per node), refresh,
  log out, edit. Filter field + "Show stopped VMs". Rows: status dot, ID, name, "Container · node · vCPU ·
  RAM", two dials (CPU, RAM; colour accent → orange > 70% → red > 90%), ↓/↑ rate, **Connect** /
  **Start & Connect**, **…** menu (separate window, noVNC, shut down, reboot, stop, history & logs, delete).
- Console page: the display (or web view) filling the pane; toolbar: Ctrl+Alt+Del (SPICE only), open in
  window, full screen, disconnect; overlays: connecting, disconnected with reason + Reconnect, "click to
  control the mouse" / "Ctrl+Alt to release".
- Wizards and logs as dialogs (sizes ~640×680 and ~980×620 on macOS).

## 7. Lessons from the macOS version

- **Form encoding:** see §3. Percent-encode everything.
- **Proxmox errors:** combine `message` and `errors`; for task failures read the task log.
- **CPU type:** `x86-64-v2` default (see §3).
- **Cluster list lag:** right after create, names/hostnames may be missing; don't rely on them for
  safety checks — read the config.
- **Layouts:** on macOS, a SwiftUI `Form` inside a `ScrollView` or with flexible content inflated the
  window to thousands of points and pushed everything off-screen (wizard fields invisible; Quick Connect
  blanked the window). Use explicit grids/rows with fixed label columns, and check every screen visually.
- **Closing a console:** change the selection first, remove the session afterwards; an embedded native
  view must not report an intrinsic size to the layout system.
- **Journal vs syslog:** use `/journal?lastentries`.
- **GTK on macOS** needed patches (quartz event loop assertion on clipboard, relative mouse); not an
  issue on Windows, where GTK/remote-viewer are mature.

## 8. Testing

- **Unit-level:** parameter generation for VM/CT drafts (compare with the verified sets in §3),
  `.vv` parsing, host normalisation (`https://pve:8006/#v1:0:…` → host `pve`, port 8006), form encoding.
- **UI:** demo mode + screenshots of every screen before handing over.
- **Live, on EDG_Lab** (rules in `CLAUDE.md`): inventory (read-only); create `chili-test-*` VMs in the
  four variants (Linux, Windows 11 with/without drivers, custom) and compare their config; create
  `chili-test-ct` from the Alpine template; start one into its console; read task history and journal;
  delete everything you created (name check against the config).
- **SPICE without a VM:** `scripts/dev/test-input-server.c` (spice-server's demo display + input logging)
  can be built under MSYS2 too, or run on the Mac and reached over the LAN (it listens on 5912, no
  password — only on a trusted network, stop it afterwards).

## 9. CI and release

- `build-windows.yml` on `windows-latest`: MSYS2 for remote-viewer + DLLs, `dotnet publish -c Release
  -r win-x64 --self-contained` (and `win-arm64`), installer, upload artifacts.
- The existing `build.yml` release job collects artifacts from all jobs; either extend it to include
  the Windows artifacts on `v*` tags, or let the Windows workflow attach its files to the same release
  (`gh release upload`).
- Unsigned installers trigger SmartScreen ("Windows protected your PC" → More info → Run anyway);
  document it like Gatekeeper on macOS. Code signing (e.g. Azure Trusted Signing) can come later.

## 10. Suggested order of work

1. Skeleton: WinUI 3 app, settings/credentials store, server editor, login (password, TOTP, token),
   certificate pinning, VM list with dials. Demo mode. Screenshots.
2. Consoles: phase 1 remote-viewer (bundled), `.vv` + `spice://` handling; noVNC/xterm.js/shell in
   WebView2 tabs.
3. Wizards (VM, container), actions, history & logs, node journal.
4. Italian localization, installer, `build-windows.yml`, README section for Windows.
5. Optional: phase 2 embedded SPICE console.

## 11. State of the macOS side at handoff (2026-11-22)

- Repo: `github.com/edgarfraus/Chili` (private at the time of writing; the maintainer is about to make
  it public). Latest work is on `main`.
- Pending for macOS v1.0.0: first GitHub Actions run (arm64 has never been built; expect fixes in
  `scripts/build-stack.sh` for Apple Silicon), then tag `v1.0.0`.
