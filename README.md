# Superconductor Mobile

A native **iOS companion** for [Superconductor](https://super.engineering) on macOS — pair your phone with your Mac, browse your agents, and follow live Pi sessions from anywhere on your network. Built on the official `sc` local API only: no SSH, no tmux.

> [!IMPORTANT]
> **This is an unofficial, community-built project.** It is **not affiliated with, endorsed by, or supported by** Superconductor or its makers. "Superconductor" and related names are trademarks of their respective owners and are used here only to describe interoperability. Use at your own risk.

> [!NOTE]
> **TestFlight coming soon.** A public TestFlight build is planned so you won't need Xcode to try the app. Until then, build the iOS app yourself (see [iOS app](#ios-app)). This repo will track the TestFlight link here once it's live.

## How it works

```
iPhone  ──HTTP/WebSocket──▶  Mac bridge  ──▶  sc … --output json  ──▶  Superconductor.app
(SwiftUI)                    (Bun)             (official local API)
```

The Mac runs a small bridge that wraps the official `sc` CLI. The iPhone talks to that bridge over your private network (Tailscale or LAN). Pi keeps running inside Superconductor on the Mac — the phone is a live window into it.

## What's in the repo

| Component | Path | Role |
|-----------|------|------|
| **Mac bridge** | `apps/bridge` | REST + WebSocket adapter over `sc … --output json` |
| **Mac companion** | `apps/mac` | Menu bar app that hosts the bridge + QR pairing |
| **iOS app** | `apps/ios` | SwiftUI: pair → agents → live Pi sessions + composer |
| **Protocol** | `packages/protocol` | Shared TypeScript types |
| **sc client** | `packages/sc-client` | Typed subprocess wrapper + subscribe JSONL |

Design notes: [`docs/plans/2026-06-18-superconductor-mobile-design.md`](docs/plans/2026-06-18-superconductor-mobile-design.md)

## Requirements

- macOS 14+ with **Superconductor.app running**
- [Bun](https://bun.sh) on the Mac (bridge)
- Xcode 16+ and an iOS 26+ device (until TestFlight is available)
- **Tailscale** (recommended) or the same LAN for phone → Mac

## Quick start

1. **Run the bridge** on your Mac (menu bar companion recommended — see [Mac companion](#mac-companion-recommended)):

   ```bash
   bun install
   bun run bridge:start
   ```

   On first run, credentials are written to `~/.superconductor-mobile/bridge.json` (`token`, `fingerprint`, `port` default **9477**).

2. **Build and run the iOS app** (see [iOS app](#ios-app)).

3. **Pair**: enter your Mac's Tailscale/LAN IP, port `9477`, and the token from `bridge.json`.

4. Open **Agents** → your **Pi** session → live stream + composer.

Verify the bridge is up:

```bash
curl -s http://127.0.0.1:9477/v1/health
curl -s -H "Authorization: Bearer YOUR_TOKEN" http://127.0.0.1:9477/v1/agents
```

Optional bridge env:

- `SC_MOBILE_BRIDGE_PORT` — listen port (default `9477`)
- `SC_MOBILE_BRIDGE_BIND` — default `0.0.0.0`
- `SC_MOBILE_BRIDGE_HOST` — host shown for pairing (default: first LAN IPv4)

## Mac companion (recommended)

A small native macOS menu bar app that hosts the bridge and shows a scannable QR code for instant pairing.

1. Build the standalone bridge binary (from repo root):

   ```bash
   bun run companion:build-bridge
   # or: bun run --cwd apps/bridge build:standalone
   ```

2. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen), then:

   ```bash
   cd apps/mac/SuperconductorMobileCompanion
   xcodegen generate
   open SuperconductorMobileCompanion.xcodeproj
   ```

   (Or create a macOS App in Xcode and drop in the sources + Info.plist. Deployment target macOS 14.0+.)

3. Build & run — a menu bar icon appears. Click it for a QR code containing the full pairing payload.

Key behaviors:
- Auto-starts the bridge child process when the companion launches.
- "Regenerate Token" writes a new `~/.superconductor-mobile/bridge.json` and restarts the server.
- Prefers Tailscale (`tailscale ip -4`) when present; otherwise best LAN IP.
- "Launch at login" via macOS Login Items.

For a distributable `.app`, see `apps/mac/build-companion.sh` (embeds the `bridge-server` executable in the bundle).

## iOS app

Until the TestFlight build is out, generate the Xcode project ([XcodeGen](https://github.com/yonaskolb/XcodeGen) required):

```bash
cd apps/ios
./scripts/prepare-icon-composer.sh
xcodegen generate
open SuperconductorMobile.xcodeproj
```

**iOS 26+ only.** App icon uses **Icon Composer** (`AppIcon.icon` + Liquid Glass). Open `AppIcon.icon` in Icon Composer (Xcode → Open Developer Tool) to tune Dark / Clear / Tinted.

Run on device or simulator, then **Pair Mac**:

1. Copy `token` from `~/.superconductor-mobile/bridge.json` on the Mac.
2. Enter your Mac's **Tailscale IP** (or LAN IP), port `9477`, and token.
3. Open **Agents** → your **Pi** session → live stream + composer.

## Security

- Treat the bridge token like a password.
- Prefer Tailscale; **do not** port-forward the bridge to the public internet.
- The bridge currently uses HTTP on a private network; HTTPS/TLS is planned.

## Contributing

Issues and PRs are welcome. The public REST + WebSocket surface is intended to stay stable — keep the `sc` CLI as the only privileged path (no SSH/tmux shortcuts).

## License

[MIT](LICENSE) © 2026 Kacper Kwapisz.

Not affiliated with Superconductor. Trademarks belong to their respective owners.
