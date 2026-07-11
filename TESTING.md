# TESTING.md — JoeScreen

Two-tier gates (build spec §9). The agent owns the **machine sub-gate**; the **hardware sub-gate** is
a human run-book, recorded PENDING. **No result here is fabricated** — anything not actually run on
hardware says PENDING.

---

## Tier 1 — Machine sub-gate (owned by the agent)

### Status: ✅ GREEN (2026-07-10, M11 + backlog)

```
swift build     → Build complete (6 library targets; JoeScreenKit at Swift 6 + StrictConcurrency,
                  JoeScreenLiveKit at Swift 5 per-target per D1)
swift test      → Executed 288 tests, 7 skipped (integration + capture-TCC), 0 failures
                  (266 through M11 + 22 backlog: InputWireBackCompat 8, InputEventPlanner 11,
                  SecureInputBanner 3)
```

5 tests SKIP (via `XCTSkip`, not fail) offline (landmine #7): the 4 `JoeScreenLiveKitTests`
integration tests (video A→B, 6-channel, identity, voice metadata) skip without `LIVEKIT_URL`, and
the capture smoke test skips without a TCC-granted host. With a dev server the LiveKit suite passes:
```bash
livekit-server --dev &
LIVEKIT_URL=ws://localhost:7880 swift test --filter JoeScreenLiveKitTests   # 5 tests, 0 failures
```

Run it yourself:
```bash
swift build
swift test
```

### What the 84 tests cover (the non-networked seams)

| Suite | Asserts |
|---|---|
| `WireProtocolRoundTripTests` (8) | Every payload encodes→decodes byte-stable; envelope versioning + **unknown-kind tolerance** (skip, not fatal); `seq` present exactly on kinds whose channel requires it; kind-mismatch on unpack; multi-line UTF-8 code paste byte-intact; the full channel matrix (cursor=unreliable/unordered … input=reliable/ordered+seq). |
| `SequenceTrackerTests` (8) | In-order accept, duplicate drop, gap/loss detection with the missing range, **out-of-order-arrival-reads-as-duplicate** (M0: the unreachable `.outOfOrder` case was removed — a behind-cursor seq is dropped as `.duplicate` on the never-stalling ordered channel), per-sender independence, re-baseline on forget, monotonic generator. |
| `CoordinateMapperTests` (6) | Normalized→global mapping, corner/center correctness, **out-of-bounds clamp (the security clamp)**, AppKit bottom-left→CG top-left flip, local-resize-invariance, round-trip. |
| `InputAuthorizerTests` (11) | Happy-path inject + **every deny path**: spoofed sender (peer-identity mismatch), global-disabled, Watch mode (incl. default-is-Watch), no/expired write capability, unknown window, single-active-controller lock blocks others, lock holder injects, atomic hand-off. |
| `AdmissionControllerTests` (6) | SFU admit-under-budget, degrade-over-budget, refuse-below-floor, **encode-session cap refuses regardless of bandwidth**, mesh (N−1) multiplier, decode-window cap. |
| `CodecSelectorTests` (6) | VP9 single-window start, H.264 structural start (≥2 windows / whole display), each fallback trigger (p95 encode, thermal, sustained-low-fps-with-motion), **one-way hysteresis** (no auto-return to VP9), healthy = no fallback. |
| `ClipboardDiffTests` (5) | changeCount increment → one send, **echo suppression** after apply, multi-line code byte-intact, oversize/type rejection, identical-changeCount = no traffic. |
| `SecretRedactorTests` (10) | AWS/GitHub/SSN/key=value/high-entropy masking, clean text unchanged, low-entropy long word NOT masked, entropy math, non-UTF-8 pass-through, Data path. |
| `ICEBatcherTests` (7) | Coalesce N candidates → one batch, debounce timing, immediate flush past window, forced end-of-candidates flush (incl. empty), idempotent merge. |
| `SignalingQueueTests` (7) | Oversize rejected before the messenger, backpressure at max depth, success removes, **retry with backoff on throw**, exhausted-attempts drop, FIFO order, per-peer handshake stagger. |
| `RingBufferTests` (5) | FIFO, capacity-overflow drops oldest, byte-budget drops oldest, never-blocks under a flood, drain. |
| `PauseDetectorTests` (6) | complete-frames stay active, frame-stop-after-motion = pause, resume on next complete, idle-without-motion ≠ pause, suspended→pause, no double-pause edge. |
| `ChunkerTests` (11) *(M0)* | Small payload = one chunk; large payload splits + reassembles byte-intact; out-of-order + duplicate fragments; interleaved groups; wire round-trip; empty payload; realistic 120 KB clipboard image under LiveKit's 15 KB cap; inconsistent-count + out-of-range rejected. |
| `CursorCoalescerTests` (7) *(M6)* | Outbound coalesce-to-latest per window, one-per-window, ignore-older-sample, flush-empties; inbound latest-wins, per-(sender,window) independence, forget-rebaselines. |
| `SessionCoordinationTests` (6) *(M7)* | TransportBootstrap + room-snapshot coordination round-trips (<200 KB); `FakeSessionProvider` start/join/fail/participant-stream/invalidation; bootstrap fits `SignalingSendQueue`. |
| WireProtocol *(M0 additions)* | `RoomSnapshot`/`ShareEvent` round-trip on the new `state` channel; extended channel matrix (6 channels); coverage for Capability/Draw/TerminalControl payloads. |

### What the machine gate deliberately does NOT prove
Anything requiring a network, a second device, a running SFU, or TCC grants. Those are Tier 2.
The framework-touching code (SessionManager, LiveKitTransport, VTCompressionSession wrappers, SCStream
capture, CGEvent injection) is scaffolded behind seams but its runtime behavior is unverifiable here.

### Milestone machine-gate results (this session)

| Milestone | Gate | Result |
|---|---|---|
| **M0** | `swift build && swift test` green (84+new) | ✅ 99 tests, 0 failures; LiveKit 2.15.1 resolved + `Package.resolved` committed. |
| **M1** | `xcodegen generate` + `xcodebuild -scheme JoeScreen-macOS` builds AND the app **launches** (no Killed: 9) | ✅ **BUILD SUCCEEDED**; app launches (ad-hoc signed, empty entitlements → only `com.apple.security.get-task-allow`, NO restricted `group-session` entitlement) and stays running via both `open -n` and the `--join-url/--room/--identity` launch-arg path. Verified `codesign -d --entitlements -` shows no restricted entitlement (the Killed-9 landmine is avoided). |
| **M2** | Integration suite skips unless `LIVEKIT_URL` set; two Rooms in one process — synthetic frames A→B received; all six channels round-trip; identity binding | ✅ Against `livekit-server --dev`: **video A→B renders in ~1 s** (real VP9 encode→SFU→decode→render, verified via the `VideoRenderer` hook), **all six data channels** round-trip an Envelope with correct topic/reliability (Chunker over reliable channels), **identity binding** surfaces the right ParticipantID. Offline `swift test` = **102 tests, 3 skipped (integration), 0 failures**. DevTokenMinter validated against the real server (its tokens are accepted). Findings recorded as R31 (contentHint gap), R32 (adaptiveStream renderer visibility gates frames), R33 (monotonic timestamps required). |
| **M3** | Capture smoke run receives ≥N `.complete` frames from a real window and forwards them into a `VideoFrameSink` | ✅ (built) `WindowCaptureService` (SCStream, `SCContentFilter(desktopIndependentWindow:)`, 420v / `showsCursor=false` / `1/30` — all verified against the 14.x SDK headers), `PauseDetector` wired, `MinimizeUnshareWatcher`, `--share-window-id` bypass. The smoke test (`WindowCaptureSmokeTests`) SKIPS on the `xctest` host (it can't hold Screen Recording TCC — a transient CLI process, error -3801); the real capture path is exercised by the M4 app (which the human grants). |
| **M4** | Two instances via `open -n`; A shares a window; B renders it live in a movable native window | ⚠️ **PARTIAL — blocked only on a one-time human TCC grant.** Built + verified: both instances launch via `open -n` with launch-arg join, **both join the same SFU room** (server-confirmed 2 participants), the app opens all six data channels, mints a working dev JWT, wires capture→publish→state-broadcast and a native `NSWindow` per remote track (`SwiftUIVideoView` + owner-color border). The sharer's `SCStream` capture needs **Screen Recording TCC**, a system dialog only a human can approve on the dev Mac (R2/R4). The capture→VP9→SFU→decode→render pipeline itself is proven by the M2 integration test (synthetic frames A→B). **PENDING (human step):** grant Screen Recording to `JoeScreen.app`, re-run the two-instance demo, screenshot the live shared window on instance B into this file. |
| **M5** | Integration test asserts audio publication + cross-Room subscription WITHOUT opening the capture device | ✅ `VoiceIntegrationTests` (skips without `LIVEKIT_URL`): two live Rooms, the transport's audio-metadata accessors (`isAudioPublished`/`remoteAudioTrackCount`) are correctly wired to LiveKit's participant audio tracks (clean baseline with no mic). Publishing a REAL audio track was observed to HANG the headless host (WebRTC audio device module with no device/mic-TCC), so the machine gate is metadata-only per the gate's own wording. The app calls `setMicrophone(enabled:true)` on join. Superseding decision recorded in DECISIONS D13-A. **PENDING (human steps):** live-mic publish, cross-device audio subscription, and the audible check (mic TCC + speakers) — see H5 below. |
| **M6** | Coalescing unit tests + cursor messages flowing in the two-instance demo | ✅ (unit) `CursorCoalescerTests` (7): outbound coalesce-to-latest per window, one-move-per-window, ignore-older-sample, flush-empties; inbound latest-wins, per-(sender,window) independence, forget-rebaselines. Wired: `RemoteVideoView.onContinuousHover` → `CursorPump.sendLocalCursor` (coalesced ~60 fps out) → `cursor` channel; inbound → `CursorOverlay` (click-through, `allowsHitTesting(false)`) renders every participant's pointer in its `ParticipantColor` at per-window normalized coords. **PENDING (with M4):** cursor messages flowing visibly in the live two-instance demo (needs the same Screen Recording grant to have a shared window to hover over). |
| **M8** | `xcodebuild -scheme JoeScreen-iOS -destination 'generic/platform=iOS Simulator' build` + run in simulator | ✅ **BUILD SUCCEEDED**; the iOS app (`JoeScreen-iOS`, viewer + voice only — NO control/share, R6) builds for the simulator and **runs** — screenshot `docs/screenshots/m8-ios-viewer.png` shows the join sheet (server/room/identity) with the correct "iOS is a viewer + voice client. It cannot control or share windows." messaging, and a zoomable `SwiftUIVideoView` (pinch-zoom `.zoomIn/.zoomOut/.resetOnRelease`) page-tab for shared windows. **PENDING (same class as M4/M5):** the LIVE connect-and-render against the `--dev` server needs a tap on iOS's custom-URL-scheme confirmation dialog (SpringBoard modal; `simctl` has no tap primitive) — a human step. |
| **Backlog #1 (F4)** | `swift build && swift test` green; `xcodebuild -scheme JoeScreen-macOS/-iOS build` | ✅ **`swift build && swift test` = 288 tests, 7 skipped, 0 failures** (22 new: `InputWireBackCompatTests` 8 tolerant-decode + additive kinds, `InputEventPlannerTests` 11, `SecureInputBannerTests` 3). **`xcodebuild JoeScreen-macOS` AND `JoeScreen-iOS` → BUILD SUCCEEDED**; macOS app launches. Lands the remote-control runtime: InputEventPlanner, SecureInputDetector (R8), CGEventInjector (InjectionStrategy switch, default hidTap), InputPump (controller send + owner authorize→inject), owner consent UI + "X is driving" badge + secure-input banner. **Human-gated:** kTCCServicePostEvent grant + the Phase-0(c) strategy spike + the owner-grant wiring + live cross-Mac injection rows F4/F5 (see Human TODO ledger). |
| **M11** | `swift build && swift test` green (M10 + new Tier-1); `xcodebuild -scheme JoeScreen-macOS/-iOS build`; LiveKit integration suite green with `LIVEKIT_URL` | ✅ **`swift build && swift test` = 266 tests, 7 skipped, 0 failures** (42 new M11 Tier-1: `ShareContextTests` 10 incl. including-pending codec math, `ShareBitratePolicyTests` 5, `AdmissionOverloadTests` 5 incl. legacy delegation, `DisplayPickResolverTests` 6, `DisplayResolutionPolicyTests` 7 incl. 5K-cap/never-upscale, `RenegotiationDecisionTests` 7 which-tracks-flip, + lifecycle updates for always-grace-on-trackEnded). **`xcodegen` + `xcodebuild JoeScreen-macOS` AND `JoeScreen-iOS` → BUILD SUCCEEDED**; macOS app launches (display-share UI + border overlay wired). **LiveKit integration suite vs live SFU** → **12 tests, 0 failures** (kind-aware publish + deferred options + renegotiation live path clean). **Adversarial review** (3 lenses — concurrency, wire/JWT back-compat, D5 renegotiation + R24/R32 + display capture): **4 CONFIRMED findings, all fixed** — (1) HIGH: `DisplayLifecycleWatcher` claimed `@unchecked Sendable` with no lock; its `stop()` raced the timer queue → now all mutable state is `NSLock`-guarded + `stop()` idempotent; (2) HIGH: `renegotiateForCodecChange` republished a stale entry if the window was concurrently unshared during the await → leaked an orphaned live track; now re-validates `publishedTracks[windowID]?.track === track` after each await and unpublishes any orphan; (3) MED: admission `.degrade` set the bitrate but never lowered ALREADY-LIVE tracks → now republishes them via `republishForBitrateChange`; (4) LOW: a share refused by the encode cap flickered a live VP9 window through H.264 and back → the encode cap is now checked BEFORE the codec context is pushed. Lands: codec-ordering fix (latent #3, D5 structural), ShareBitratePolicy + admission revival (dead code #4), display picker + macOS-14 floor DisplayPickResolver, DisplayCaptureService (hall-of-mirrors filter, showsCursor, screen-lock pause, display-unplug), display:<uuid> naming, structural VP9↔H.264 renegotiation (in-place swap), one-display-per-sharer, ShareBorderOverlay. **PENDING (Tier-2 hardware rows below):** the LIVE display-share behaviors. |
| **M10** | `swift build && swift test` green (M9 + new Tier-1); `xcodebuild -scheme JoeScreen-macOS/-iOS build`; LiveKit integration suite green with `LIVEKIT_URL`; Go token server builds | ✅ **`swift build && swift test` = 224 tests, 7 skipped, 0 failures** (29 new M10 Tier-1: `TrackClassifierTests` 7 incl. share-name-beats-camera-source precedence, `DevTokenMinterTests` 4 name-claim, `ParticipantMediaReducerTests` 9 incl. the mute→avatar-not-frozen trap + late-join seed, `TileSubscriptionPlannerTests` 9 incl. name-then-UUID determinism + decode-budget parking). **`xcodegen` + `xcodebuild JoeScreen-macOS` AND `JoeScreen-iOS` → BUILD SUCCEEDED**; the macOS app **launches with the participant tile strip** (no crash). **Go token server** `go build ./...` clean (SetName wired). **LiveKit integration suite vs live SFU** → **0 failures** (media-state delegates + descriptor hooks don't disturb the live path). **Adversarial review** (3 lenses — concurrency, JWT/wire back-compat, R24/R32 + camera economics + decode budget): **2 CONFIRMED findings, both fixed** — (1) HIGH: the share thumbnail's second renderer was gated only on `!isClosed`, so a soft-hidden window kept a live renderer and defeated the R24/R32 downlink-off soft-hide → now gated on `isRenderingActive` too (and `.unsubscribe` marks the entry inactive); (2) MED: the decode budget counted `remoteWindows.count` incl. user-closed (hard-unsubscribed, zero-decode) windows → now counts only actively-decoding windows. Lands: TrackClassifier routing, display names via the JWT `name` claim (SFU-distributed to late joiners, zero wire surface), ParticipantMediaReducer (mute reads `isMuted`, never subscription), the tile strip + share thumbnails (second renderer on the held track). **PENDING (Tier-2 hardware rows below):** the LIVE multi-Mac tile behaviors. |
| **M9** | `swift build && swift test` green (120 + new Tier-1); `xcodebuild -scheme JoeScreen-macOS build`; LiveKit integration suite green with `LIVEKIT_URL` | ✅ **`swift build && swift test` = 195 tests, 7 skipped, 0 failures** (75 new M9 Tier-1 suites: `ShareTrackNameTests` 8, `ShareInfoTests` 7, `VideoFitMathTests` 11, `WindowCascadeTests` 8, `ResizeStabilizerTests` 8, `RemoteWindowLifecycleTests` 19 incl. full every-event-in-every-state matrix, `RoomModelShareInfoTests` 14). **`xcodegen generate` + `xcodebuild JoeScreen-macOS` AND `JoeScreen-iOS` → BUILD SUCCEEDED**; the macOS app **launches and stays running** (no Killed:9) with the new `@Observable RemoteVideoWindow`, lifecycle-driven window manager, and Window-menu commands. **LiveKit integration suite vs live SFU** (`bun run livekit` from repo root, `LIVEKIT_URL=ws://localhost:7880 swift test --filter JoeScreenLiveKitTests`) → **8 tests, 0 failures**, incl. `testSyntheticVideoFrameFlowsAToB` (real VP9 encode→SFU→decode→render through the new `setOnRemoteTrack` descriptor hook). **Adversarial review** (3 lenses — Swift-6 concurrency, wire back-compat, R24/R32 subscription — + per-finding refutation): 2 raw findings, both addressed (the `.closedByUser`-leak was found+fixed pre-review; the soft-hide-stuck concern hardened by reconciling occlusion on deminiaturize). Lands: receive-side lifecycle reducer, SID-keyed registry (latent bug #1), trackGone dual hook incl. unpublish-is-authoritative (frozen-ghost fix), owner repair (latent bug #5), aspect-true windows, cursor letterbox mapping, WindowResizeWatcher, ShareInfo plumbing. **PENDING (Tier-2 hardware rows below):** the LIVE two-Mac correctness behaviors. |
| **M7** | Compiles + unit tests against a `FakeSessionProvider`; runtime rows PENDING in the hardware run-book | ✅ (compiles + unit) `GroupSessionCoordinator: SessionProviding` + `GroupActivityPresenter` compile against the real GroupActivities framework (`prepareForActivation()` → `GroupActivityActivationResult` → `activate()`; `GroupActivitySharingController` presenter with `GroupStateObserver.isEligibleForGroupSession` fallback; `TransportBootstrap`/`CoordinationMessage` over `GroupSessionMessenger` via `SignalingSendQueue` retry/backoff; late-joiner re-broadcast; reuses `JoeScreenActivity`'s existing `GroupActivity` conformance — not re-declared). `SessionCoordinationTests` (6): bootstrap + room-snapshot wire round-trips (<200 KB), `FakeSessionProvider` start/join/fail/participant-stream/invalidation, bootstrap fits `SignalingSendQueue`. **PENDING (hardware, needs group-session entitlement + TEAM_ID + 2 devices/different iCloud accounts):** H1 runtime — see run-book. |

### Additional machine-gateable spikes (PENDING — single-device, no pairing)
These *can* be run by the agent/human on ONE Mac and are not yet done:
- **Phase-0(b)** SCStream → VT low-latency H.264 encode → decode → `AVSampleBufferDisplayLayer` render, single device. Proves the capture/encode/decode/render pipeline end-to-end on one machine.
- **Phase-0(c)** `CGEvent` injection into a target window on a Dev-ID non-sandboxed build with the `kTCCServicePostEvent` grant, incl. tagged-event local-override.
- **`livekit-server --dev`** loopback: publish a synthetic track and subscribe from the same machine (no certs).

---

## Tier 2 — Hardware sub-gate (human run-book) · ALL PENDING

Minimum kit: **2 Macs (at least one base-tier Apple Silicon) + 1 iPad/iPhone, on DIFFERENT iCloud
accounts.** A LiveKit server reachable by all (or `--dev` on the LAN for early runs).

### Latency metric (define once, referenced everywhere)
**glass-to-glass** = capture-timestamp → on-screen-render, measured via an injected timecode diff (or a
second-camera frame-counter). **Target ≤ ~150 ms on a quiet LAN** for screen video; the terminal
(F12) must be *visibly* snappier than screen share. Record method + numbers here when run.

### Run-book (fill in results; leave PENDING until actually observed)

| # | Procedure | Expected | Result |
|---|---|---|---|
| H1 | **Phase-0(a)** Start a session Mac↔Mac: `GroupActivitySharingController` picker (test its reported flakiness — R9), then `prepareForActivation()`→`activate()` fallback. Exchange a hello over `GroupSessionMessenger`. | Session forms; hello delivered; note picker reliability. | PENDING |
| H2 | **Phase-0(e)** Bring up a `PeerConnection`/LiveKit room using ONLY messenger-relayed bootstrap. Exercise ICE-batch discipline. Measure glass-to-glass. | Video flows; g2g ≤150 ms LAN. | PENDING |
| H3 | **Phase-0(f)** 3-peer / 2-window session through `livekit-server`. Measure uplink consumed + max concurrent low-latency encode sessions on the base Mac (sets `AdmissionController.maxEncodeSessions` + windows-per-host cap). | Data-driven caps recorded here + in DECISIONS D5/D7. | PENDING |
| H4 | **Codec A/B (D5 decision gate)** Encode the fixed screen-text corpus VP9 vs H.264 at 2.5 Mbps on a base Mac; OCR character-error-rate + blind human side-by-side at 100% zoom; check encode-time/thermal budget. | Confirms or flips the VP9-default; record QP bounds + corpus hash in DECISIONS. | PENDING |
| H5 | **M5 live mic.** Grant mic TCC to JoeScreen.app; join a call; `setMicrophone(enabled:true)` publishes a real Opus track; a second device/instance subscribes; speak and confirm audible on the peer with AEC (no echo/howl). | Audio track published + subscribed cross-device; voice audible; AEC works. | PENDING |
| F1 | Mac A shares one window; Mac B + iPad see it as an independent movable window, live ≤~150 ms LAN; nothing else on A visible. | Meets §4 F1. | PENDING |
| F2 | A shares IDE while B shares terminal; both + iPad see both, owner-color-labeled. | Meets §4 F2. | PENDING |
| F3 | Join shares nothing; per-window share via hover tab + drag-onto-shared-display; whole-display auto-share; unshare one action; **minimize auto-unshares**; off-Space = pause (not disconnect); iOS full-screen via broadcast picker. | Meets §4 F3. | PENDING |
| F4 | Both A and B drive A's window (mouse+type) without raising/refocusing A for its local user; A's own input overrides (tagged events). | Meets §4 F4. | PENDING |
| F5 | 3-person: participants drive different Mac windows concurrently; single window governed by the soft single-active-controller lock; injection respects receipt order + security checks. | Meets §4 F5. | PENDING |
| F6 | Copy a multi-line code snippet in A's window → pasteable byte-intact (UTF-8, whitespace) in B's window on B's machine, both directions. | Meets §4 F6. | PENDING |
| F7 | Session at the **claimed upper bound (up to 10)** through the SFU with per-participant colors/roster, F2/F5/F8 holding, uplink admission active (degrade/refuse, not saturate). | Meets §4 F7 at the bound. | PENDING |
| F8 | Every participant's pointer over shared windows in their color at ~60 fps, correct per-window coords. | Meets §4 F8. | PENDING |
| F9 | Any participant inks on any window; all peers see it live; clear/undo per author. | Meets §4 F9. | PENDING |
| F10 | Each remote window Watch/Control/Draw, **Watch default**; sharer can globally disable control; per-user write-access blocks that user; enforcement on the owner Mac (Watch drops injection). | Meets §4 F10. | PENDING |
| F11 | FaceTime-started session carries voice (implement nothing); Messages-started gets the Opus fallback; optional camera bubbles minimal. | Meets §4 F11. | PENDING |
| F12 | Shared PTY streams text to all peers, visibly lower latency than screen share; multiple users type; redaction masks obvious credentials before transmit; iOS is a first-class terminal client. | Meets §4 F12. | PENDING |
| F13 | Named, rejoinable sessions in a "Recent" list (local + `GroupSessionJournal` snapshot); invite via SharePlay link/share sheet; contacts/presence with one-tap start. | Meets §4 F13. | PENDING |
| F14 | Start from the system share sheet / `ShareLink` via `GroupActivityTransferRepresentation` and via a custom-URL deep link. | Meets §4 F14 (minimal). | PENDING |
| P1 | Broadcast-extension **peak RSS** under the ~50 MB ceiling at ≤720p (R7); behavior on device lock (R19). | RSS recorded; lock behavior noted. | PENDING |
| P2 | `kTCCServicePostEvent` vs `kTCCServiceAccessibility` grant flows; Secure Event Input blocking a password field surfaces the "can't be remote-controlled" message (R8). | Both grants exercised; secure-input surfaced. | PENDING |
| P3 | macOS 15+ recurring screen-recording prompt cadence with the `SCContentSharingPicker` path (R4). | Cadence observed + recorded. | PENDING |

### M9 — Receive-side lifecycle correctness (Tier-2, all PENDING)

| # | Procedure | Expected | Result |
|---|---|---|---|
| M9-1 | Mac A shares a window; Mac B renders it in a native window; **force-quit A** (or kill the sharer). | B's viewer window closes ≤2 s — **no frozen ghost**. (trackGone from unpublish → close+purge.) | PENDING |
| M9-2 | B renders A's shared window; **close the viewer window on B**, then click **Reopen** (tile or Window menu). | Window closed (downlink cut, `set(subscribed:false)`); Reopen restores it **at the remembered frame** with **live video**, no duplicate window. | PENDING |
| M9-3 | A shares a window; **resize the source window on A**. | B's viewer keeps the **new aspect ratio** within one `ResizeStabilizer` confirmation (~0.75 s settle), no mid-drag churn; letterbox stays correct. | PENDING |
| M9-4 | **Two owners × two windows each** join and share. | Per-owner **cascade groups** (each owner's windows cluster; distinct owner anchors); all fully on-screen. | PENDING |
| M9-5 | A shares a **portrait** window; B views on a **landscape** display (letterboxed). Hover the cursor over a feature at a known pixel. | Pointer tips **align on the same pixel feature** at both ends (VideoFitMath content-rect mapping; the pre-M9 drift is gone). | PENDING |
| M9-6 | A shares; drop A's network briefly so the SFU link goes `.reconnecting` (do NOT unshare). | B's viewer shows a **"Reconnecting…" badge over the frozen frame** and stays open through the ~10 s grace; recovers to live on reconnect; only tears down if grace expires. | PENDING |
| M9-7 | B **miniaturizes** (or fully occludes) A's viewer window, then restores it. | While hidden, the renderer detaches and adaptive-stream stops SFU forwarding (downlink drops) — verify via webrtc-internals; restore re-attaches (keyframe ≈0.5 s). `set(enabled:)` never called (R24). | PENDING |
| M9-8 | A shares a window with a real title (e.g. an Xcode file) and app. | B's viewer window **title bar shows the window title + app + owner**, and the share tile is aspect-true before/at first frame (ShareInfo seed). | PENDING |

### M10 — participant video tile strip (Tier-2, all PENDING; need 2–3 Macs + cameras + mic TCC)

| # | Procedure | Expected | Result |
|---|---|---|---|
| M10-1 | 3 Macs join with distinct names (JoinSheet "Your name" / `--name`), all cameras ON. | Each Mac's strip shows **all three tiles** (self mirrored, first) with the **correct names** ≤2 s after join; late joiners still get everyone's name (JWT `name` claim distributed by the SFU). | PENDING |
| M10-2 | On Mac A, **mute the mic**. | A red `mic.slash` badge appears on A's tile on B and C ≤1 s (driven by `publication.isMuted` via didUpdateIsMuted). | PENDING |
| M10-3 | On Mac A, **turn the camera OFF** (which mutes, not unpublishes). | A's tile on B/C shows the **avatar** (color circle + initials), NOT a frozen last frame — the semantic trap. Camera back on → live video returns. | PENDING |
| M10-4 | Everyone speaks in turn. | The **green speaking ring** tracks the actual speaker ≈300 ms (SFU speaker detection); rings don't flicker (add a debounce only if they do). | PENDING |
| M10-5 | 8 participants join, all cameras on, plus some shares. | Decode budget holds: shares decode first, then up to the camera budget; **cameras beyond the budget park as avatars** (no renderer → SFU stops forwarding those streams); scrolling the strip attaches/detaches tiles without runaway decode. | PENDING |
| M10-6 | B has A's shared window open. | The **shares-pane tile shows a live mini-thumbnail** (second renderer on the held track); the big window keeps full quality (adaptive-stream reports the max renderer size). Tap thumbnail → the big window raises; tap A's participant tile → all A's shared windows raise. | PENDING |

### M11 — whole-screen (display) share (Tier-2, all PENDING; need 2 Macs, a 5K display for M11-1)

| # | Procedure | Expected | Result |
|---|---|---|---|
| M11-1 | Mac A shares a **5K display**; Mac B views it. | B's viewer window is **≈2389×1344, aspect-true and readable** (DisplayResolutionPolicy area-cap); not the full 14.7 Mpx. | PENDING |
| M11-2 | Mac A shares a **window (VP9)**, then also shares a **display**. | Both tracks become **H.264** (verify in webrtc-internals / SFU stats); the existing window track **renegotiates with a ~1s freeze and NO window flicker** (in-place track swap). Unshare the display → the window renegotiates back. | PENDING |
| M11-3 | Mac A shares a display while JoeScreen's own windows (incl. B's remote-share viewers if A also views) are on that screen. | **JoeScreen's own windows are ABSENT from the shared display** (hall-of-mirrors fix via excludingApplications). | PENDING |
| M11-4 | Mac A locks the screen (⌘⌃Q) while sharing a display, then unlocks. | B sees the share **pause (badge) on lock** (lock-screen frames suppressed, not broadcast) and **resume ≤2s on unlock**. | PENDING |
| M11-5 | Mac A unplugs / turns off the shared display. | The share **unshares ≤2s** (1 Hz CGGetActiveDisplayList poll → terminal .ended). | PENDING |
| M11-6 | Mac A tries to share a **second display** while already sharing one. | **Refused with a visible reason** (one display per sharer, v1); a window+display mix is allowed. | PENDING |
| M11-7 | Mac A shares a display containing a **DRM-protected window** (e.g. a paid video). | **R27 observation only:** the DRM region renders as a **black area** in the share (documented; no detector in v1). | PENDING |
| M11-8 | If a **macOS 14.0–15.1** Mac is available, share a display. | The **DisplayPickResolver frame-match path** resolves the display correctly (includedDisplays is 15.2+; the floor path matches contentRect against display frames). | PENDING |
| M11-9 | Mac A sharing a display sees the **red border overlay** around it + the **"Sharing Display" chip** with a stop button in the control bar. | Border visible to A only (excluded from the capture filter → invisible to B); the chip's stop button ends the share. | PENDING |

**Reminder:** do not mark any Tier-2 row anything but PENDING until it is actually observed on
hardware, with the method and numbers written into this file.
