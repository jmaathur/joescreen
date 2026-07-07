# JoeScreen

A native **macOS + iOS/iPadOS** shared-desktop app in the spirit of CoScreen: multiple people
simultaneously share individual application windows, and each shared window appears on every other
participant's desktop as a **real, native, movable window filled with a live video stream** — with
per-participant cursors and the ability to click/type/draw into any shared window at once, routed
back to the owning Mac without stealing its focus.

> **Status: foundation / Phase 0.** APIs verified against live Apple docs + the local SDK
> `.swiftinterface` headers; the shared logic package builds and passes 84 unit tests; the networked
> and platform-framework pieces are scaffolded behind seams. Nothing has been run on paired hardware
> — see `TESTING.md` for the two-tier gate status and the PENDING human run-book. This is **not** a
> shippable app yet.

## Architecture in one paragraph

Two planes (full detail in `docs/architecture.md`). **Coordination plane = SharePlay / Group
Activities** — session start (which also gives free FaceTime voice), participant presence, and a
low-rate signaling/state channel. **Media plane = a self-hosted LiveKit SFU** — all real-time media
(per-window video, cursors, input, clipboard, terminal, draw, fallback audio) travels here, never
over SharePlay's messenger (which is capped and throttled). Input injection on the target Mac forces a
**non-sandboxed Developer-ID** build. See `DECISIONS.md` for every choice and `RISKS.md` for what's
unverified.

## Requirements

- **Xcode 26.1+** (floor), Swift 6.2 toolchain.
- Deployment floor **macOS 14.0 / iOS 17.0**, built with the 26.1 SDK (`DECISIONS.md` D2).
- For the media plane: a reachable **LiveKit server** (or `livekit-server --dev` on the LAN for local
  testing). See `infra/`.

## Build & test (the primary machine gate)

The shared logic lives in a Swift package so `swift build`/`swift test` is the fast, offline,
hardware-free green gate:

```bash
swift build          # 5 library targets, Swift 6 + strict concurrency
swift test           # 84 tests, 0 failures — wire protocol, auth, mapping, admission, codec, …
```

The app + broadcast-extension **product** targets live in an Xcode project layer
(`Apps/JoeScreen.xcodeproj`, added in a later phase) that consumes this package. Scheme names:
`JoeScreen-macOS`, `JoeScreen-iOS`, `JoeScreenKit-Package`. Expected `xcodebuild` invocations once the
project layer exists:

```bash
xcodebuild -scheme JoeScreen-macOS -destination 'platform=macOS' build
xcodebuild -scheme JoeScreen-iOS   -destination 'generic/platform=iOS' build
```

## Dependencies (pinned — `DECISIONS.md` D7)

Real, resolved tags (verified 2026-07-07). The default `swift build`/`swift test` gate targets are
**dependency-free** (pure logic); the `.package(...)` lines in `Package.swift` are present but
commented, to be enabled for the Xcode app layer.

| Dependency | Pin |
|---|---|
| `livekit/client-sdk-swift` | `2.15.1` |
| `migueldeicaza/SwiftTerm`  | `1.13.0` |
| `apple/swift-certificates` | `1.19.3` |
| `livekit/livekit-server` (Docker) | `v1.13.3` |

Graph rule: **no dependency that links a second libwebrtc may enter the graph.**

## Signing (`TEAM_ID` placeholder strategy — `DECISIONS.md` D6, `RISKS.md` R2)

The macOS app ships **non-sandboxed, notarized Developer ID, outside the Mac App Store** (input
injection needs Accessibility, which the sandbox forbids). Signing reads a `TEAM_ID` env var:

- `TEAM_ID` **set** → use it as the `DEVELOPMENT_TEAM`.
- `TEAM_ID` **unset** → automatic/ad-hoc signing (fine for local `swift`/build; **not** notarizable).

Notarization, provisioning profiles, App Group registration, and TCC grants are **human steps** — see
`RISKS.md` R2 and `TESTING.md`.

## Server (media plane)

```bash
cd infra
docker compose up          # pins livekit-server v1.13.3 + the JWT token endpoint
# or, for local loopback testing without certs:
livekit-server --dev
```
See `infra/README.md`. **The API secret lives only in the token server, never in the app.** Media is
plaintext in SFU memory until E2EE (v1.x) — `RISKS.md` R3.

## Repo layout

```
Package.swift              # the machine gate: all library targets
Sources/
  JoeScreenKit/            # shared brain: wire protocol, session, transport seam, codec, input auth,
                           #   clipboard, terminal redaction, admission, presence, room, draw, audio
  JoeScreenBridge/         # App Group IPC (host ↔ iOS broadcast extension); dependency-free
  JoeScreenCaptureMac/     # macOS SCStream capture + pause/black-frame detection
  JoeScreenInputMac/       # macOS CGEvent injection + correct-TCC-service preflight (Dev-ID)
  JoeScreenUI/             # shared SwiftUI feature layer
Tests/                     # 84 tests across the non-networked seams
Apps/                      # Xcode product targets (macOS app, iOS app, broadcast extension) — later phase
infra/                     # self-hosted LiveKit SFU (docker-compose, config, token server)
Spikes/                    # Phase-0 throwaway spikes (encode-loopback, injection, SFU load, codec A/B)
docs/architecture.md       # the two-plane architecture, kept current
DECISIONS.md RISKS.md TESTING.md
```

## What works today vs. what's PENDING
- ✅ Verified API surface, green package build + 84 tests, complete architecture + decision/risk docs,
  pinned deps, server infra ready to deploy.
- ⏳ All networked behavior, capture/encode/decode/render on-device, input injection, the iOS
  broadcast extension, and every F1–F14 acceptance criterion — **PENDING hardware** (`TESTING.md`).
