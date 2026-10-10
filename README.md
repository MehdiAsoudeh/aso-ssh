# ASO VPN

macOS system-wide VPN over SSH using [sshuttle](https://github.com/sshuttle/sshuttle).  
GUI is **Objective-C (Cocoa)**; tunnel logic is **Bash** (`vpn.sh`).

No server credentials are baked into the source. Connection settings are empty until you save them in the app.

## Requirements

- macOS 12+
- Xcode Command Line Tools (`xcode-select --install`)
- [Homebrew](https://brew.sh) (the app can install `sshuttle` on first connect)
- Admin password once (for transparent tunnel / pf)

## Build

```bash
git clone <your-repo-url> aso-vpn
cd aso-vpn
chmod +x build.sh vpn.sh
./build.sh
open "dist/ASO VPN.app"
```

Universal binary: `arm64` + `x86_64`.

## Usage

1. Open **ASO VPN**
2. Click **Config** → enter Host / User / Password / Port → **Save Config**
3. Click **Connect** and allow admin access once
4. Traffic is tunneled system-wide (TCP + DNS)

Config file (created only after Save):

```text
~/Library/Application Support/ASO VPN/vpn.conf
```

## Project layout

| Path | Role |
|------|------|
| `VPNApp.m` | macOS GUI |
| `vpn.sh` | sshuttle / privilege / tunnel control |
| `build.sh` | compile + package `.app` |
| `resources/AppIcon.icns` | app icon |

## Notes

- Deleting the `.app` does **not** always remove the saved config under Application Support.
- Distributing a prebuilt `.pkg` without Apple Developer ID + notarization will be blocked by Gatekeeper on other Macs. Building from this source on each machine avoids that.

## License

Use and modify for your own needs. Add a license file if you publish publicly.
