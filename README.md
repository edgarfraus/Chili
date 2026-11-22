<p align="center">
  <img src="resources/icon/AppIcon.svg" width="128" alt="Chili icon">
</p>

<h1 align="center">Chili</h1>
<p align="center"><b>An unofficial SPICE client for macOS</b></p>

<p align="center">
  A native, self-contained SPICE remote viewer for macOS — with one-click Proxmox VE integration.
  <br>
  <a href="README.it.md">🇮🇹 Leggi in italiano</a>
</p>

<p align="center">
  <a href="../../releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/edgarfraus/chili-spice-macos?label=download"></a>
  <a href="../../actions/workflows/build.yml"><img alt="Build" src="https://img.shields.io/github/actions/workflow/status/edgarfraus/chili-spice-macos/build.yml?branch=main"></a>
  <img alt="macOS 12+" src="https://img.shields.io/badge/macOS-12%2B-blue">
  <a href="LICENSE"><img alt="License: GPL-2.0-or-later" src="https://img.shields.io/badge/license-GPL--2.0--or--later-green"></a>
</p>

---

Connecting to a virtual machine's SPICE console from a Mac has always meant Homebrew taps, XQuartz or
compiling GTK yourself. **Chili** is a regular drag-to-install app: it bundles the upstream
`remote-viewer` (virt-viewer + spice-gtk) with everything it needs, and adds a small native front end
that talks to Proxmox VE for you.

## Contents

