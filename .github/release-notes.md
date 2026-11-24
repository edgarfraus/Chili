### What's new in 1.0.2

- **Cloudflare Access**: a Proxmox hostname protected by Access works with a service token, entered in the
  new *Cloudflare Access* section of the server settings. Chili sends it with every API request and from
  the noVNC and shell consoles. An Access login page (or any other login page in front of Proxmox) is now
  reported clearly instead of as "unexpected response".
- The SPICE tunnel moved to its own *SPICE tunnel (Cloudflare)* section, independent of Access; a checkbox
  sends the Access token to the tunnel hostname too (see the [guide](../../#through-a-cloudflare-tunnel)).

Updating from 1.0.1: **Update Now** in the banner at the top of the window.

### Download

| Your Mac | File |
|---|---|
| Apple Silicon (M1, M2, M3, M4…) | `Chili-*-arm64.dmg` |
| Intel | `Chili-*-x86_64.dmg` |

Not sure? Apple menu → **About This Mac** → look at *Chip* (Apple M…) or *Processor* (Intel).

Open the DMG and drag **Chili** into **Applications**. If macOS refuses to open it the first time,
go to **System Settings → Privacy & Security** and click **Open Anyway** (see the
[guide](../../#first-launch)).

`*-sources.tar` contains the exact source code of every bundled component, as required by the GPL.
