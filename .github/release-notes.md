### What's new in 1.0.1

- **Automatic updates**: Chili checks GitHub for new releases and installs them with **Update Now**
  (can be turned off in Settings). From this version on, updating no longer means downloading the DMG.
- **SPICE through a Cloudflare Tunnel**: if Proxmox is published with `cloudflared`, enter the hostname of
  the tunnel's TCP service for spiceproxy under **SPICE tunnel** in the server settings. No WARP or
  `cloudflared` needed on the Mac (see the [guide](../../#through-a-cloudflare-tunnel)).

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
