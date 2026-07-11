# DECISIONS.md — JoeScreen

Every load-bearing option-choice and why. Decisions were produced by a Phase-0 verification +
design-panel pass (see `docs/architecture.md` for the two-plane model). Where a decision **deviates
from the original build spec**, it is flagged. Dependency pins are real, resolved artifacts
(verified 2026-07-07), not transcribed from memory.

---

## D1 — Swift 6 language mode, strict concurrency
Swift 6 language mode (toolchain 6.2.1, Xcode 26.1.1) for all first-party targets, with
`StrictConcurrency` enabled. If a pinned dependency (livekit/client-sdk-swift, SwiftTerm) fails to
compile under strict concurrency, fall back to Swift 5 language mode **per-target**, never globally,
and record the exact failing diagnostic here. `JoeScreenKit` itself stays Swift 6 (it is pure Swift,
dependency-free).
**Why:** strict concurrency directly de-risks this codebase's dominant hazard class — capture
callbacks, encoder sessions, transport delegates, and MainActor UI crossing actor boundaries. The
per-target fallback keeps the primary green gate (`swift build`/`swift test` on JoeScreenKit) at
Swift 6 even if UI/SDK-adjacent targets must degrade.
**Status:** the package builds clean and 84 tests pass at Swift 6 + StrictConcurrency today.

## D2 — Deployment floor: macOS 14.0 / iOS 17.0 (built with the 26.1 SDK)
Minimum Xcode floor 26.1. Newer capabilities are `#available`-gated: macOS 15 for
`SCRecordingOutput`/`captureMicrophone`; macOS 14.4 for the `persistent-content-capture` entitlement
(inert on 14.0–14.3); macOS 26 / iOS 26 optional `VTFrameProcessor` receive-side super-resolution.
**Why:** the OS26 delta audit confirmed every load-bearing API exists at 14/17 — SCStream +
`SCContentSharingPicker` (macOS 14.0), GroupActivities/GroupSessionMessenger incl. `.unreliable`
(macOS 13/iOS 16), `GroupSessionJournal` (14/17), ReplayKit broadcast (not deprecated in 26-era
docs — but see R21), VideoToolbox low-latency rate control. Nothing in macOS 15/26 or iOS 18/26
removed anything the design uses. Raising the floor buys no core capability.

## D3 — WebRTC via livekit/client-sdk-swift is the default (and only fully-built) media transport
**DEVIATES FROM SPEC** (spec suggested `stasel/WebRTC`). All media-plane code sits behind a
`MediaTransport` protocol in JoeScreenKit with two seams: `LiveKitTransport` (built) and
`LANQUICTransport` (Network.framework Bonjour+QUIC — a compiling seam, **shipped dark**, not built
in parallel; it is the Phase-0(d) fallback and future same-LAN option).
**Why:** LiveKit ships the SFU server binary, embedded TURN, token auth, simulcast/dynacast, and an
officially-maintained Swift SDK with `BufferCapturer` — exactly the SCStream-CMSampleBuffer→track
seam JoeScreen needs — versus hand-rolling signaling/congestion/keyframe machinery. The spec's own
rule (§3.2) forbids building two real-time transports in parallel; the protocol seam preserves the
QUIC LAN option without splitting effort. **Never link two libwebrtc binaries** — the LAN mesh mode
imports LiveKit's bundled fork directly.
**User sign-off:** confirmed 2026-07-07 (self-hosted SFU chosen over managed Cloud and over
STUN+LAN-only).

