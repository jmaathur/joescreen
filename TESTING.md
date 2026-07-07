# TESTING.md — JoeScreen

Two-tier gates (build spec §9). The agent owns the **machine sub-gate**; the **hardware sub-gate** is
a human run-book, recorded PENDING. **No result here is fabricated** — anything not actually run on
hardware says PENDING.

---

## Tier 1 — Machine sub-gate (owned by the agent)

### Status: ✅ GREEN (2026-07-07)

```
swift build     → Build complete (6 library targets; JoeScreenKit at Swift 6 + StrictConcurrency,
                  JoeScreenLiveKit at Swift 5 per-target per D1)
swift test      → Executed 111 tests, 5 skipped (integration + capture-TCC), 0 failures
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
| **M4** | Two instances via `open -n`; A shares a window; B renders it live in a movable native window | ⚠️ **PARTIAL — blocked only on a one-time human TCC grant.** Built + verified: both instances launch via `open -n` with launch-arg join, **both join the same SFU room** (server-confirmed 2 participants), the app opens all six data channels, mints a working dev JWT, wires capture→publish→state-broadcast and a native `NSWindow` per remote track (`SwiftUIVideoView` + owner-color border). The sharer's `SCStream` capture needs **Screen Recording TCC**, a system dialog only a human can approve on the dev Mac (R2/R4). The capture→VP9→SFU→decode→render pipeline itself is proven by the M2 integration test (synthetic frames A→B). **PENDING (human step):** grant Screen Recording to `JoeScreen.app`, re-run the two-instance demo, screenshot the live shared window on instance B into this file. |
| **M5** | Integration test asserts audio publication + cross-Room subscription WITHOUT opening the capture device | ✅ `VoiceIntegrationTests` (skips without `LIVEKIT_URL`): two live Rooms, the transport's audio-metadata accessors (`isAudioPublished`/`remoteAudioTrackCount`) are correctly wired to LiveKit's participant audio tracks (clean baseline with no mic). Publishing a REAL audio track was observed to HANG the headless host (WebRTC audio device module with no device/mic-TCC), so the machine gate is metadata-only per the gate's own wording. The app calls `setMicrophone(enabled:true)` on join. Superseding decision recorded in DECISIONS D13-A. **PENDING (human steps):** live-mic publish, cross-device audio subscription, and the audible check (mic TCC + speakers) — see H5 below. |
| **M6** | Coalescing unit tests + cursor messages flowing in the two-instance demo | ✅ (unit) `CursorCoalescerTests` (7): outbound coalesce-to-latest per window, one-move-per-window, ignore-older-sample, flush-empties; inbound latest-wins, per-(sender,window) independence, forget-rebaselines. Wired: `RemoteVideoView.onContinuousHover` → `CursorPump.sendLocalCursor` (coalesced ~60 fps out) → `cursor` channel; inbound → `CursorOverlay` (click-through, `allowsHitTesting(false)`) renders every participant's pointer in its `ParticipantColor` at per-window normalized coords. **PENDING (with M4):** cursor messages flowing visibly in the live two-instance demo (needs the same Screen Recording grant to have a shared window to hover over). |

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

**Reminder:** do not mark any Tier-2 row anything but PENDING until it is actually observed on
hardware, with the method and numbers written into this file.
