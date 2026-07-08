# JoeScreen

A native **macOS + iOS/iPadOS** shared-desktop app in the spirit of CoScreen: multiple people
simultaneously share individual application windows, and each shared window appears on every other
participant's desktop as a **real, native, movable window filled with a live video stream** — with
per-participant cursors and the ability to click/type/draw into any shared window at once, routed
back to the owning Mac without stealing its focus.

> **Status: Phase 1 — working calls.** The macOS app runs a real call: join by link/launch-arg →
> connect to a self-hosted LiveKit SFU → share a window (ScreenCaptureKit → VP9) → every peer renders
> it as a live, movable native `NSWindow`, with voice, coalesced cursors, and mirrored session state.
> The end-to-end media pipeline (capture → VP9 encode → SFU → decode → render) is verified against a
> live `livekit-server --dev`; an iOS viewer app builds + runs. The remaining live gates — the
> two-instance screenshot and iOS render — need one-time **human steps** (Screen Recording / mic TCC,
> an iOS URL-scheme tap); SharePlay's runtime needs 2 devices on different iCloud accounts. See
> `TESTING.md` for the two-tier gate status and the PENDING human run-book.

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

## Monorepo layout

This is a **bun + turborepo** monorepo (the JS tooling is only the task runner / single-command
entrypoint — the app itself is Swift, built by Xcode):

```
.                      repo root: package.json (bun workspaces), turbo.json, bunfig.toml, scripts/
├─ apps/
│  ├─ joescreen/       the Swift project — Package.swift, Sources/, Tests/, Apps/ (macOS + iOS)
│  └─ livekit/         self-hosted LiveKit SFU config + token server (dev + docker-compose)
├─ scripts/           dev.sh (the single command), app.sh, livekit.sh
└─ docs/  README.md  DECISIONS.md  RISKS.md  TESTING.md
```

## Quickstart — one command

Requires `bun`, `livekit-server` (`brew install livekit`), and `xcodegen` (`brew install xcodegen`).

```bash
bun install          # once — installs turbo
bun run dev          # starts the LiveKit dev SFU, builds, and launches the macOS app joined to it
```

`bun run dev` starts `livekit-server --dev` (reusing one if already running), builds the
`JoeScreen-macOS` app, and launches it joined to `ws://localhost:7880`. Ctrl-C stops the SFU. Open a
second window in the same room (to get a real two-party call) with:

```bash
bun run app          # build + launch another instance (fresh identity, same "demo" room)
bun run dev my-room  # or use a custom room name
```

Then in instance A: **Share → pick a window** (grant Screen Recording once); B watches it live in a
native window. Component scripts are also runnable on their own: `bun run livekit` (just the SFU),
`bun run app` (just build+launch).

### Manual path (no bun)

The Swift/Xcode build is unchanged — run it directly from `apps/joescreen/`:

```bash
cd apps/joescreen
xcodegen generate --spec Apps/project.yml
xcodebuild -project Apps/JoeScreen.xcodeproj -scheme JoeScreen-macOS -derivedDataPath build build
APP=build/Build/Products/Debug/JoeScreen.app
open -n "$APP" --args --join-url ws://localhost:7880 --room demo --identity "$(uuidgen)"
```

The iOS viewer app (viewer + voice only — iOS can't be remote-controlled), from `apps/joescreen/`:

```bash
xcodebuild -project Apps/JoeScreen.xcodeproj -scheme JoeScreen-iOS \
  -destination 'generic/platform=iOS Simulator' build
```

## Build & test (the primary machine gate)

The shared logic lives in a Swift package so `swift build`/`swift test` is the fast, offline,
hardware-free green gate:

```bash
swift build          # 6 library targets; JoeScreenKit at Swift 6 + strict concurrency
swift test           # 117 tests, 5 skipped (integration/capture need a server/TCC), 0 failures
```

The LiveKit integration + voice tests run against a dev server (skip, never fail, when it's absent):

```bash
livekit-server --dev &
LIVEKIT_URL=ws://localhost:7880 swift test --filter JoeScreenLiveKitTests   # 5 tests, 0 failures
```

## Dependencies (pinned — `DECISIONS.md` D7)

Real, resolved tags (`Package.resolved` committed). Only `JoeScreenLiveKit` (the sole
libwebrtc-linking target) and the app layer link LiveKit; `JoeScreenKit` + its tests stay
dependency-free so the machine gate is fast and offline. SwiftTerm / swift-certificates stay
commented (dark) until their milestones (F12 terminal / LAN QUIC).

| Dependency | Pin | Status |
|---|---|---|
| `livekit/client-sdk-swift` | `2.15.1` | active (media plane) |
| `migueldeicaza/SwiftTerm`  | `1.13.0` | dark (F12) |
| `apple/swift-certificates` | `1.19.3` | dark (LAN QUIC) |
| `livekit/livekit-server` (`brew`/Docker) | `v1.13.3` | infra |

Graph rule: **no dependency that links a second libwebrtc may enter the graph.**

## Tooling

- **XcodeGen 2.42.0** generates `Apps/JoeScreen.xcodeproj` from `Apps/project.yml` (the committed
  source of truth; the `.xcodeproj` is gitignored). Regenerate: `xcodegen generate --spec
  Apps/project.yml`.
- **`livekit-server` 1.13.3** + **`lk` CLI 2.16.7** via `brew install livekit livekit-cli`.

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
- ✅ **Working macOS call app:** Direct Session Mode join (link / launch-arg / URL scheme), connect to
  a self-hosted LiveKit SFU, share a window (SCK → VP9), render every peer's window as a live movable
  `NSWindow`, voice on join, coalesced cursors, mirrored `RoomModel` over a reliable `state` channel.
- ✅ **Verified end-to-end** against `livekit-server --dev`: video A→B renders (real
  capture→VP9→SFU→decode→render), all six data channels round-trip, identity binding, audio
  publish/subscribe metadata. 117-test offline gate green; iOS viewer app builds + runs.
- ✅ SharePlay coordination layer (`GroupSessionCoordinator: SessionProviding`) compiles against the
  real GroupActivities framework + unit-tested against a `FakeSessionProvider`.
- ⏳ **PENDING human steps** (one dev Mac): the live two-instance screenshot (Screen Recording TCC),
  the audible-voice check (mic TCC), and the iOS live render (URL-scheme tap). **PENDING hardware** (2
  devices / different iCloud accounts): SharePlay runtime, F7-at-the-bound, glass-to-glass latency —
  see the `TESTING.md` run-book.
- 🔜 **Not yet built** (post-M4 phases per `BUILD_PROMPT.md` §7): input injection (F4/F5), clipboard
  (F6), draw (F9), terminal (F12), iOS broadcast extension — the tested `InputAuthorizer` /
  `CoordinateMapper` / `ClipboardSyncEngine` / `DrawModel` / `SecretRedactor` seams await their pumps.
