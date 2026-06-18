# Superconductor Mobile — Design

## Product

A **native iOS companion** for [Superconductor](https://super.engineering) on macOS. Use your Pi (and other) agents, worktrees, and review surfaces while away from the desk—without SSH, tmux, or screen hacks.

## Principles

1. **Official surface only** — All Mac-side behavior goes through the bundled `sc` CLI and documented local API semantics ([CLI and local API](https://super.engineering/docs/cli-local-api/)).
2. **First-party feel** — Native SwiftUI, system typography, calm motion, pairing flow comparable to AirPods-style device trust.
3. **Honest terminal UX** — Pi runs in Superconductor’s terminal; mobile shows **`terminal_snapshot`** streams from `sc agent subscribe`, not a fake remote PTY.
4. **Security by default** — Bridge binds to Tailscale interface or loopback; bearer token + optional pairing code; no public internet exposure.

## Architecture

Current (v1):
```
iOS (SwiftUI)  --HTTPS/WSS (bearer + token)-->  Mac Bridge (Bun/TS)
                                                      |
                                                      v  (sc CLI + Unix socket)
                                             Superconductor.app
```

Target (third-party Swift companion we control):
```
iOS (SwiftUI)  --HTTPS/WSS (bearer)-->  Superconductor Mobile Companion (Swift menu bar app)
                                             |
                                             + hosts adapter (Bun today, Swift later)
                                             + shows QR + status
                                             + talks only to official sc + local socket
                                             + always available while installed
```

The public contract (REST + WS + pairing JSON) is stable. iOS does not care if the server on the Mac is our Bun process today or a pure-Swift implementation tomorrow.

### Mac Bridge / Companion

- **Role:** Adapt `sc … --json` and JSONL `sc agent subscribe` into a stable **REST + WebSocket** contract for iOS (over LAN or Tailscale). The bridge is the network surface; the iOS app never talks the Unix socket directly.
- **Current runtime:** TypeScript + Bun (fast iteration, shares packages/protocol with this repo).
- **Target (third-party):** A first-class Swift menu-bar / status item companion (owned here) that users install on the same Mac as Superconductor. It makes the bridge "always on" with nice QR pairing without requiring `bun run`.
  - We continue to speak *only* the official `sc` + local socket contract (we do not own or modify Superconductor.app).
  - If the main team later wants to absorb the listener, the iOS contract remains unchanged.
- **Discovery:** `~/.superconductor/local-api.json`; the companion refuses to start (or shows clear error) if `sc status` / the socket fails.
- **Streaming:** One subscribe child (or direct) per active WebSocket; forward payloads unchanged.

### iOS App

- **SwiftUI** (iOS 17+), `@Observable` models, `URLSessionWebSocketTask` for streams.
- **Screens:** Pairing → Agents → Agent session (terminal view + composer) → Worktree (status, diff summary, review checklist).
- **Terminal view:** Monospace `Text` with diff-friendly updates from snapshot `lines[]`; status bar from last line when detectable; pull-to-refresh via `sc agent read`.

### Protocol (v1)

| Method | Path | Description |
|--------|------|-------------|
| GET | `/v1/health` | Liveness (no auth) |
| GET | `/v1/status` | `sc status --json` |
| GET | `/v1/agents` | `sc agents list --json` |
| GET | `/v1/agents/:target/snapshot` | `sc agent read --last 80` |
| WS | `/v1/agents/:target/stream` | `sc agent subscribe --live-only` |
| POST | `/v1/agents/:target/send` | `{ "text", "prefill?", "queue?" }` |
| POST | `/v1/agents/:target/interrupt` | `sc agent interrupt` |
| POST | `/v1/agents/:target/stop` | `sc agent stop` |
| GET | `/v1/worktree/status` | `?path=` → `sc worktree status` with `cwd` |

`:target` is URL-encoded `id:terminal:…` or `view:1/tab:1/pane:1`.

### Pairing

1. Bridge shows **pairing payload** (JSON): `{ "host", "port", "token", "fingerprint" }`.
2. iOS scans QR or pastes URL `superconductor-mobile://pair?...`.
3. Token stored in Keychain; all requests use `Authorization: Bearer`.

### Pi-specific behavior

- Prefer agents with `provider_key == "pi"` and `ui == "terminal"`.
- Subscribe events include `session_id` (Pi JSONL path) and `conversation_id` for future structured sidecar (not required for v1).
- Send uses `sc agent send --prompt` (steer agent); optional `--prefill` for typing into terminal without submitting.

## Non-goals (v1)

- Raw ANSI terminal emulator with full scrollback history.
- Terminal-backed session control beyond documented agent commands.
- File uploads / user-input answer flows omitted by Superconductor API v1.
- Android.

## Success criteria

- With Superconductor running on Mac and bridge started, iPhone can list Pi agent, watch live terminal snapshots, send a message, and interrupt—over Tailscale—with no SSH.