- [Features](#features)
- [Download and install](#download-and-install)
- [First launch](#first-launch)
- [Using it with Proxmox VE](#using-it-with-proxmox-ve)
- [Quick Connect (QEMU, libvirt, others)](#quick-connect-qemu-libvirt-others)
- [Inside the viewer](#inside-the-viewer)
- [Troubleshooting](#troubleshooting)
- [Privacy and security](#privacy-and-security)
- [Building from source](#building-from-source)
- [How it works](#how-it-works)
- [Limitations](#limitations)
- [License and credits](#license-and-credits)

## Features

- **Proxmox VE built in.** Log in once (password, TOTP two-factor or API token), see all VMs of your
  cluster, double-click to open a console. Stopped VMs can be started from the list.
- **Built-in console, all in one window.** Consoles open inside Chili, listed in the sidebar next to your
  servers; any of them can be moved to its own window (or full screen) and back. Native macOS display,
  keyboard, mouse, clipboard and audio, written directly on spice-glib — no GTK window involved.
- **noVNC, containers and node shells too.** VMs without SPICE automatically open Proxmox' own noVNC
  console, LXC containers its xterm.js console, and the toolbar's **Shell** menu opens a shell on any node —
  all in the same tabs. (These web consoles need a password login, not an API token.)
- **Create and manage VMs and containers without the web UI.** A *New VM* wizard with two modes — *Recommended for
  Chili* (just the essentials, everything else set up for the best console experience) and *Custom*
  (every option, as in Proxmox) — plus shut down, reboot, stop and delete from each VM's menu.
- **Opens `.vv` files.** The files that the Proxmox web UI downloads (*Console → SPICE*), or that oVirt
  and virt-manager produce, open with a double-click in a bare console window, without the rest of the app.
- **Quick Connect** to any SPICE server by host and port, and `spice://` links.
- **Self-contained.** No Homebrew, MacPorts or XQuartz. Native Cocoa (Quartz) GTK backend.
- **Audio** playback and microphone via GStreamer, **hardware H.264/H.265 decoding** via VideoToolbox.
- Clipboard sharing and automatic resolution when the guest runs the SPICE agent.
- Passwords and tokens stored in the macOS **Keychain**; self-signed certificates checked by fingerprint.
- English and Italian user interface.
- Apple Silicon and Intel builds, reproducible from source with one command.

## Download and install

1. Open the [**latest release**](../../releases/latest) and download the DMG for your Mac:

   | Your Mac | Download |
   |---|---|
   | Apple Silicon (M1, M2, M3, M4…) | `Chili-<version>-arm64.dmg` |
   | Intel | `Chili-<version>-x86_64.dmg` |

   Not sure? Apple menu  → **About This Mac**: *Chip: Apple M…* means Apple Silicon,
   *Processor: Intel…* means Intel.

2. Open the DMG and drag **Chili** onto the **Applications** folder.
3. Eject the DMG and start Chili from Launchpad or Applications.

Requirements: macOS 12 Monterey or later.

## First launch

Unless the release says it is *notarized*, the app is signed ad hoc only, because notarization requires
a paid Apple Developer account. The first time you open it, macOS says it "cannot verify the developer"
or that the app "could not be opened". This is expected:

1. Click **Done** (or **OK**) in the dialog.
2. Open  → **System Settings → Privacy & Security**.
3. Scroll down to *Security*: you will see *"Chili" was blocked…*. Click **Open Anyway** and
   confirm with your password or Touch ID.

You only do this once. If you prefer the Terminal:

```sh
xattr -dr com.apple.quarantine "/Applications/Chili.app"
```

You can always check that the DMG you downloaded is the one built by GitHub Actions: each release
lists the SHA-256 of every DMG (`shasum -a 256 Chili-*.dmg`).

## Using it with Proxmox VE

### 1. Prepare the VM (once per VM)

In the Proxmox web UI, select the VM:

1. **Hardware → Display → Edit → Graphic card: `SPICE`** (shown as *SPICE (qxl)*). For multiple
   monitors choose *SPICE dual/triple/quad monitor*. Increase memory to 32–64 MiB for high resolutions.
2. Optional, for sound: **Hardware → Add → Audio Device**, device `ich9-intel-hda`, driver `SPICE`.
3. Shut the VM down and start it again: display changes need a full stop, not a reboot from inside.
4. Inside the guest, install the SPICE agent for clipboard sharing and automatic resize:
   - **Windows:** [spice-guest-tools](https://www.spice-space.org/download.html) (includes the QXL
     driver and the vdagent).
   - **Linux:** the `spice-vdagent` package (`apt install spice-vdagent`, `dnf install spice-vdagent`…).

### 2. Add your server

1. Start Chili and click **Add Server…** in the sidebar (or **File → New Proxmox Server…**, ⌘N).
2. Fill in:
   - **Host**: the address you use for the web UI, without `https://` and without `:8006`.
   - **Port**: `8006`, unless you changed it.
   - **Log in with → Password**: **User** (e.g. `root`) and **Realm** — `Linux PAM` for system users
     such as `root`, `Proxmox VE` for users created in the Proxmox UI. The realm list is read from your
     server as you type the host.
   - **Remember in Keychain** saves the password so the next login is automatic.
3. Click **Add**.

The first time you connect, the app shows the **certificate fingerprint** of your server: Proxmox uses a
self-signed certificate, which macOS cannot verify by itself. To make sure you are talking to your
server, in the Proxmox web UI open **your node → System → Certificates**, select `pve-ssl.pem` (or
your custom certificate), click **View Certificate** and compare the *Fingerprint*. If it matches, click **Trust and Continue**. The app remembers the
fingerprint and warns you again only if the certificate changes.

If your account has **two-factor authentication** (TOTP), you are asked for the 6-digit code after the
password. Recovery keys work too. WebAuthn/YubiKey-only accounts are not supported: use an API token.

### 3. Connect

The list shows every VM in the cluster, with its node, vCPUs and memory, and refreshes every 5 seconds. Running VMs show live CPU and memory dials and network traffic.

- Double-click a VM, or click **Connect**: the console opens in the main window and appears under
  **Consoles** in the sidebar. The window button next to *Connect* opens it in a separate window instead.
- For a stopped VM, **Start & Connect** boots it and opens the console as soon as it is up.
- Use the filter field to search by name or VM ID.

### Creating a VM

Click **New VM** in the server's toolbar.

- **Recommended for Chili**: choose node, name, operating system, installation ISO, CPU cores, memory,
  disk and network. Chili adds the rest: SPICE display and audio, QEMU guest agent, q35 machine,
  VirtIO SCSI disk with discard and IO thread, VirtIO network; for Windows 11 also UEFI with Secure Boot
  and TPM 2.0. For Windows, pick the `virtio-win.iso` drivers ISO too (Chili mounts it as a second CD);
  without it, Chili uses SATA and Intel network devices that Windows setup recognises by itself.
- **Custom**: every option of the Proxmox wizard (VM ID, BIOS, machine, SCSI controller, disk bus, cache,
  CPU sockets and type, ballooning, VLAN, display type, monitors…).
- The CPU type defaults to `x86-64-v2` (or `host` on very old CPUs): Proxmox' own default,
  `x86-64-v2-AES`, doesn't start on hosts without AES-NI.
- With **Start the VM and open its console** ticked, the new VM boots straight into a console tab.

Each VM's **…** menu also has **Shut Down**, **Reboot**, **Stop** and **Delete** (both ask first).

### Creating a container

**New → New Container…** creates an LXC container: hostname, template, root password and/or SSH key,
CPU, memory, disk, network (bridge, VLAN tag, DHCP or static). Chili makes it unprivileged with nesting enabled (what
systemd-based distributions and Docker need) and opens its console when it's up. The template list shows
those already on your storages and, under *Download from Proxmox*, the official catalogue: pick one and
Chili downloads it first. More options (ID, swap, IPv6, privileged, start at boot) are under *Advanced*.

### History and logs

- **… → History & Logs…** on any VM or container lists the tasks Proxmox ran for it (start, stop,
  backups, migrations, console sessions…) with result, user and duration; select one to read its full log.
  Running tasks update live.
- **Node → System Log** in the server toolbar shows the node's journal, with a filter and live follow.
  The same menu opens a **Shell** on the node.

### Using an API token instead of a password (recommended)

An API token can be revoked at any time, works with 2FA-protected accounts and can be limited to just
what the viewer needs.

1. In Proxmox: **Datacenter → Permissions → API Tokens → Add**. Choose the user, a *Token ID* such as
   `spice`, and keep *Privilege Separation* checked. Copy the secret: it is shown only once.
2. **Datacenter → Permissions → Add → API Token Permission**: path `/vms`, token `user@realm!spice`,
   role `PVEVMUser` (it includes `VM.Console`, `VM.Audit` and `VM.PowerMgmt`).
3. In Chili, edit the server, choose **Log in with → API token**, enter
   `user@realm!spice` as **Token ID** and paste the **Secret**.

### Network requirements

The Mac must reach the Proxmox host on:

| Port | Used for |
|---|---|
| TCP 8006 | Proxmox API (login, VM list) |
| TCP 3128 | `spiceproxy`, which carries the SPICE session |

The app asks Proxmox to route the session through the host you entered, so a single address is enough
even in a cluster. Over the internet, put both ports behind a VPN (WireGuard, Tailscale…) rather than
exposing them.

### Opening consoles from the Proxmox web UI

You can keep using the browser: **Console → SPICE** (the small arrow next to *Console*) downloads a
`.vv` file. Open it and Chili starts the viewer directly. The file contains a one-time ticket
valid for about 30 seconds, and the viewer deletes it after reading.

- **Chrome / Edge:** click the arrow next to the download → **Always open files of this type**.
- **Firefox:** when asked, choose *Open with Chili* and tick *Do this automatically*.
- **Safari:** open the file from the downloads list (Safari never auto-opens this kind of file).

## Quick Connect (QEMU, libvirt, others)

**Quick Connect** (⌘K) opens any SPICE server by address: enter host, port and password (if any).
Tick **Use TLS** when the port is a TLS port.

Examples of server-side configuration:

```sh
# QEMU: listen on all interfaces, port 5900, with a password
qemu-system-x86_64 ... -vga qxl -spice port=5900,addr=0.0.0.0,password-secret=sec0 \
  -object secret,id=sec0,data=s3cret \
  -device virtio-serial -chardev spicevmc,id=vdagent,name=vdagent \
  -device virtserialport,chardev=vdagent,name=com.redhat.spice.0
```

```xml
<!-- libvirt: <devices> section of the domain XML -->
<graphics type='spice' port='5900' autoport='no' listen='0.0.0.0' passwd='s3cret'/>
<video><model type='qxl'/></video>
```

Links of the form `spice://host:5900` also open in Chili, and **File → Open Connection File…**
(⌘O) opens any `.vv` file.

## Inside the viewer

| Action | How |
|---|---|
| Control the VM | click inside the console |
| Release the mouse when it's captured | **Ctrl+Alt** (the mouse is captured only while the guest has no agent/tablet, e.g. during Windows setup) |
| Full screen / separate window | toolbar buttons, or right-click the console in the sidebar |
| Send Ctrl+Alt+Del | toolbar button |
| Change resolution | resize the window (needs the SPICE agent in the guest) |
| Copy and paste between Mac and VM | just copy and paste (needs the SPICE agent) |

The **⌘ Command** key is sent to the VM as the *Super / Windows* key (app shortcuts such as ⌘Q still
work). In **Chili → Settings** you can choose where consoles open, full screen, whether the VM follows the
window size (and at Retina resolution), clipboard sharing, and fall back to the classic `remote-viewer`.

## Troubleshooting

Viewer logs are in `~/Library/Logs/Chili/remote-viewer.log` (**Help → Show Viewer Logs**). For
details, turn on **Settings → Verbose viewer logging** and reproduce the problem.

| Problem | Solution |
|---|---|
| *This VM has no SPICE display* | Set **Hardware → Display** to *SPICE*, then shut the VM down and start it again. |
| The viewer opens and closes immediately, *Connection refused* | TCP **3128** is not reachable from the Mac: check firewalls/VPN. On the node, `systemctl status spiceproxy`. |
| *Authentication failed* | Check user **and realm** (`root` is in `Linux PAM`). For tokens, the Token ID must be `user@realm!name`. |
| The `.vv` file from the browser does nothing / *ticket expired* | The ticket is valid for ~30 s: open the file right after downloading it, or use the built-in Proxmox list. |
| Certificate warning again after a Proxmox upgrade | The certificate changed: compare the new fingerprint, then trust it. **Settings → Forget Trusted Certificates** resets all. |
| No resize, no clipboard | Install `spice-guest-tools` (Windows) or `spice-vdagent` (Linux) in the guest. |
| No sound | Add an *Audio Device* with driver **SPICE** to the VM. |
| macOS asks to allow access to the Keychain | Click **Always Allow**. Without an Apple Developer ID signature, macOS asks again once after each update of the app. |
| The app "is damaged and can't be opened" | It was downloaded with quarantine and isn't notarized: see [First launch](#first-launch). |

## Privacy and security

- The app talks only to the servers you add. There is no telemetry and no update check.
- Passwords and token secrets are stored in your login Keychain only when *Remember in Keychain* is on.
- Proxmox certificates are accepted only after you confirm their SHA-256 fingerprint, which is then
  pinned per host and port.
- The one-time SPICE ticket is written to a temporary file readable only by you, which the viewer
  deletes as soon as it has read it.

## Building from source

Everything — about 30 libraries plus the viewer — is compiled from pinned, checksummed upstream
releases into `build/<arch>/prefix`, using an explicit macOS SDK sysroot. Homebrew, MacPorts and
anything else in `/usr/local` or `/opt` is **never** used, so the result runs on any Mac with
macOS 12 or later.

Requirements:

- macOS with the **Xcode Command Line Tools** (`xcode-select --install`); full Xcode also works.
- **Python ≥ 3.10** for the build tools (python.org, Homebrew or any other); set `PYTHON=/path/to/python3`
  if it isn't found automatically.
- About 8 GB of free disk space and an internet connection. Rust is installed automatically inside
  `build/` and doesn't touch your system.

```sh
git clone https://github.com/edgarfraus/chili-spice-macos.git
cd chili-spice-macos
make            # → dist/Chili-<version>-<arch>.dmg
```

The first build takes 30–90 minutes depending on the Mac; later builds reuse what is already compiled.
Other targets:

| Command | What it does |
|---|---|
| `make stack` | build only the libraries and `remote-viewer` |
| `make app` | assemble `dist/<arch>/Chili.app` |
| `make run` | assemble and open the app |
| `make test` | check that the bundle is self-contained and its plugins load |
| `make clean` / `make distclean` | remove `dist/` / remove everything, downloads included |

To rebuild a single component, delete its stamp: `rm build/<arch>/stamps/lib_spice_gtk && make`.
Build logs are in `build/<arch>/logs/`. Versions and checksums are at the top of
[`scripts/build-stack.sh`](scripts/build-stack.sh); our patches to upstream are in [`patches/`](patches).

Environment variables: `ARCH` (defaults to the current machine), `MACOSX_DEPLOYMENT_TARGET`,
`BUNDLE_ID`, `CODESIGN_IDENTITY` (a *Developer ID Application* identity, default ad hoc),
`NOTARY_PROFILE` (a `xcrun notarytool store-credentials` profile name).

### Releases

GitHub Actions ([`.github/workflows/build.yml`](.github/workflows/build.yml)) builds both architectures
natively on every push. Pushing a tag such as `v1.0.0` (matching the `VERSION` file) publishes a GitHub
release with both DMGs, their SHA-256 and a tarball of all sources.

To sign and notarize releases, add these repository secrets: `MACOS_CERTIFICATE` (base64 of a
*Developer ID Application* `.p12`), `MACOS_CERTIFICATE_PASSWORD`, and for notarization `APPLE_ID`,
`APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` (an app-specific password). Without them, builds are signed ad hoc.

## How it works

```
Chili.app
├── Contents/MacOS/Chili         ← Swift/SwiftUI launcher: Proxmox API, Quick Connect,
│                                         .vv and spice:// handling, Keychain
└── Contents/Helpers/Chili Viewer.app   ← upstream remote-viewer (virt-viewer)
    ├── MacOS/remote-viewer               spice-gtk · GTK 3 (Quartz) · GStreamer
    ├── Frameworks/                       every library, relocated to @rpath
    ├── PlugIns/                          GStreamer and gdk-pixbuf modules
    └── Resources/                        icons, GSettings schemas, translations
```

For a Proxmox VM, the launcher logs in to the API, asks
`POST /api2/spiceconfig/nodes/{node}/qemu/{vmid}/spiceproxy` for a one-time ticket — exactly what the
web UI does — writes it to a private temporary `.vv` file and starts `remote-viewer` on it with an
environment that points GTK, GStreamer and gdk-pixbuf at the bundle.

## Limitations

- **USB redirection**, **smart cards** and **folder sharing** (WebDAV) are not included yet.
- WebAuthn/U2F-only Proxmox logins aren't supported; use TOTP or an API token.
- The viewer window is GTK, so it looks slightly different from native Mac apps.

## License and credits

Chili is free software under the [GNU General Public License v2.0 or later](LICENSE).

It bundles, unmodified or with the small patches in [`patches/`](patches), the work of these projects
(licenses in brackets): [virt-viewer](https://gitlab.com/virt-viewer/virt-viewer) (GPL-2.0+),
[spice-gtk](https://gitlab.freedesktop.org/spice/spice-gtk) (LGPL-2.1+),
[GTK](https://gtk.org), GLib, Pango, gdk-pixbuf, ATK, librsvg, json-glib, libxml2 (LGPL / MIT),
[GStreamer](https://gstreamer.freedesktop.org) (LGPL-2.1+), cairo and pixman (LGPL-2.1 / MPL-1.1, MIT),
HarfBuzz, FreeType, Fontconfig, FriBidi, libepoxy, libffi, PCRE2, libpng, libjpeg-turbo, expat, Opus,
LZ4, OpenSSL (Apache-2.0), GNU gettext (LGPL-2.1+) and the Adwaita icon theme (CC-BY-SA-3.0 / LGPL-3.0).
Each release includes `Chili-<version>-sources.tar` with the exact sources of all of them.

This project is not affiliated with Red Hat, the SPICE project or Proxmox Server Solutions GmbH.
SPICE is a trademark of Red Hat, Inc.; Proxmox is a trademark of Proxmox Server Solutions GmbH.