## D4 — Topology: star through a self-hosted single-node LiveKit SFU for ALL sessions
**DEVIATES FROM SPEC** (spec proposed mesh-for-tiny / relay-for-big). One code path, 1:1 included,
no per-size switching, no mid-session migration. Deployment: docker-compose on one VPS
(livekit-server + a ~60-line JWT token endpoint holding the API secret + TLS), with LiveKit's
embedded TURN/TLS on :443 as the UDP-blocked fallback (no separate coturn). Room name derives from
the `GroupSession`; room identity = SharePlay `Participant` UUID. The spec's mesh survives only as a
**feature-flagged, serverless SAME-LAN mode for ≤3 peers** (host candidates only, ICE batched over
the messenger); a 4th mesh join is refused with a "switch to server session" affordance. Three-sided
admission control (§ AdmissionController) is enforced before every share.
**Why (the math forces it):** full-mesh egress is 54–90 Mbps up at the F7 bound (beyond typical
uplinks) AND libwebrtc instantiates one encoder per RTPSender per PeerConnection, colliding with the
**single hardware encode engine** on base Apple Silicon — so mesh fails F7 *even on a LAN* where
bandwidth is free. The SFU needs exactly one encoder per shared window, dissolves symmetric-NAT
pairwise failure by construction (all clients dial out), and gives a loopback-testable dev loop via
`livekit-server --dev`. Participant-hosted "MCU-lite" was rejected: its hub egress (~240 Mbps at the
bound) is worse than the mesh case already declared infeasible.

## D5 — Codec: VP9 for single-window Mac shares; hardware H.264 (VT low-latency) otherwise + as fallback
VP9 (software, libvpx screen-content mode, `contentHint = .detail`) is the v1 default for the
**single-window Mac share path only**. Hardware H.264 via VideoToolbox low-latency mode
(`kVTVideoEncoderSpecification_EnableLowLatencyRateControl` + explicit
`kVTCompressionPropertyKey_AverageBitRate`, **never** `ConstantBitRate`) is the structural fallback
and the only codec for: ≥2 shared windows, whole-display shares, the iOS broadcast extension, and
encoder-pressure fallback. Fallback triggers (one-way per share session, no flap-back): p95 encode
>22 ms over 5 s; CPU-limited <15 fps for 10 s with changed frames; `thermalState .serious`;
structural window-count ≥2. Per-codec QP bounds are derived by OCR-scored calibration on a fixed
screen-text corpus — **VP9's 0–63 and H.264's 0–51 scales are incommensurable; never transliterate
Multi.app's VP9 numbers.** HEVC and AV1 are out of v1. Legibility invariants regardless of codec:
`contentHint = .detail`, `degradationPreference = .maintainResolution`, 30 fps source cap, zero
jitter/playout delay.
**Phase-0 A/B is a DECISION GATE:** if VP9 misses the encode-time/thermal budget or doesn't beat
H.264 on OCR character-error-rate at 2.5 Mbps on a base-tier Mac, the default flips to hardware
H.264. See `CodecSelector` (implemented + unit-tested) for the fallback state machine.

## D6 — Distribution/signing: macOS = notarized Developer-ID, NON-sandboxed, outside the MAS
The iOS app is a standard App-Store-eligible app with a ReplayKit broadcast upload extension sharing
an App Group. Signing uses a `TEAM_ID` env-var placeholder: unset → automatic/ad-hoc signing with a
README note; notarization + profile installation are required human steps (R2). The macOS
entitlements file contains `com.apple.developer.group-session` and **deliberately omits App Sandbox**;
the extension holds only the App Group.
**Why (top architectural constraint):** input injection via `CGEvent` is gated by
`kTCCServicePostEvent` (surfaced under Accessibility), and these permissions are **unavailable to
sandboxed apps** — a sandboxed app cannot be added to the Accessibility list at all. Screen capture
alone could be sandboxed; **injection is what forces Developer-ID.** The `persistent-content-capture`
entitlement (macOS 14.4+, Apple-approval form) is requested early but the app must function without
it. See `InjectionPermissions` (checks `kTCCServicePostEvent` via `CGPreflightPostEventAccess`, NOT
`AXIsProcessTrusted` — the wrong service).

## D7 — Pinned dependencies (resolved artifacts, bump-only policy)
Verified 2026-07-07. Each bump requires the `swift test` gate + the Phase-0 loopback spike to stay
green. **Rule: no dependency that links a second libwebrtc may ever enter the graph.**

