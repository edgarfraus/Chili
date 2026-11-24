### What's new in 1.1.0

From this version on, **one release carries both apps**: the Mac DMGs and the Windows installer share a
version number and are published together.

- **Windows users:** install this version by hand once (download the setup below and run it over the
  existing install; servers and settings are kept). Earlier Windows versions look for the old separate
  `windows-v…` releases and won't see this one; from 1.1.0 on, **Update Now** works again.
- **Mac users:** nothing changes; **Update Now** in the banner at the top of the window installs it.
- Same features on both systems: SPICE console, Cloudflare Tunnel and Cloudflare Access, automatic updates,
  English and Italian.

### Download

| Your computer | File |
|---|---|
| Mac with Apple Silicon (M1, M2, M3, M4…) | `Chili-*-arm64.dmg` |
| Mac with Intel | `Chili-*-x86_64.dmg` |
| Windows 10 (1809) or later, 64-bit | `Chili-*-x64-setup.exe` |

**Mac:** not sure which one? Apple menu → **About This Mac** → look at *Chip* (Apple M…) or *Processor*
(Intel). Open the DMG and drag **Chili** into **Applications**. If macOS refuses to open it the first time,
go to **System Settings → Privacy & Security** and click **Open Anyway** (see the
[guide](../../#first-launch)).

**Windows:** run the setup. It installs for your user only (no administrator rights needed; "Install for
all users" is offered too), adds Chili to the Start menu and, if you leave the options ticked, opens `.vv`
files and `spice://` links with Chili. On Windows on ARM the x64 build runs under emulation. The installer
isn't code-signed yet, so Windows may say **"Windows protected your PC"**: click **More info → Run anyway**.
Not yet on Windows: the Windows key and Alt+Tab go to Windows, not to the VM; there's no settings page yet.

Each file has a `.sha256` next to it, to check it's the one built by GitHub Actions.

### Sources

`Chili-*-sources.tar` (macOS) and `Chili-*-windows-sources.tar` (Chili's source plus the MSYS2 source
packages of remote-viewer, spice-gtk, GTK, GStreamer…) contain the exact source code of every bundled
component, as required by the GPL.
