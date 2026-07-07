# RISKS.md — JoeScreen

The risk register. Three classes: **(A) required human / out-of-agent-scope steps**, **(B) UNVERIFIED
Apple-API assumptions** (each wrapped behind a guard/shim and queued for hardware verification — never
silently filled in from memory), and **(C) ops / scaling / correctness** risks. Severity: high /
medium / low.

Every UNVERIFIED item below has a code-level mitigation already in place (a protocol seam, an
explicit-set-don't-assume convention, or a runtime probe) so the design does not *depend* on the
unverified fact being true.

---

## A. Required human steps (agent must NOT perform these)

### R1 — No paired test hardware · **high**
SharePlay + the transport cannot run in one simulator, and this build has no two Apple devices on
different iCloud accounts. **Every** hardware gate (F1–F14 acceptance, glass-to-glass latency, F7 at
the bound, `GroupActivitySharingController` presentation, TCC prompt flows, broadcast-extension memory
ceiling) is **PENDING**, not passed.
**Mitigation:** two-tier gates (see `TESTING.md`). Advance on the machine sub-gate (green
`swift build`/`swift test`, single-device capture→encode→decode→render loopback, `livekit-server
--dev` loopback). Every hardware item is a PENDING run-book step. **Never fabricate "verified on
hardware."**

### R2 — Human/destructive steps outside agent scope · **high**
Developer ID certificate + keychain access; notarization credentials; provisioning profiles + App
Group ID registration; `TEAM_ID` configuration; granting Screen Recording + Accessibility
(`kTCCServicePostEvent`) TCC permissions on test Macs; submitting the `persistent-content-capture`
entitlement request form to Apple; deploying the LiveKit VPS (domain, DNS, TLS certs, API secret).
**Mitigation:** `TEAM_ID` env placeholder with automatic/ad-hoc signing when unset; every step
enumerated here and in `TESTING.md`/`infra/README.md`; `infra/` ships a ready docker-compose so the
VPS step is one command after a human provides the box; the app degrades gracefully (LAN/loopback)
until server + signing exist.

### R5 — persistent-content-capture entitlement needs Apple approval · **medium**
`com.apple.developer.persistent-content-capture` (macOS 14.4+) requires prior Apple approval via a
request form before it can appear in a profile; timeline is Apple-controlled. Without it,
remote-control sessions on macOS 15+ face the R4 prompt friction.
**Mitigation:** submit the form early (R2); the app must fully function without it; the entitlement is
`#available`-inert on 14.0–14.3 so it never moves the floor.

---

## B. UNVERIFIED Apple-API assumptions (shimmed, queued for hardware/human verification)

### R10 — 256 KB GroupSessionMessenger cap is transcript-only · **medium**
The 256 KB per-message cap appears in **no** API reference — only the WWDC22 transcript. The messenger
also has an UNDOCUMENTED burst-throttle where rapid sends make `send()` throw.
**Mitigation:** never hard-code 256 KB as a protocol constant — `SignalingSendQueue` chunks at ≤200 KB
and treats a `send()` throw as the authoritative oversize/throttle signal (queue + backpressure +
retry/backoff); `ICECandidateBatcher` coalesces bursts; handshakes are staggered. *(both implemented +
unit-tested)*

### R11 — 100 MB GroupSessionJournal cap is transcript-only · **low**
Stated only in the WWDC23 transcript.
**Mitigation:** validate size before `add()`, surface a typed error, rely on the thrown error as the
real limit check.

### R12 — Extension-cannot-join-GroupSession is inferred · **low**
Only "this entitlement applies only to apps" is verified; the concrete runtime behavior is not.
**Mitigation:** architecture never tests it — all GroupActivities access is behind `SessionProviding`
in the app targets; the extension links only `JoeScreenBridge` (App Group IPC).

### R13 — SCStream pause-on-Space-switch is undocumented · **medium**
No Apple doc states it; "no frames" is ambiguous with `SCFrameStatus.idle` (unchanged content);
behavior may vary by macOS version.
**Mitigation:** `PauseDetector` (implemented + unit-tested with synthetic timelines) classifies
pause-vs-idle behind a protocol; runtime probe procedure per macOS version in `TESTING.md`.

### R14 — SCStreamConfiguration.pixelFormat default is undocumented · **low**
**Mitigation:** always set `pixelFormat` explicitly (420v) and debug-assert the received
`CVPixelBuffer` format.

### R15 — VideoToolbox low-latency rate-control specifics unverified · **low**
(a) whether low-latency mode *requires* an explicit `AverageBitRate` (WWDC21 implies it applies a
default if unset); (b) whether `ConstantBitRate` is specifically rejected on the low-latency H.264
path.
**Mitigation:** convention over contract — ALWAYS set `AverageBitRate` explicitly (deterministic,
harmless); NEVER set `ConstantBitRate` on the low-latency path; check the `VTSessionSetProperty`
`OSStatus` and treat `kVTPropertyNotSupportedErr` as expected.

### R16 — HEVC low-latency support unverified · **low**
No current source enumerates supported low-latency codecs beyond WWDC21's "H.264."
**Mitigation:** ship H.264 as the only low-latency VT codec; HEVC is out of v1 (D5); if ever wanted,
runtime-probe and fall back on non-zero `OSStatus`.

### R17 — Single hardware encode engine on base chips is secondary-sourced · **low**
Apple confirms singular engines only for M1 Pro / base M2 / base M3; base M1 rests on a third-party
table.
**Mitigation:** the design assumes ONE shared encoder on all base chips regardless (the conservative
case); Phase-0(f) measures actual max concurrent low-latency encodes and sets the windows-per-host cap
from data. `AdmissionController` already enforces a configurable `maxEncodeSessions` (default 1).

### R18 — QP-clamp keys on low-latency H.264 unverified · **medium**
`kVTCompressionPropertyKey_MaxAllowedFrameQP` / `MinAllowedFrameQP` support was not fact-verified.
**Mitigation:** attempt via `VTSessionSetProperty` treating `kVTPropertyNotSupportedErr` as expected;
fall back to `AverageBitRate` + libwebrtc quality-scaler thresholds; validate the clamp×maintainResolution
interaction in the Phase-0 A/B.

### R19 — Broadcast-extension lock/interrupt callback unverified · **medium**
`broadcastFinished`+kill vs `broadcastPaused` on device lock — Apple documents neither.
**Mitigation:** `SampleHandler` implements `broadcastPaused()`/`broadcastResumed()` AND
`broadcastFinished()`; last-known state persisted through the App Group so the host shows "sharing
interrupted (device locked)"; never assume the extension survives lock.

### R20 — RPSystemBroadcastPickerView auto-tap hack unverified beyond iOS 13 · **low**
Relies on a private view hierarchy.
**Mitigation:** user-tap picker is the SUPPORTED path; the hack lives behind a nil-safe helper that
degrades to the real picker; Control Center documented as the always-works route.

### R21 — ReplayKit deprecated at 27.0 · **medium**
Current doc metadata marks ReplayKit "no longer supported" at 27.0, with ScreenCaptureKit arriving on
iOS at 27.0 beta.
**Mitigation:** iOS capture sits behind a protocol (D11) so an SCK impl slots in at iOS 27; fully
supported for the iOS 17–26 target range.

---

## C. Ops / scaling / correctness

### R3 — Single-node self-hosted SFU is a SPOF + ops burden + plaintext media · **high**
Every internet session (1:1 included) depends on the VPS; media is PLAINTEXT in SFU memory (DTLS
terminates at the server) until E2EE via insertable streams lands.
**Mitigation:** self-host on team-controlled infra; document the trust model; keep the feature-flagged
LAN mesh as the degraded no-server mode; E2EE + LAN-deployed SFU are named v1.x items; LiveKit Cloud is
the managed escape hatch (same SDK). Embedded TURN/TLS on 443 removes separate coturn ops.

### R4 — macOS 15+ recurring screen-recording prompt · **medium**
Apps bypassing the system picker get a recurring (~monthly, cadence UNVERIFIED) re-approval dialog
users can't disable.
**Mitigation:** `SCContentSharingPicker` is the primary entry (exempt apps); onboarding anticipates the
prompt; MDM `forceBypassScreenCaptureAlert` documented for fleets; the sanctioned opt-out is R5's
entitlement.

### R6 — iOS cannot be remote-controlled (permanent) · **medium**
No public API injects input into other apps on iOS (DTS-confirmed); iOS shares full-screen only.
**Mitigation:** hard-coded asymmetry in the room model (control targets are Mac windows only); surfaced
in UI + docs; the terminal (F12) gives iOS first-class interactive participation since it's text.

### R7 — Broadcast-extension ~50 MB ceiling is empirical/undocumented · **high**
The figure comes from vendor docs + `EXC_RESOURCE` crash logs; it could shift per iOS release, and
exceeding it silently kills the extension.
**Mitigation:** budget conservatively — ≤720p downscale, immediate per-frame hardware encode, zero
pixel-buffer queuing, encoded-frames-only App Group handoff (`EncodedFrameRingBuffer` drops oldest on
overflow, never blocks the serial callback — implemented + unit-tested); peak-RSS measurement is a
run-book item.

### R8 — Secure Event Input is process-global · **medium**
Any app leaving `EnableSecureEventInput` on silently blocks ALL synthetic keystrokes system-wide.
**Mitigation:** `SecureInputDetector` polls the state, surfaces "remote typing blocked by <app>", and
the injector reports injection failures back to the controller instead of silently dropping.

### R9 — GroupActivitySharingController flaky on macOS · **medium**
Spec-flagged; the class itself is verified macOS 13+ in `_GroupActivities_AppKit`.
**Mitigation:** test on real Mac hardware in Phase 0(a); keep the fallback start path
(`prepareForActivation()` → `activate()` gated on `isEligibleForGroupSession`, plus
ShareLink/`GroupActivityTransferRepresentation`).

### R22 — LiveKit stack coupling · **medium**
The LAN mesh mode uses LiveKit's bundled WebRTC fork directly (off the supported path); an upstream
relicense or Swift-SDK deprioritization would strand the stack; linking a second libwebrtc is a hard
failure mode.
**Mitigation:** pin exact versions (D7); mesh mode stays feature-flagged (can ship dark); graph rule —
no second libwebrtc; mediasoup/Pion recorded as the fallback lineage.

### R23 — Encoding control mediated by the SDK, not raw VTCompressionSession · **medium**
The legibility knobs and the `BufferCapturer` "≥1 frame before publish" constraint are unproven through
LiveKit's publish options.
**Mitigation:** Phase-0 A/B validates each knob end-to-end through the SDK; the decision gate flips to
H.264 if VP9 can't be controlled adequately.

### R24 — Receiver downlink at the F7 bound (27–90 Mbps) · **high**
Visible-window-only selective subscription (dynacast/adaptive-stream) and the decode-visible-only cap
are load-bearing **correctness**, not optimization; simulcast behavior with detail-hint screen tracks
is unproven.
**Mitigation:** selective subscription is mandatory in `LiveKitTransport`; off-screen/minimized/unfocused
remote windows freeze-frame and unsubscribe (driven from the coordination plane); Phase-0(f) load test
derives the admission thresholds. `AdmissionController.canDecodeAnotherWindow` enforces the cap
(implemented + unit-tested).

### R25 — Server-mode hairpin adds RTT · **medium**
Co-located teams in server mode add ~40–80 ms, violating the ≤150 ms LAN ideal.
**Mitigation:** surface which mode a session is in (`SessionMode.viaServer` / `.localNetwork`); LAN mesh
flag recovers the budget for ≤3 co-located peers; LAN-deployed SFU is a named v1.x item.

### R26 — CGEventPostToPid to an unfocused window is unreliable + two TCC grants · **medium**
May need BOTH `kTCCServicePostEvent` (injection) and `kTCCServiceAccessibility` (AX focus-assist);
preflighting with `AXIsProcessTrusted()` checks the wrong service.
**Mitigation:** `InjectionPermissions` preflights the correct services separately with distinct
onboarding rows; `FocusAssist` handles stubborn targets; accept and surface that some UI needs focus;
tagged synthetic events let local input win.

### R27 — DRM/HDCP windows capture as black frames · **low**
Undocumented; no `SCWindow` flag exists.
**Mitigation:** `BlackFrameDetector` heuristic surfaces "this window appears to be protected content";
documented as observed behavior.

### R28 — Coordination-plane loss mid-session · **medium**
If the FaceTime call / `GroupSession` invalidates, the signaling channel dies; late-joiners get no
messenger backlog.
**Mitigation:** media connections (client↔SFU) survive independently by construction; `SessionManager`
re-broadcasts full state to new/rejoining participants; last-known room credentials persisted;
`GroupSessionJournal` snapshot for durable state.

### R29 — Local Network permission silently deniable (LAN QUIC path) · **low**
Bonjour/outbound connects just fail with no prompt-shaped error.
**Mitigation:** `LANQUICTransport` (when built) treats timeout-with-no-prompt as probable denial and
surfaces remediation; plist keys declared; infrastructure Wi-Fi preferred. Dormant while the seam is
unbuilt.

### R30 — LAN-mesh flag connects only same-LAN pairs · **low**
By design (host candidates only) non-LAN pairs fail; users may misread it as a bug.
**Mitigation:** mesh mode is gated to same-LAN detection, capped at 3 peers, labeled "local network
session"; a failed mesh connect offers one-tap "switch to server session."

---

## Open questions for a human (from the design pass)
1. Team ID for the `TEAM_ID` placeholder; who executes the signing/notarization/App-Group steps.
2. Submit the `persistent-content-capture` request form now? Under which account/bundle ID?
3. LiveKit hosting: VPS provider/region/domain + operator, or use LiveKit Cloud despite media-plane trust?
4. Is plaintext media at the self-hosted SFU acceptable for v1 (E2EE deferred to v1.x)?
5. Ship the LAN-mesh flag dark in v1, or cut until v1.x?
6. When can 2 Macs (one base Apple Silicon) + 1 iPad on **different** iCloud accounts be provided, and who runs the Phase-0 hardware spikes?
7. Who performs the human half of the codec legibility gate (blind side-by-side at 100% zoom)?
8. Is App Store submission of the iOS app actually intended (affects review-risk investment)?
9. If Swift 6 strict concurrency fails against LiveKit/SwiftTerm, is per-target Swift 5 fallback pre-approved (D1)?