| Dependency | Pin | Role |
|---|---|---|
| `livekit/client-sdk-swift` | **2.15.1** (exact) | media plane; replaces stasel/WebRTC (D3) |
| `migueldeicaza/SwiftTerm`  | **1.13.0** (exact) | F12 terminal rendering |
| `apple/swift-certificates` | **1.19.3** (exact) | LAN QUIC TLS plumbing (seam only, dark) |
| `livekit/livekit-server` (Docker) | **v1.13.3** | self-hosted SFU (infra/) |

Note: the default `swift build`/`swift test` gate targets are **dependency-free** — the pure-logic
seams don't link LiveKit/SwiftTerm so the machine gate is fast and offline. The `.package(...)` lines
in `Package.swift` are present but commented; uncomment to resolve against the network for the Xcode
app layer.

## D8 — Package-first layout
One `Package.swift` declares all non-app library targets so `swift build`/`swift test` is the PRIMARY
machine-checkable green gate. A thin `Apps/JoeScreen.xcodeproj` adds the three product targets
(JoeScreen-macOS, JoeScreen-iOS, JoeScreenBroadcast) consuming the local package.
Schemes: `JoeScreen-macOS`, `JoeScreen-iOS`, `JoeScreenKit-Package`.
**Why:** with no paired hardware, maximizing logic in SPM targets maximizes what can actually be
verified. App/extension targets need Xcode for entitlements, signing, and the extension product type.

## D9 — SharePlay is the coordination plane ONLY
Session start (`GroupActivitySharingController` on macOS; `prepareForActivation()` →
`activate()` — **verified signatures**: `prepareForActivation()` returns `GroupActivityActivationResult`
with exactly `.activationPreferred` / `.activationDisabled` / `.cancelled` (NOT Bool); `activate()`
is `async throws -> Bool`), presence/roster (opaque `Participant` UUIDs), and low-rate state.
`GroupSessionMessenger` carries: transport bootstrap `{LiveKit server URL, room name, JWT}` + session
state; batched trickle-ICE rides it **only** in the feature-flagged LAN mesh mode (behind
`ICECandidateBatcher` + `SignalingSendQueue` backpressure/retry/stagger). No payload over the
messenger exceeds 200 KB (conservative vs the transcript-only 256 KB cap — R10). **Media NEVER
touches the messenger.** Established media connections must survive `GroupSession` invalidation
(SFU connection is independent; re-establish signaling on rejoin; re-broadcast state to late-joiners).

## D10 — macOS capture: pure ScreenCaptureKit
`SCStream` per shared window via `SCContentFilter(desktopIndependentWindow:)`, with
`SCContentSharingPicker` as the primary selection path and `CGPreflightScreenCaptureAccess()` /
`CGRequestScreenCaptureAccess()` preflight for the direct-filter fallback. `pixelFormat` is ALWAYS
set explicitly (420v; debug-asserted — R14), `showsCursor = false` (remote cursors render in the
overlay), `minimumFrameInterval = 1/30`. Minimize is detected and treated as UNSHARE; off-Space /
no-frame conditions are classified by `PauseDetector` as PAUSE, never disconnect (R13). Black-frame
runs are surfaced as probable DRM/HDCP content (R27). No `CGDisplayStream`/`CGWindowListCreateImage`.

## D11 — iOS capture: ReplayKit broadcast upload extension
`RPBroadcastSampleHandler`, launched via the plain user-tap `RPSystemBroadcastPickerView` (the
`sendActions` auto-tap is best-effort polish behind a nil-safe helper — R20). The extension
downscales to ≤720p and hardware-encodes H.264 (VT low-latency) **per-frame immediately** — never
queues `CVPixelBuffer`s — and hands small ENCODED frames to the host app over an App Group ring
buffer (`EncodedFrameRingBuffer`, implemented + unit-tested). The HOST app owns the LiveKit Room and
SharePlay session (group-session entitlement is app-only — verified). iOS capture sits behind a
protocol for migration to ScreenCaptureKit when iOS 27 ships (R21).

