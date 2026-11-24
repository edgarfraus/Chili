### Download

Download **`Chili-*-x64-setup.exe`** and run it. It installs for your user only (no administrator rights
needed; "Install for all users" is offered too), adds Chili to the Start menu and, if you leave the options
ticked, opens `.vv` files and `spice://` links with Chili. Windows 10 (1809) or later, 64-bit. On Windows on
ARM the x64 build runs under emulation.

The installer isn't code-signed yet, so Windows may say **"Windows protected your PC"**: click
**More info → Run anyway**. Compare the file with its `.sha256` if you want to be sure it's the one built
by GitHub Actions.

### What's in this first Windows release

- Proxmox servers with password (+ TOTP) or API token, secrets in Windows Credential Manager, trust on
  first use for Proxmox' self-signed certificate.
- VMs and containers with live CPU/RAM dials and network rates; start, shut down, reboot, stop, delete.
- **Built-in SPICE console** in the main window: resizes the VM to the window (with the SPICE agent),
  shared clipboard, audio, Ctrl+Alt+Del, full screen. Quick Connect for any SPICE server.
- New VM (recommended preset or every option) and new container wizards; history & logs per VM;
  system log per node.
- **SPICE through a Cloudflare Tunnel** without WARP or cloudflared on the PC: publish the spiceproxy
  (`tcp://localhost:3128`) on its own hostname and enter it under *SPICE tunnel* in the server settings
  (see the README, *Network requirements*).
- **Cloudflare Access** supported with a service token (Client ID + Secret in *Remote access (Cloudflare)*);
  an Access login page is now reported as such instead of showing its HTML.
- English and Italian.

Not yet on Windows: noVNC, container consoles and the node shell open in your browser (Proxmox asks you to
log in there); the Windows key and Alt+Tab go to Windows, not to the VM; there's no settings page yet.

`*-windows-sources.tar` contains Chili's source and the MSYS2 source packages of every bundled component
(remote-viewer, spice-gtk, GTK, GStreamer…), as required by the GPL.
