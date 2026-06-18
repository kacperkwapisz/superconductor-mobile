# Superconductor Mobile

Native **iOS companion** for [Superconductor](https://super.engineering) on macOS. Official `sc` local API only—no SSH, no tmux.

## What's in the repo

| Component | Path | Role |
|-----------|------|------|
| **Mac bridge** | `apps/bridge` | REST + WebSocket adapter over `sc … --json` |
| **iOS app** | `apps/ios` | SwiftUI: pair → agents → live Pi terminal snapshots |
| **Protocol** | `packages/protocol` | Shared TypeScript types |
| **sc client** | `packages/sc-client` | Typed subprocess wrapper + subscribe JSONL |

Design: [`docs/plans/2026-06-18-superconductor-mobile-design.md`](docs/plans/2026-06-18-superconductor-mobile-design.md)

## Requirements

- macOS 14+ with **Superconductor.app running**
- [Bun](https://bun.sh) on the Mac (bridge)
- Xcode 15+ (iOS)
- **Tailscale** (recommended) or same LAN for phone → Mac

## Mac bridge

The recommended way is the native **Mac menu bar companion** (see below).

You can still run the bridge manually:

```bash
bun install
bun run bridge:start
```

On first run, credentials are written to `~/.superconductor-mobile/bridge.json` (`token`, `fingerprint`, `port` default **9477**).

Optional env:

- `SC_MOBILE_BRIDGE_PORT` — listen port
- `SC_MOBILE_BRIDGE_BIND` — default `0.0.0.0`
- `SC_MOBILE_BRIDGE_HOST` — host shown for pairing (default: first LAN IPv4)

Verify:

```bash
curl -s http://127.0.0.1:9477/v1/health
curl -s -H "Authorization: Bearer YOUR_TOKEN" http://127.0.0.1:9477/v1/agents
```

## Mac Companion (recommended)

A small native macOS menu bar app that hosts the bridge + shows a beautiful QR code for instant pairing.

1. Build the standalone bridge binary (from repo root):

```bash
bun run companion:build-bridge
# or: bun run --cwd apps/bridge build:standalone
```

2. (Recommended) Install [XcodeGen](https://github.com/yonaskolb/XcodeGen), then:

   ```bash
   cd apps/mac/SuperconductorMobileCompanion
   xcodegen generate
   open SuperconductorMobileCompanion.xcodeproj
   ```

   Or manually create a macOS App in Xcode and drop in the sources + Info.plist. Set deployment target macOS 14.0+.

3. Build & run. You will see a menu bar icon ( phone symbol).

4. Click it → popover shows a scannable QR code containing the full pairing payload.

5. On iPhone: paste host/port/token or (future) scan QR. The iOS app continues to use the exact same HTTP/WS contract.

Key behaviors:
- Auto-starts the bridge child process when the companion launches.
- "Regenerate Token" writes a new `~/.superconductor-mobile/bridge.json` and restarts the server.
- Prefers Tailscale (`tailscale ip -4`) when present; otherwise best LAN IP.
- Set to "Launch at login" via macOS Users & Groups / Login Items (or the app can call `SMAppService`).

For packaging a distributable `.app`, see `apps/mac/build-companion.sh`. Embed the `bridge-server` executable inside the bundle.

The public REST + WebSocket surface stays 100% stable. The iPhone app does not change.

## iOS app

Generate Xcode project (requires [XcodeGen](https://github.com/yonaskolb/XcodeGen)):

```bash
cd apps/ios
./scripts/prepare-icon-composer.sh
xcodegen generate
open SuperconductorMobile.xcodeproj
```

**iOS 26+ only.** App icon uses **Icon Composer** (`AppIcon.icon` + Liquid Glass). Regenerate layers from the Mac app: `apps/ios/scripts/prepare-icon-composer.sh`, then open `AppIcon.icon` in **Icon Composer** (Xcode → Open Developer Tool) to tune Dark / Clear / Tinted.

Run on device or simulator. **Pair Mac**:

1. Copy `token` from `~/.superconductor-mobile/bridge.json` on the Mac.
2. Enter your Mac’s **Tailscale IP** (or LAN IP), port `9477`, and token.
3. Open **Agents** → your **Pi** session → live stream + composer.

## Terminal on iPhone

Pi stays in Superconductor’s terminal on the Mac. The app shows **`terminal_snapshot`** lines from `sc agent subscribe` and sends input via `sc agent send`—the supported, documented path.

## Security

- Treat the bridge token like a password.
- Prefer Tailscale; do not port-forward to the public internet.
- HTTPS/TLS for the bridge is planned; v1 uses HTTP on a private network.

## License

Private / your project—add license as needed.