## D12 — Input security model (owner-Mac enforcement)
Every remote input message is bound to the DTLS/SFU-authenticated peer identity PLUS an owner-issued
capability token; the owner enforces authorization **at injection time** against trusted local state
(control mode, per-user write access) and clamps injected coordinates to the shared window's bounds.
Synthetic `CGEvent`s are tagged via `eventSourceUserData` so local input always wins. Default mode is
Watch; F5 multi-user control uses a soft single-active-controller lock per window (turn-taking),
never simultaneous injection into one field. Injection preflight checks `kTCCServicePostEvent` (NOT
`AXIsProcessTrusted`). Secure Event Input is detected and surfaced as "this field can't be
remote-controlled." Implemented + unit-tested in `InputAuthorizer` / `ControlCapability` (all deny
paths covered).

## D13 — Audio: FaceTime-carried voice is the default; Opus fallback for Messages-started sessions
FaceTime carries voice automatically during a SharePlay call (zero implementation, zero programmatic
access). Messages-started sessions get `AVAudioSession(.playAndRecord, .voiceChat)` + `AVAudioEngine`
with `setVoiceProcessingEnabled(true)` (set while stopped; required for AEC) + `AVAudioConverter`
PCM↔Opus (48 kHz mono, 960 frames/packet = 20 ms) published as a LiveKit audio track.

