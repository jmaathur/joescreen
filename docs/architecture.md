# JoeScreen Architecture

Kept current. The one idea that dictates everything: **SharePlay cannot stream media.** Group
Activities is a coordination + small-data framework (`GroupSessionMessenger` caps at ~256 KB/message
and throttles bursts; `GroupSessionJournal` is async ≤100 MB file sync; the only media API,
`AVPlaybackCoordinator`, syncs *playback commands* for media each device already has). There is **no
API to stream arbitrary live screen video over SharePlay.** So the system has **two planes**.

```
┌───────────────────────── COORDINATION PLANE — SharePlay / Group Activities ─────────────────────────┐
│  • Start the session (GroupActivitySharingController on macOS → also gives free FaceTime voice)      │
│    Gate on GroupStateObserver.isEligibleForGroupSession; prepareForActivation() returns              │
│    GroupActivityActivationResult {.activationPreferred/.activationDisabled/.cancelled} (NOT Bool),   │
│    then activate() async throws -> Bool.                                                             │
│  • Presence / roster — opaque Participant UUIDs (the only identity SharePlay exposes)                │
│  • GroupSessionMessenger (≤200 KB chunks, .reliable/.unreliable): transport bootstrap               │
│    {LiveKit URL, room, JWT}; low-rate session state (who shares which window, control/write flags,   │
│    pause/unshare); batched trickle-ICE ONLY in LAN-mesh mode.                                        │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
                                              │  bootstrap {url, room, jwt}
                                              ▼
┌────────────────────────────── MEDIA PLANE — self-hosted LiveKit SFU ────────────────────────────────┐
│  Every client dials OUT to the SFU (symmetric-NAT failure disappears; embedded TURN/TLS on :443).   │
│  Star topology for ALL sessions (1:1..10). Per shared window: one video track. Typed data channels: │
│                                                                                                     │
│   cursor    unreliable / unordered   latest-wins, coalesced, never retransmit stale positions       │
│   input     reliable  / ordered      monotonic seq + source id; owner injects in receipt order      │
│   clipboard reliable  / ordered      UTF-8-exact text first (code); size/type limits                │
│   terminal  reliable  / ordered      PTY bytes (post-redaction) — a separate, much-lower-latency path│
│   draw      reliable  / ordered-per-author   vector ink                                              │
│   video     WebRTC media track (RTP/SRTP) — NOT a data channel                                      │
│                                                                                                     │
│  LAN alt (shipped dark): Network.framework Bonjour + QUIC — Phase-0(d) fallback / same-LAN mode.     │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

The channel semantics are **opposite per payload** and enforced at the type level: `MessageKind`
fixes each payload's `DataChannel`, and `ChannelPolicy` fixes each channel's reliability/ordering, so
"a keystroke on the lossy cursor channel" cannot be expressed. (`Sources/JoeScreenKit/WireProtocol/`.)

## Why the SFU (not mesh) — the math

Full-mesh egress = `(peers−1) × windows × bitrate`. A host sharing 2 windows at 3–5 Mbps to 9 peers
needs **54–90 Mbps up** — beyond typical uplinks. *And* libwebrtc instantiates one encoder per
RTPSender per PeerConnection, so mesh costs `(N−1)` encode sessions per window while base Apple Silicon
has a **single hardware encode engine** — mesh fails F7 even on a LAN where bandwidth is free. The SFU
needs exactly one encoder per window and one uplink copy per host regardless of peer count. See
`DECISIONS.md` D3/D4 and `Sources/JoeScreenKit/Transport/AdmissionController.swift`
(three-sided admission: sharer uplink ≤70%, receiver visible-window decode cap, host encode cap).

## Capture

- **macOS** (`JoeScreenCaptureMac`): one `SCStream` per window via
  `SCContentFilter(desktopIndependentWindow:)`; `showsCursor=false` (remote cursors render in an
  overlay); explicit 420v pixel format; `minimumFrameInterval=1/30`; frames → a low-latency
  `VTCompressionSession` (H.264, `EnableLowLatencyRateControl` + explicit `AverageBitRate`, no
  B-frames) or libvpx VP9 for the single-window text-legibility path. **Minimize = unshare.** Off-Space
  frame gaps = **pause, not disconnect** (`PauseDetector`). DRM/HDCP windows = black frames, detected
  and surfaced.
- **iOS** (`JoeScreenBridge` + broadcast extension): ReplayKit broadcast upload extension, ≤720p,
  immediate per-frame H.264 encode under the ~50 MB jetsam ceiling; **encoded** frames handed to the
  host over an App Group ring buffer (`EncodedFrameRingBuffer`), and the **host** owns the LiveKit Room
  (the group-session entitlement is app-only, so the extension can't join SharePlay).

## Native window recreation (the core magic — F1/F2)

Each remote shared window becomes a **real movable/resizable `NSWindow`** on macOS (a zoomable Metal /
`AVSampleBufferDisplayLayer` view on iOS), with the sharer's color as a border. Receiver-side resize is
**local scaling only** — it never reflows the sender's window, and never changes the input coordinate
mapping (`CoordinateMapper` always resolves against the owner's real bounds). Multi-cursor presence is a
transparent, click-through overlay window drawing every participant's pointer at ~60 fps in per-window
coordinates.

## Input, security, and the distribution constraint

Injecting mouse/keyboard on the target Mac uses `CGEvent`, gated by **`kTCCServicePostEvent`**
(Accessibility) — a *different* service from what `AXIsProcessTrusted()` checks, and **unavailable to
sandboxed apps**. That single fact forces the macOS app to be a **non-sandboxed Developer-ID** build
(D6). Injection is the highest-consequence surface, so authorization is enforced **on the owner at
injection time** (`InputAuthorizer`): the message sender must equal the DTLS/SFU-authenticated peer, the
owner's remote-control master switch must be on, the window must be owned + in Control mode (default is
**Watch**), a valid owner-issued write capability must exist, and the soft single-active-controller lock
must admit this driver. Coordinates are **clamped to the window's bounds** before injection so a
malicious peer can't address other windows. Synthetic events are tagged so local input always wins.
In-band control flags (which ride the coordination plane) **never** authorize on their own.

## Coordination-plane loss

Media (client↔SFU) survives `GroupSession` invalidation by construction. On loss, `SessionManager`
re-establishes signaling and re-broadcasts full session state; late-joiners (who get no messenger
backlog) are resynced, with a `GroupSessionJournal` snapshot for durable room state.

## Terminal (F12) — a separate text path

A real PTY on the host streams **bytes, not video**, over the reliable/ordered `terminal` channel to
SwiftTerm views on all peers — dramatically lower latency than screen sharing, and iOS is a first-class
client (text, not injection). `SecretRedactor` masks obvious credentials **before** transmit
(best-effort, explicitly **not** a security boundary).

## Module map

| Module | Role |
|---|---|
| `JoeScreenKit` | Shared brain: wire protocol + channel matrix, session/roster/room models, `MediaTransport` seam (LiveKit built, LAN-QUIC dark), signaling discipline (ICE batching, send-queue backpressure), codec selection + VT wrappers, input authorization + coordinate mapping, clipboard sync, terminal redaction, admission control, draw model. Pure/Sendable, dependency-free, unit-tested. |
| `JoeScreenBridge` | App Group IPC between the iOS host app and broadcast extension. Dependency-free (fits the extension budget). |
| `JoeScreenCaptureMac` | macOS SCStream capture, minimize=unshare, pause/black-frame detection. |
| `JoeScreenInputMac` | macOS CGEvent injection, correct-TCC-service preflight, secure-input detection, AX focus-assist, pasteboard monitor. Developer-ID, non-sandboxed. |
| `JoeScreenUI` | Shared SwiftUI feature layer (roster, share controls, remote-window chrome, cursor/draw overlays, terminal view, onboarding). |
| `Apps/*` (Xcode layer) | macOS app (real NSWindow recreation, overlays, PTY host, sharing-controller presenter), iOS app (zoomable viewer, broadcast picker, host bridge reader), broadcast extension. |
| `infra/*` | Self-hosted LiveKit SFU: docker-compose (pinned v1.13.3), server config, JWT token server. |

## Deviations from the original build spec (see DECISIONS.md)
- **Transport:** `livekit/client-sdk-swift` + a self-hosted LiveKit SFU, replacing the spec's
  `stasel/WebRTC` + mesh-for-tiny/relay-for-big design (D3/D4). Forced by the encode-engine + uplink
  math above; confirmed by user sign-off. The mesh survives only as a dark, feature-flagged same-LAN
  mode.