## D13-A — Voice on the LiveKit path uses the SDK's mic capture/AEC (supersedes D13's hand-built pipeline) · M5
**SUPERSEDES D13** for the LiveKit/Direct-Mode/fallback voice path. Voice is carried by
`localParticipant.setMicrophone(enabled:)` — LiveKit's SDK owns mic capture, echo cancellation
(`AudioCaptureOptions.echoCancellation`), auto-gain, and noise suppression, and publishes an Opus
audio track through the same SFU as video. This replaces D13's hand-built
`AVAudioSession(.playAndRecord,.voiceChat)` + `AVAudioEngine(setVoiceProcessingEnabled)` +
`AVAudioConverter` PCM↔Opus pipeline for every path where LiveKit is the transport.
**Why:** the media plane is already LiveKit (D3/D4); routing voice through the same SDK gives AEC,
device management, and Opus for free, with one publish/subscribe model for audio and video. Building a
parallel AVAudioEngine+Opus pipeline would duplicate capture/AEC and add a second audio path to
reconcile. `NSMicrophoneUsageDescription` is declared (M1); the app calls `setMicrophone(enabled:true)`
on join.
**D13's pipeline remains the reference** for any FUTURE non-LiveKit voice path (e.g. a
FaceTime-carried SharePlay session where voice is automatic, or a LAN-mesh mode that doesn't run the
LiveKit SDK). It is not deleted — it is the documented fallback lineage.
**Verification:** the audio publish/subscribe metadata plumbing is machine-tested (two live Rooms,
`isAudioPublished()`/`remoteAudioTrackCount()` correctly wired to LiveKit's participant audio tracks)
WITHOUT opening the capture device — a headless host can't clear the mic-TCC prompt and publishing a
real audio track starts the WebRTC audio device module, which hangs with no device. The live-mic
publish + cross-device subscription + audible check are one-time local HUMAN steps (TESTING.md).

## D14 — Terminal (F12) is a first-class, separate TEXT path
A real PTY spawned on the host Mac, raw bytes over the reliable/ordered `terminal` channel to
SwiftTerm-rendered views on all peers (iOS is a full terminal client — text, not injection). Secret
redaction (regex + Shannon-entropy) is applied BEFORE transmit in `SecretRedactor` (implemented +
unit-tested), documented as best-effort and **never a security boundary.**

## D15 — Receive-side window lifecycle is a pure reducer (M9)
The correctness of "movable window shares" (no frozen ghosts, no duplicate windows on reopen, no
SFU-blip flap, soft-hide releases downlink) lives in a pure `RemoteWindowLifecycle` reducer in
JoeScreenKit — `reduce(state, event) → (state, [Effect])` — so every dead-window/desync bug class is
an enumerable unit test and `AppModel` only executes effects. **Why:** the app layer can't be unit-
tested (needs a window server + a second Mac + TCC), so the correctness must live below it in a
testable seam. Two reversible sub-decisions recorded for the autonomous run (both softenable by a
constant/flag later):
- **Reconnect grace = 10 s.** When the media link is `.reconnecting`, a `trackGone` parks the viewer
  in `.stale` (frozen frame + "Reconnecting…" badge) for 10 s before tear-down, so a brief SFU blip
  doesn't flap the window closed. An authoritative snapshot-removal or owner-disconnect purges
  immediately regardless (the share is really gone). `AppModel.reconnectGraceSeconds`.
- **Belt-and-braces prune.** On a transport participant-set diff, a departed owner's windows also get
  `ownerDisconnected` fed to the lifecycle and `room.pruneParticipant` (a **receiver-local cleanup
  that never bumps `revision`** — the host stays the LWW authority), so a dropped SDK track-event
  still tears their windows down. **Reversible:** it's additive to the trackGone path, never the sole
  mechanism.
- **"Follow New Shares" defaults OFF.** New viewer windows open with `orderFrontRegardless()` (never
  steal focus); an opt-in session toggle switches to `makeKeyAndOrderFront`. The non-stealing default
  is the reversible/least-surprising choice.

## D16 — One `ShareTrackName` / `RemoteTrackDescriptor` contract (M9)
Share track naming has exactly one implementation: `ShareTrackName` (JoeScreenKit), byte-identical to
the pre-M9 `window:<uuid>` format, with `display:<uuid>` reserved additively for M11. The transport's
`trackName(for:)`/`windowID(fromTrackName:)` delegate to it. The subscribe hook is the design panel's
**superset** `RemoteTrackDescriptor {trackSID, trackName, sourceKind, ownerID?}`; the registry is
keyed by **SID** (a name key overwrote two same-named camera tracks — latent bug #1). `trackGone`
fires from **both** `didUnsubscribeTrack` and `didUnpublishTrack` (a locally-unsubscribed track fires
only unpublish on a later crash — hooking one leaks), deduped per SID. **Why:** M10 (camera routing)
and M11 (`display:`) both build on this one contract; a single implementation keeps the wire rule
(extend-never-break) enforceable in one place.

## D17 — Participant tiles: display names + media presence + decode budget (M10)
- **Display names via the JWT `name` claim.** The client puts an optional top-level `name` claim in
  its token (DevTokenMinter in DEBUG; the Go token server's `SetName` in release); LiveKit surfaces
  it as `participant.name` and the SFU distributes it to everyone, including late joiners. **Why over
  the alternatives:** participant *metadata* is more plumbing for the same result and needs a
  `canUpdateOwnMetadata` grant; a *state-channel profile message* has no late-join story (non-sharers
  never broadcast today). The `name` claim is zero wire-protocol surface and free late-join. Fallback
  everywhere: the existing 4-char UUID label.
- **Mic/camera-off is a MUTE, read from `publication.isMuted`.** LiveKit `setCamera(false)`/
  `setMicrophone(false)` mute rather than unpublish, so a muted camera track stays subscribed. The
  tile's `cameraOn`/`micLive` MUST derive from `isMuted` (via `isCameraEnabled()`/`isMicrophoneEnabled()`
  + didUpdateIsMuted), NEVER from track un/subscription — otherwise a camera-off peer renders a frozen
  last frame instead of an avatar. A correctness invariant, enforced in `ParticipantMediaReducer` +
  the transport's `handleMuteChanged`.
- **Cameras keep SDK-default simulcast ON.** D5's simulcast-OFF rule governs SHARE tracks only. Camera
  tracks stay simulcast-on so adaptive-stream can downshift thumbnail tiles cheaply. (Reversible if a
  measured decode budget says otherwise.)
- **Decode budget: 6 decoded video streams total, shares first.** `TileSubscriptionPlanner` gives
  shares priority and parks cameras beyond the remaining budget as avatars (no renderer → the SFU
  stops forwarding that stream). Default 6 is a placeholder pending the Phase-0(f) hardware
  measurement; a single constant to change. Off-screen tiles also self-limit via `LazyHStack`
  detaching renderers.

---

### Derived per-codec QP bounds (D5)
To be populated from the Phase-0 legibility calibration on real hardware, with the corpus hash
recorded here. **Pending hardware** — see `TESTING.md`. Do not transliterate across codec scales.
