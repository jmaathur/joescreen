# Build Prompt: "JoeScreen" — a CoScreen-class multiplayer screen collaboration app for macOS + iOS (Swift, SharePlay-anchored)

> Paste this entire document as the opening prompt of a **Claude Code session running Opus 4.8 with ultracode enabled**. It is written to be executed by an agentic coding harness that can fan out subagents via workflows. Read the whole thing before writing code. The section **"§2 Hard platform constraints — READ FIRST"** overrides any instinct to "just stream the screen over SharePlay"; that is impossible and the architecture below exists because of it.

---

## §0. How you (the implementing agent) should work

- **Orchestrate if you can.** IF your harness exposes subagent/workflow orchestration (ultracode/Workflow), use it: fan out parallel readers to map Apple docs/sample code, run independent design panels for the risky subsystems (transport, capture, input injection), and adversarially verify every non-trivial API assumption. **Otherwise do the same steps sequentially** — the discipline matters more than the tool.
- **Verify APIs before use.** Every framework call you write should be traceable to a doc page or WWDC session you actually fetched this session — do NOT implement from memory on the SharePlay/ScreenCaptureKit/VideoToolbox/Network.framework surface; these APIs shift across OS versions and the exact availability annotations matter. **When an API can't be verified** (doc fetch fails, or developer.apple.com is JS-rendered and yields no usable text): mark it **UNVERIFIED in `RISKS.md`**, wrap it behind a narrow `@available`-guarded shim, prefer **WWDC transcripts / the SDK `.swiftinterface` headers** as secondary sources, and queue it for human verification — **never silently fall back to memory.**
- **Build vertically, not horizontally.** Ship a thin end-to-end slice first (two Macs, one shared window, view-only) before widening. A beautiful capture engine with no working transport is worthless.
- **You probably lack paired test hardware.** SharePlay + the transport can't run in one simulator, and you likely have no two Apple devices on different iCloud accounts. So: structure code so the non-networked pieces (capture, encode, decode, render, input mapping, wire protocol) have **unit-testable seams**; advance on the **machine sub-gate** (§7/§9); emit a **human hardware run-book** in `TESTING.md`; and **never fabricate "verified on hardware" results.**
- **Keep a running `DECISIONS.md`** (every option-choice + reason), **`RISKS.md`** (anything unverified or undocumented — there are several, flagged below), and **`TESTING.md`** (machine gates passed + the pending human hardware run-book).
- **Autonomy & destructive actions:** proceed autonomously through the phases; for a headless run, "destructive" means deleting files outside the repo, force-push, modifying signing/keychain, or installing system profiles — record any such need as a **required human step in `RISKS.md`** and continue with non-destructive work rather than blocking.

---

## §1. Product vision — what we are replicating

Build **JoeScreen**, a native Swift application for **macOS and iOS/iPadOS only**, that replicates the product experience of **CoScreen** (coscreen.co — the Datadog-owned "multiplayer mode for agile teams," being shut down July 31 2026). CoScreen's defining idea is a **shared team desktop**: instead of one person presenting one screen, *multiple people simultaneously share individual application windows*, and each shared window appears on every other participant's desktop as a **real, native, movable/resizable window filled with a live video stream** — not one big meeting tile. Everyone has their own cursor, and anyone can **click, type, draw, and copy/paste into any shared window at the same time**, with input routed back to and applied on the machine that owns the window, **without stealing that machine's focus** and **without a presenter-handoff or "request control" dance**.

The feature set to replicate (from CoScreen's own comparison table and use-case pages):

| # | Feature | CoScreen behavior to match |
|---|---------|----------------------------|
| F1 | **Single-user window sharing** | A user shares one application window; a peer sees it as a native window they can position freely. |
| F2 | **Multi-user simultaneous window sharing** | Multiple users each share one or more windows at the same time; everyone sees all shared windows side-by-side, forming a joint desktop. |
| F3 | **Selective per-window / whole-display sharing (privacy-preserving)** | Nothing is shared on join. User shares *chosen* windows; the rest of the screen stays private. Optional whole-display share auto-includes new windows on that display. |
| F4 | **Single-user remote control** | Two users can both drive one shared window with mouse + keyboard, without taking the owner's focus. |
| F5 | **Multi-user remote control** | Any participant can interact with any shared window, from any owner, simultaneously. |
| F6 | **Cross-user copy & paste** | Copy text in one user's window, paste into another user's window, across machines. |
| F7 | **Mob collaboration (3+ users)** | 3–10 participants in one session, all sharing and controlling. |
| F8 | **Multi-cursor presence** | Every participant's pointer is visible over shared windows, color-coded per participant, translated into each window's coordinate space, at high frame rate. |
| F9 | **Draw / annotate on shared windows** | A "Draw" mode lets anyone ink annotations over any shared window. |
| F10 | **Per-window interaction modes** | Each remote window offers Watch / Control / Draw; the sharer can disable remote control; a per-user "write access" toggle prevents accidental edits. |
| F11 | **Built-in voice (+ optional video) chat** | Low-fatigue audio chat with optional small camera bubbles; deliberately minimal, "artifact is the focus." |
| F12 | **Collaborative shared terminal (CoTerm)** | A shared terminal streamed as **PTY text, not video** (dramatically lower latency); multi-user type/draw/copy-paste; optional secret redaction (regex + entropy) before transmit. |
| F13 | **Persistent rooms + link invites + presence** | Named sessions that survive everyone leaving; join by link/ID; a "recent sessions" list; a contacts/presence list with one-click call. |
| F14 | **Session bootstrap integrations** | Start/join from a calendar event or a chat message (adapt to Apple-native equivalents; see §4.13). |

**Explicitly out of scope / adapted for Apple platforms (do not fight the OS):**
- **No Windows/Linux/web client.** macOS + iOS/iPadOS only, as requested.
- **iOS/iPadOS devices can share their screen and can *control* a Mac, but cannot themselves be remote-controlled** — iOS has no public API to inject input into other apps (Apple DTS-confirmed). Design so iPhone/iPad are always *controller + viewer + full-screen sharer*, and the *controlled* end is always a Mac window. See §2 and §4.5.
- **iOS shares the full screen only** (ReplayKit), not an individual window — per-window sharing is a macOS-only capability.

---

## §2. Hard platform constraints — READ FIRST (this dictates the whole architecture)

These are verified facts about Apple's frameworks as of 2025/2026. They are the reason the architecture in §3 looks the way it does. **Do not design around wishful versions of these.**

### 2.1 SharePlay / Group Activities is a coordination + small-data framework, NOT a media transport
- `GroupSessionMessenger` sends `Codable` messages capped at **256 KB each** (`send()` throws if larger). It rides the E2E-encrypted FaceTime data channel. WWDC guidance: it "should not be used for streaming large assets like files, images, or videos." It has **undocumented flow control** — sending a burst in a tight loop can make `send()` throw. `DeliveryMode.reliable` (TCP-like) and `.unreliable` (UDP-like) exist from **iOS 16 / macOS 13**.
- `GroupSessionJournal` (**iOS 17 / macOS 14**) transfers `Transferable` attachments up to **100 MB each**, delivered to late-joiners automatically. It is async file sync, **not a stream**.
- The only media-sync API in the stack is `AVPlaybackCoordinator` / `AVDelegatingPlaybackCoordinator`, which synchronizes *playback commands* (rate/seek/item) for media each device already possesses. **There is no API to stream arbitrary live video/screen/audio over SharePlay, and no API to access the FaceTime call's own audio/video streams or FaceTime's system screen-sharing.**
- **Conclusion:** SharePlay is used for **session grouping, participant presence, launching (which also gives you free FaceTime voice — see 2.4), and as a signaling/state channel**. All real-time media (screen video, cursors, input events, clipboard, terminal I/O, fallback audio) travels over a **custom transport you build** (§3.2).

### 2.2 SharePlay session start + reach
- A `GroupSession` only exists inside a FaceTime call or Messages conversation context. **Activation flow (verify exact API against live docs — see §10):** call `GroupActivity.prepareForActivation()` first and act on its result; only call `activate()` when the system reports it's eligible. Do **not** rely on "`activate()` throws when there's no call" as your gate — `activate()` is async and reports success/failure without cleanly surfacing "not in a call." On macOS, prefer `GroupActivitySharingController` (iOS 15.4+ / **macOS 13+**, a separate `NSViewController` subclass on Mac) to present a people-picker that *starts the call/conversation for you*, and gate any custom "start" button on `GroupStateObserver.isEligibleForGroupSession`. Messages-based (call-free) SharePlay needs iOS 16 / macOS 13. AirDrop-proximity start is **iPhone-only**; there is no Mac equivalent. (Note: `GroupActivitySharingController` presentation is reported flaky on macOS specifically — test it on real Mac hardware early and keep a fallback path.)
- **Apple-ecosystem only:** all participants must be Apple devices signed into iCloud/FaceTime. **SharePlay tolerates up to 33 participants, but live media does NOT scale to that — the media plane is the real limit (see §3.2 for the hard cap and relay requirement).** No Android/Windows/web. (Acceptable for the stated Mac+iOS scope; note it in `DECISIONS.md`.)
- `Participant` exposes only an **opaque UUID** — no name, handle, or network address. So to bootstrap the custom transport you must exchange your own connection info (WebRTC SDP/ICE, or Bonjour/endpoint tokens) *over `GroupSessionMessenger`*.
- Entitlement: `com.apple.developer.group-session` (Boolean), added by enabling the **Group Activities** capability in Xcode. No special Apple approval. App-target only (a broadcast extension cannot itself join a session).

### 2.3 macOS capture + input injection realities
- **Capture:** `ScreenCaptureKit` (**macOS 12.3+**). `SCContentFilter(desktopIndependentWindow:)` captures exactly one window regardless of display. **One `SCStream` per window** → capturing N windows = N streams. Per-stream CPU is modest on Apple Silicon, **but this does NOT mean sharing many windows is free — the hardware video-*encode* engine and the receive-side decode budget are the real limits (see §3.2/§3.3 for the encode/decode budgets you must enforce).** `SCContentSharingPicker` is a system picker (**macOS 14+**). Capture is **TCC-gated** (Privacy & Security → Screen & System Audio Recording); use `CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()`. **macOS 15 Sequoia adds a recurring (~monthly) re-authorization prompt** users can't disable; the exemption is the Apple-approval-gated `com.apple.developer.persistent-content-capture` entitlement (macOS 14.4+, intended for remote-desktop apps). **Caveats:** (a) SCK **audio capture is application-level only** — you cannot get audio for just one window; (b) **DRM/HDCP-protected windows** (some video/streaming apps) capture as **black/blank frames** — sharing them silently fails, so detect and message it; (c) when a shared window leaves the sharer's active Space, SCK may **stop delivering frames** — treat this as a *pause*, not a disconnect (see §4/F3 pause-on-Space-switch rule).
- **Input injection (the decisive constraint):** synthesizing mouse/keyboard on macOS uses `CGEvent.post`/`postToPid`, which is gated by the **`kTCCServicePostEvent`** TCC service (surfaced under **Accessibility** in System Settings) — this is a *separate* service from `kTCCServiceAccessibility` (the one `AXIsProcessTrusted()` checks, used by the `AXUIElement` API). An app can hold one and not the other, so **do not preflight injection with `AXIsProcessTrusted()`** — that checks the wrong service. If you also use AX APIs for window focus-assist, you'll need `kTCCServiceAccessibility` too, so the app may need **both** grants. Crucially: **these permissions are unavailable to sandboxed apps** — a sandboxed app can't be added to the Accessibility list at all. **Therefore the macOS app must be distributed as a Developer ID (notarized) app OUTSIDE the Mac App Store.** Screen capture alone *can* be sandboxed/MAS; **input injection is what forces Developer-ID distribution.** Record this as the top architectural constraint.
  - **Secure Event Input is process-global:** any app that has left `EnableSecureEventInput` on blocks synthetic keystrokes *system-wide*, not just in its own field — so remote typing can silently fail even outside the shared window. Detect and surface it.
  - Tag synthetic events (`CGEvent` `eventSourceUserData`/`setIntegerValueField(.eventSourceUserData)`) so the owner machine can distinguish local vs remote input and let local input win (prevents cursor fights).
  - `CGEventPostToPid` can target a process without globally raising it, but **delivery to a specific *unfocused* window is unreliable per-app** — plan for an AX-based window-raise/focus assist for stubborn targets, and accept that some UI needs focus.
  - **Secure input fields** (`NSSecureTextField` / `EnableSecureEventInput`, e.g. password fields, terminals with secure keyboard entry) **block all synthetic keystrokes** — no workaround. Surface this to the user as "this field can't be remote-controlled."
- **Cursors:** render remote pointers in a transparent, click-through overlay `NSWindow` (`ignoresMouseEvents = true`, high level like `.statusBar`, `collectionBehavior` incl. `.canJoinAllSpaces`, `orderFrontRegardless()`).
- **Clipboard:** `NSPasteboard` has **no change notification** — poll `changeCount` on a timer (~0.3–0.5 s). Write via `clearContents()` + `writeObjects()`.

### 2.4 iOS realities
- **Screen out:** two paths, both **ReplayKit**. (a) In-app `RPScreenRecorder.startCapture` — easy, HD, but only your own app and stops on backgrounding. (b) **Broadcast Upload Extension** via `RPSystemBroadcastPickerView` — captures the **whole device screen** (no per-window selection on iOS), runs in a separate process under a **hard ~50 MB memory ceiling** (ReplayKit's own buffers eat ~half), so you **must downscale (≤720p) and hardware-encode (VideoToolbox H.264) per-frame in the extension** and never queue `CVPixelBuffer`s. The picker can't be launched programmatically except via a fragile subview-`sendActions` hack; broadcasting pauses on lock. The extension is a separate process → move encoded frames to the host app via an App Group, or (simpler) transmit straight from the extension. **The group-session entitlement is app-only**, so the extension can't join SharePlay — the host app owns SharePlay and hands the extension the transport info via the App Group.
- **iOS as viewer/controller (fully supported):** decode incoming H.264/HEVC with `AVSampleBufferDisplayLayer` (enqueue compressed `CMSampleBuffer`s, set `kCMSampleAttachmentKey_DisplayImmediately`) or `VTDecompressionSession`→Metal for custom rendering; pinch-zoom a remote Mac window by hosting the display layer in a `UIScrollView`/Metal transform; map `UIGestureRecognizer`/keyboard events to remote-input messages sent over the control channel and injected on the Mac.
- **iOS cannot be controlled** (no event-injection API, DTS-confirmed). Hard-code this asymmetry.

### 2.5 Voice/audio
- When a Group Activity runs **during a FaceTime call, FaceTime carries voice/video automatically** and you implement nothing — this is the "free" path and the recommended default for F11's audio. **But you get ZERO programmatic access to those FaceTime streams** — so any *in-app* camera bubbles, per-participant mute, or custom audio routing must be built on your own transport regardless of FaceTime. When SharePlay starts from Messages (no call), **there is no voice channel at all** — you need the fallback: `AVAudioSession(.playAndRecord, mode: .voiceChat)` + `AVAudioEngine` with `setVoiceProcessingEnabled(true)` (echo cancel; must be set while engine stopped) + `AVAudioConverter` PCM↔Opus over the custom transport.

---

## §3. Target architecture

Two planes. **Coordination plane = SharePlay. Media plane = your own transport.**

```
                    ┌────────────────────── SharePlay / Group Activities ──────────────────────┐
                    │  • Start session (GroupActivitySharingController → FaceTime = free voice)  │
                    │  • Participant presence / roster (opaque UUIDs)                            │
COORDINATION PLANE  │  • GroupSessionMessenger (≤256KB, reliable+unreliable):                    │
(low-rate, SharePlay)│      – signaling: exchange transport connection info (SDP/ICE or tokens)  │
                    │      – session state: who's sharing which window, control-mode toggles,    │
                    │        write-access flags, room metadata                                   │
                    └───────────────────────────────────────────────────────────────────────────┘

                    ┌───────────────────────── Custom media transport ─────────────────────────┐
                    │  WebRTC (stasel/WebRTC xcframework via SPM) — DTLS-SRTP, STUN/TURN NAT     │
                    │  traversal, congestion control. Topology by size (§3.2): mesh ONLY for     │
                    │  tiny sessions; a selective-forwarding relay (SFU/MCU-lite) is REQUIRED    │
                    │  for the F7 3–10 target and any multi-window scenario. Per-window video     │
                    │  track + typed data channels.                                              │
MEDIA PLANE         │  LAN alt (Phase-0(d) fallback / same-LAN option): Network.framework —      │
(real-time, custom) │  Bonjour discovery + NWConnection QUIC; NOT built in parallel with WebRTC.  │
                    │  Carries: per-window H.264/HEVC/VP9 video, cursor moves (unreliable),      │
                    │  discrete input (reliable+ordered), clipboard/terminal (reliable),         │
                    │  draw ops, fallback Opus audio — see the §3.2 channel matrix.               │
                    └───────────────────────────────────────────────────────────────────────────┘
```

### 3.1 Coordination plane (SharePlay) — responsibilities
- Define `JoeScreenActivity: GroupActivity` (`Codable`, unique `activityIdentifier`, `GroupActivityMetadata` with title/type/fallbackURL). Conform to `Transferable` for share-sheet/ShareLink start (iOS 17/macOS 14 path).
- Start via `prepareForActivation()`→`activate()` (see §2.2) and/or `GroupActivitySharingController`, gated on `isEligibleForGroupSession`. Manage lifecycle: `sessions()` async sequence → `join()` → observe `activeParticipants` → `leave()`/`end()`. Hold strong refs to session + messenger + journal; drop on `.invalidated`. The participant set is always the SharePlay roster — **already-authenticated Apple-ID peers**, keyed by their stable in-session `Participant` UUIDs (with `session.localParticipant` as self) — so the media transport is doing NAT traversal *between authenticated peers*, not open-internet room joining.
- Use `GroupSessionMessenger` for **signaling and low-rate session state only**, never per-frame data. Put **all real-time payloads (video, cursors, input, clipboard, terminal, draw) on the media transport's data channels**, not the messenger — see the §3.2 channel matrix. Reserve the messenger for: transport bootstrap/signaling, and low-rate state (who's sharing which window, control-mode toggles, write-access flags, pause/unshare events). Record the split in `DECISIONS.md`.
- **Signaling discipline (build this explicitly — the #1 cause of "connected but no video"):** trickle ICE emits many tiny candidate messages at setup; multiplied across peers this trips the messenger's undocumented burst-throttle and silently drops candidates. So: (1) **coalesce/batch ICE candidates** (end-of-candidates or a short debounce) instead of one `send()` per candidate; (2) put a **send queue with backpressure + retry/backoff** in front of the messenger and treat a `send()` throw as "retry," using `.reliable` for signaling; (3) **stagger per-peer handshakes** so simultaneous connections don't burst together. The message *size* is rarely the problem (SDP is a few KB) — the *burst* is.
- **Coordination-plane loss recovery:** if the FaceTime call / `GroupSession` invalidates, the signaling channel dies. Design so established media `PeerConnection`s **survive on their own ICE** and the app re-establishes a signaling path (persist last-known peer endpoints; optional lightweight fallback signaling) rather than tearing down the whole session.
- Late-joiners get nothing from the messenger automatically — re-broadcast current session state to a new participant on join (or use `GroupSessionJournal` on iOS 17/macOS 14+ for the room's durable state/snapshot).

### 3.2 Media plane (custom transport) — the load-bearing decisions

Expose a `MediaTransport` protocol, but **build WebRTC only** through the vertical slice and early phases (do NOT implement two full real-time transports in parallel — that splits scarce effort). WebRTC = `stasel/WebRTC` xcframework via SPM (Google no longer ships official prebuilt WebRTC Apple binaries; use a community xcframework and **pin a known-good version**). Signaling (batched SDP + ICE, per the §3.1 discipline) rides `GroupSessionMessenger`.

**Topology — mesh does NOT scale to the F7 target; a relay is required.** Full-mesh egress is `(peers − 1) × (windows this host shares) × per-window bitrate`. A host sharing just 2 windows at 3–5 Mbps to 9 peers needs **54–90 Mbps up** — beyond typical uplinks. So:
- **Mesh only** for tiny sessions (≈2–3 peers) with a small total shared-window count.
- A **selective-forwarding relay (SFU, or one participant acting as an "MCU-lite" relay)** is the **REQUIRED** path for the F7 3–10 target and for any multi-window scenario. Decide who hosts it (a designated participant relay, or a deployed lightweight SFU such as self-hosted mediasoup/LiveKit) and record the NAT/trust/ops implications in `DECISIONS.md`/`RISKS.md`. **This is a Phase-0 spike, not a Phase-6 follow-up.**
- **Uplink admission control:** before adding a share, check `windows × peers × bitrate` against measured available uplink and **degrade quality or refuse (with a clear "session at capacity for live sharing" state)** rather than silently saturating the link. Hard-cap the live-media participant/window counts and surface the cap in the UI.

**Encode budget (real, and unmentioned by "cheap per stream"):** base M1/M2/M3 have a **single hardware video-encode engine** (only Pro/Max/Ultra add more). N concurrent low-latency encode sessions **degrade** (frame pacing, latency), they don't scale linearly. So: measure the max concurrent low-latency encode sessions before pacing collapses on a **base** Apple Silicon Mac (Phase-0 spike) and **cap shareable-windows-per-host** accordingly with graceful "you can share N more" UI. Design option to keep in mind: when a host shares many windows, tile them into **one atlas encode stream** instead of N independent encoders, trading per-window independence for encoder headroom.

**Decode budget (the real receive-side wall):** each receiver runs one `VTDecompressionSession` + `AVSampleBufferDisplayLayer` + `NSWindow` **per remote window per sharer** — dozens in a busy session. **Cap the number of simultaneously-decoded remote windows; only decode *visible* windows** — auto-pause/last-frame-freeze windows that are off-screen, minimized, or unfocused, driven from the coordination plane.

**Codec choice — make it an explicit, verified decision (`DECISIONS.md`):** hardware **HEVC/H.264** = low CPU but patchy WebRTC interop and weaker small-text legibility; **VP9/AV1** = best text legibility but software-only on Apple (high CPU, and it fights the encode budget above). Set `contentHint = .detail` regardless. Recommended default: **VP9 for legibility on capable Macs, hardware H.264 fallback under encoder pressure.** **Do NOT copy Multi.app's QP bounds (8–52 → 4–36) onto HEVC/H.264 — those numbers are VP9-specific;** derive per-codec bounds. Add a Phase-0 A/B test rendering small monospaced text across codecs on real hardware. Other legibility tuning (real, verified): `degradationPreference = .maintainResolution`, cap ~30 fps, zero the jitter/playout delay (Multi.app measured ~90 ms saved).

**Per-channel reliability/ordering matrix (specify in the wire protocol — semantics are OPPOSITE per payload):**

| Payload | Reliability | Ordering | Notes |
|---|---|---|---|
| Pointer/cursor move (~60 fps) | **unreliable** | unordered | latest-wins; coalesce; never retransmit stale positions |
| Discrete input (key down/up, mouse down/up/click, scroll) | **reliable** | **ordered** | monotonic seq # + source-participant id; owner injects in receipt order, detects loss, rejects out-of-order |
| Clipboard | reliable | ordered | size/type limits |
| Terminal PTY bytes | reliable | ordered | — |
| Draw ops | reliable, ordered per author | per-author | or unreliable + periodic full-stroke resync |
| Video frames | unreliable (RTP/SRTP) | — | WebRTC media track, not a data channel |

Putting keystrokes on the cursor's lossy channel silently drops/reorders input and corrupts the remote session — the matrix is not optional.

**NAT traversal & reach — TURN is mandatory for real internet:** STUN alone cannot traverse **symmetric NAT**, so real-internet peer pairs will silently fail without a **TURN relay**. Either deploy TURN (coturn or hosted) with credential provisioning, **or explicitly scope v1 to STUN-only + same-LAN** and move TURN/self-hosted signaling to `RISKS.md` with the ops/cost implication stated honestly — do not imply "Apple-only, no server" works over the open internet, because it doesn't.

**LAN alt (do not build in parallel — it's the Phase-0(d) fallback + a same-LAN option):** Network.framework — Bonjour advertises **host+port over TCP/UDP only** (discover, then dial QUIC separately; don't advertise QUIC directly), `NWConnection` QUIC (TLS 1.3 required — cert plumbing via `swift-certificates`), reliable streams for input/clipboard/terminal, datagrams (iOS 16+) for frames. Prefer **infrastructure Wi-Fi**; set `includePeerToPeer = true` (AWDL, needs Wi-Fi on, not cellular-only) only when there's no shared LAN — it adds hundreds of ms and degrades infra Wi-Fi. Needs `NSLocalNetworkUsageDescription` + `NSBonjourServices`, and **the Local Network permission can be denied silently** (connections just fail) — handle denial explicitly, not just the plist keys. Add retry/delay on the NWBrowser→NWConnection race. This path is loopback-testable with no external STUN/TURN, which is exactly why it's the fallback if the WebRTC spike is the only red one.

### 3.3 Capture
- **macOS:** `SCStream` per shared window (`SCContentFilter(desktopIndependentWindow:)`), `SCStreamConfiguration` (`minimumFrameInterval` for fps, `showsCursor = false` since remote cursors are rendered separately, `pixelFormat` 420v default), feed frames to a per-window `VTCompressionSession` in **low-latency mode** (`kVTVideoEncoderSpecification_EnableLowLatencyRateControl`; HEVC on Apple Silicon, else H.264; no B-frames). **Low-latency mode requires you to set an explicit average bitrate** (`kVTCompressionPropertyKey_AverageBitRate`) — this is the correct mode; it is *not* the same as `ConstantBitRate` (`kVTCompressionPropertyKey_ConstantBitRate`), which is incompatible with low-latency H.264. Respect the **encode budget** in §3.2 (cap windows-per-host; consider atlas encode). Optional `SCContentSharingPicker` for the share UI on macOS 14+.
- **Minimize = unshare (CoScreen behavior):** minimizing a shared window auto-unshares it. `SCContentFilter(desktopIndependentWindow:)` keeps streaming a minimized window, so you MUST detect miniaturization / off-screen state and **stop the corresponding `SCStream` and broadcast an unshare event** — otherwise you leak a window CoScreen would have hidden.
- **iOS:** ReplayKit broadcast extension, ≤720p, immediate VideoToolbox H.264 encode. **Transport location decision (Phase-0/5 benchmark):** the extension can't join SharePlay (app-only entitlement) and lives under the ~50 MB cap; WebRTC's resident footprint may not fit. Preferred design: **encode in the extension and hand small ENCODED `CMSampleBuffer`s to the host app over an App Group ring buffer; the host owns the `PeerConnection`.** Do not push raw pixel buffers across the App Group at video rates.

### 3.4 Rendering ("native window recreation" — the core magic of F1/F2)
- **macOS receiver:** for each remote shared window, create a **real borderless/titled `NSWindow`** whose content is a Metal/`AVSampleBufferDisplayLayer` view fed by the decoded stream. Make it movable/resizable **locally** (resize = local scaling only; it must not reflow the sender's window). Draw the sharer's **assigned color as a border**. Two distinct affordances (don't conflate them): (1) a **per-remote-window mode tab** carrying **Watch / Control / Draw** and a "Bring to front" action; (2) on the **sharer's own** shared window, a dedicated **drag grip** (6-dot style, à la CoScreen) for safe local repositioning — dragging by the titlebar risks a minimize, which unshares it (see §3.3). **Windows default to Watch (no injection)** — a participant must explicitly switch to Control (see §3.5). This native-window recreation is what makes it feel like a shared desktop instead of a video call.
- **iOS receiver:** each shared window is a zoomable view (scroll/Metal) — on a phone likely one-at-a-time or a paged/grid layout; on iPad a freeform canvas closer to the Mac.
- **Multi-cursor overlay:** transparent click-through overlay window (macOS) / overlay view (iOS) drawing every participant's pointer at 60 fps, color-coded, positioned in each window's coordinate space, with optional name labels.

### 3.5 Input + clipboard + draw + terminal
- **Input (Mac target only), per the §3.2 channel matrix:** pointer moves on the unreliable/unordered channel (coalesce-to-latest); discrete key/mouse/scroll events on the reliable/ordered channel with a monotonic seq # + source-participant id. The owner Mac maps window-local coords back to global and injects via `CGEvent` (tagged synthetic so local input wins; focus-assist for stubborn windows; respects the secure-input block).
  - **Default is Watch (no injection).** "Multi-user control" (F5) means different users on different windows, or **turn-taking** on one window via a soft single-active-controller lock surfaced in the window UI — *not* simultaneous injection into one text field (which interleaves into gibberish; do not attempt CRDT merge). Build the soft lock; it's the safe default, not a stretch.
  - **Security (this is the highest-consequence surface — a non-sandboxed, Accessibility-privileged app synthesizing input from remote peers):** (1) **authenticate/integrity-protect every input & control message** and bind data-channel input to the **DTLS-authenticated peer** plus an owner-issued capability — do NOT trust in-band control/write-access flags alone, since those ride the coordination plane while injection happens on the data plane; (2) **enforce authorization on the OWNER at injection time** against trusted *local* state (control-mode, write-access), and **clamp injected coordinates to the shared window's bounds** so a malicious peer can't address other windows/apps; (3) treat clipboard & terminal as explicit consent surfaces with a visible "being shared" indicator; (4) document that F12 redaction is **best-effort, never a security boundary.**
- **Clipboard (F6):** poll `NSPasteboard.changeCount`; on change from a shared window's app, ship over the reliable channel; on receipt, write to the local pasteboard. **Prioritize plain-text/UTF-8 with exact whitespace/newline preservation first** (code is the primary use case) — done-when a multi-line code snippet pastes across machines byte-intact — then RTF/image, with size/type limits.
- **Draw (F9):** vector ink ops (points + color + participant id) on the reliable-ordered-per-author channel (or unreliable + periodic full-stroke resync), rendered in the per-window overlay on all peers.
- **Terminal (F12):** a real PTY on the host (spawn a shell via `posix_spawn`/`Process` + pseudo-terminal), stream **bytes not video** over a reliable channel to a terminal view (SwiftTerm or a hand-rolled VT parser) on every peer; multi-writer input; optional secret redaction (regex for keys/tokens/cards/SSNs + Shannon-entropy scan) applied **before** transmit. Because it's text, **iOS is a first-class terminal client here.** This is a distinct, much-lower-latency path than screen sharing — implement it as such.

### 3.6 Shared modules
Structure so macOS and iOS share as much as possible:
- `JoeScreenKit` (shared Swift package): activity definition, session manager, `MediaTransport` protocol + WebRTC & Network.framework impls, signaling, wire protocol (Codable message envelope for control/cursor/input/clipboard/draw/terminal), video codec wrappers, presence/roster, room model.
- `JoeScreenCaptureMac`, `JoeScreenInputMac` (Developer-ID Mac-only, non-sandboxed).
- iOS broadcast extension target.
- Two app targets (`JoeScreen-macOS` AppKit/SwiftUI, `JoeScreen-iOS` SwiftUI) + a shared SwiftUI feature layer where practical.

---

## §4. Feature spec with acceptance criteria (build to these)

For each: **platform matrix** (M=macOS, i=iOS) and a concrete **done-when**. Implement roughly in this order within the phases of §7.

- **F1 Single-user window sharing** (M share→M/i view). *Done when:* Mac A shares one window via a hover "Share" affordance or picker; Mac B and an iPad see it as an independent, movable window with live ≤~150 ms LAN video; nothing else on A's screen is visible.
- **F2 Multi-user simultaneous sharing** (M share; M/i view). *Done when:* A shares its IDE while B shares its terminal at the same time; both, plus an iPad, see both windows side-by-side, each labeled with the owner's color.
- **F3 Selective + whole-display share, privacy default** (M full; i full-screen-only). *Done when:* joining shares nothing; sharing is explicit per window (hover "Share" tab **and** a drag-onto-designated-shared-display gesture: drag on = share, off = unshare); a "share display" mode auto-shares new windows on that display; unsharing is one action; **minimizing a shared window auto-unshares it** (§3.3); when a shared window leaves the active Space its stream **pauses** (paused affordance shown) and **resumes** on return rather than reading as a disconnect. iOS offers full-screen share via the broadcast picker only.
- **F4 Single-user remote control** (target=M). *Done when:* both A and B move the pointer and type into A's shared window; input applies on A without raising/refocusing A's app for the local user; synthetic events are tagged so A's own input overrides.
- **F5 Multi-user remote control** (target=M **only**; iOS-origin shares are viewer/controller endpoints, exempt as control *targets*). *Done when:* in a 3-person session, participants drive different Mac-owned windows concurrently, and on a single window a **soft single-active-controller lock** (turn-taking, surfaced in the window UI) governs who's driving; injection respects receipt order + the §3.5 security checks. (True simultaneous injection into one field is a non-goal — it interleaves; no CRDT.)
- **F6 Cross-user copy & paste** (M↔M; M→i view of pasteboard). *Done when:* copying **a multi-line code snippet** in A's shared window makes it pasteable byte-intact (UTF-8, whitespace preserved) in B's window on B's machine, and vice-versa.
- **F7 Mob collaboration 3–10** (M/i). *Done when:* a session at the **claimed upper bound** works with per-participant colors, roster, and F2/F5/F8 holding, routed through the **selective-forwarding relay** (§3.2) — not plain mesh — with the uplink **admission check** active so quality degrades/refuses instead of saturating. Bitrate-bounded: exercise the actual upper bound, not just "3+".
- **F8 Multi-cursor presence** (M/i). *Done when:* every participant's pointer shows over shared windows in their color at ~60 fps, in correct per-window coordinates.
- **F9 Draw/annotate** (M/i). *Done when:* any participant inks on any shared window and all peers see it live; clear/undo per author.
- **F10 Interaction modes + write-access** (M/i UI; enforce on M target). *Done when:* each remote window has Watch/Control/Draw with **Watch the default** (no injection until a user explicitly takes Control); the sharer can globally disable control; a per-user write-access toggle blocks that user's injection; enforcement is on the **owner Mac** against trusted local state (§3.5), dropping injected events for Watch-mode windows.
- **F11 Voice (+optional video) chat** (M/i). *Done when:* sessions started via FaceTime carry voice automatically (implement nothing); Messages-started sessions get the AVAudioEngine+Opus fallback; optional small camera bubbles, minimal by design.
- **F12 Collaborative terminal** (M host; M/i view+type). *Done when:* a shared PTY streams text to all peers with visibly lower latency than screen sharing; multiple users type; optional secret redaction masks obvious credentials before transmit. (iOS is a first-class terminal client here since it's text, not injection.)
- **F13 Persistent rooms + invites + presence** (M/i). *Done when:* sessions are named and rejoinable, appear in a "Recent" list (local store + `GroupSessionJournal` snapshot), invite via SharePlay link / share sheet, and a contacts/presence list shows availability with one-tap start. (True server-side persistence surviving all-participants-leaving is a documented `RISKS.md` item, not a v1 promise — see §6.)
- **F14 Bootstrap integrations** (M/i). *Done when (minimal):* a session is startable from the system **share sheet / `ShareLink`** via `GroupActivityTransferRepresentation`, and via a **custom-URL deep link**. *Optional stretch:* EventKit "start JoeScreen" from a calendar event, Messages-based start. Skip Slack/Zoom/Datadog-specific integrations (out of scope for Apple-only); note them in `DECISIONS.md`.

---

## §5. Tech stack & project layout

- **Language/UI:** pin **one Swift language mode** (recommend Swift 6 with strict concurrency; if that fights the dependencies, fall back to Swift 5 language mode and record why) — don't leave it ambiguous. SwiftUI for shared UI, AppKit interop on Mac for real `NSWindow` recreation + overlays + `NSViewControllerRepresentable` for `GroupActivitySharingController`.
- **Frameworks:** GroupActivities, ScreenCaptureKit (M), ReplayKit (i), VideoToolbox, CoreMedia, AVFoundation, Network, CoreGraphics/AppKit (M input+overlay), Metal/MetalKit, UniformTypeIdentifiers.
- **Third-party (SPM):** `stasel/WebRTC` (media), `swift-certificates` (QUIC LAN path), a terminal renderer (e.g. `SwiftTerm`) for F12. **Pin exact known-good versions** — `stasel/WebRTC` tracks Chromium branches and `SwiftTerm` churns; record the pins and a bump policy in `DECISIONS.md`.
- **Deployment targets (recommend; justify in `DECISIONS.md`):** macOS 14+ and iOS 17+ to get `GroupSessionJournal`, `.unreliable` messenger, `SCContentSharingPicker`, and `ShareLink` start. (macOS 13/iOS 16 is possible with feature degradation; macOS 12 loses too much.)
- **Build/run/test scaffolding (set up first):** state a **minimum Xcode version floor**; define the exact `xcodebuild`/`swift build`/`swift test` invocations and **scheme names** the agent keeps green; use a `DEVELOPMENT_TEAM` / signing-identity **placeholder strategy** (e.g. a `TEAM_ID` env var; if unset, automatic/ad-hoc signing, noted). **The non-networked package targets staying `swift build`/`swift test`-clean is the PRIMARY agent-checkable gate** (see §9). Put all of this in the `README`.
- **Repo layout:** a single Xcode workspace / Swift package graph as in §3.6, with `README.md`, `DECISIONS.md`, `RISKS.md`, `TESTING.md`, and a `docs/architecture.md` you keep current.

---

## §6. Entitlements, permissions, distribution (get this right early — it gates everything)

- **Group Activities capability** → `com.apple.developer.group-session` on both app targets.
- **macOS app: NOT sandboxed → Developer ID + notarization** (because input injection needs Accessibility, which sandbox forbids). Request **Screen Recording** (TCC) and **Accessibility** (TCC) at first use, with clear onboarding UI and preflight checks; handle the macOS 15 recurring screen-recording prompt (and note the `persistent-content-capture` entitlement as a future Apple-approval request in `RISKS.md`).
- **iOS:** ReplayKit broadcast extension target + App Group shared between host and extension; `NSMicrophoneUsageDescription`, `NSCameraUsageDescription` (if video bubbles), `NSLocalNetworkUsageDescription` + `NSBonjourServices` (if Network.framework path), `NSPhotoLibraryUsageDescription` only if needed.
- **Info.plist:** custom URL scheme for invite deep links; `GroupActivities` activity registration.
- **Broadcast picker:** ship the plain **user-tap `RPSystemBroadcastPickerView`** as the *supported* path (the user must confirm "Start Broadcast" in the system sheet regardless — it can't be fully programmatic); treat the `sendActions` auto-tap as **best-effort polish** that relies on a private view hierarchy and breaks across iOS versions. Since this deliverable isn't going to App Review, don't over-invest there — flag the review risk in `RISKS.md` for a real submission.
- **Server-side reality (`RISKS.md`):** a real deployment needs a **TURN server** (§3.2) and, for truly persistent rooms surviving all-participants-leaving, **server-side room persistence** — neither is "Apple-only, no server." v1 may scope to STUN+LAN and local Recents + a `GroupSessionJournal` snapshot; say so explicitly rather than implying full internet persistence works for free.
- Document the **App Store consequence** prominently: the Mac app ships outside MAS (Developer ID + notarization); the iOS app *could* ship on the App Store subject to the review risks above.

---

## §7. Implementation phases

**Two-tier gates (read §9 first).** You (the executing agent) almost certainly have **no two paired Apple devices on different iCloud accounts** — so every phase has (1) a **machine sub-gate** you *can* pass (compiles, `swift build`/`swift test`-clean on non-networked seams, single-process loopback where the API allows, single-device capture→encode→decode→render, architecture + docs complete) and (2) a **hardware sub-gate** you record as **PENDING** in `TESTING.md` as a human run-book. **Do NOT fabricate "verified on hardware" results.** Advance on a green machine sub-gate; never block scaffolding on unavailable hardware.

1. **Phase 0 — Spikes & de-risking (do these first).** Prove each as a tiny throwaway:
   - (a) `GroupSession` start (`prepareForActivation`/`GroupActivitySharingController`) + a hello over `GroupSessionMessenger` between two Macs.
   - (b) one-window `SCStream`→low-latency `VTCompressionSession`→loopback decode→`AVSampleBufferDisplayLayer` render (single-device, **machine-gateable**).
   - (c) `CGEvent` injection into a target window on a Dev-ID non-sandboxed Mac with the `kTCCServicePostEvent` grant, incl. tagged-event local-override (single-device, **machine-gateable**).
   - (d) a WebRTC video track between two devices. **This is the hardest, most-likely-red item — if only (d) is red, fall back to the Network.framework/QUIC LAN transport (loopback-testable, no STUN/TURN) for the Phase-1 slice and defer WebRTC; don't let (d) freeze (a)–(c).**
   - **(e) INTEGRATION spike (the seam most likely to kill the project):** bring up a real `PeerConnection` between two Macs using **only** `GroupSessionMessenger`-relayed signaling (no hand-relay), exercising the trickle-ICE **burst discipline** (§3.1), and **measure glass-to-glass latency**.
   - **(f) Scaling micro-spike:** a 3-peer / 2-window session that **measures actual uplink consumption** and the **max concurrent encode/decode sessions** on a base Apple Silicon Mac — so the mesh-vs-relay and window-cap decisions (§3.2) are **data-driven before Phase 2**, not discovered in Phase 6.
2. **Phase 1 — Vertical slice.** Mac A shares one window, Mac B views it as a native window, over the real transport, signaling over SharePlay, voice via FaceTime. (F1, minimal F3, F11-free-path, F13-minimal.)
3. **Phase 2 — Multi-share + presence + cursors + relay.** F2, F8, roster/colors, iPad viewer, and the **selective-forwarding relay** stood up (from 0(f)) so F7 is reachable — not deferred.
4. **Phase 3 — Remote control + clipboard + modes + security.** F4, F5 (soft lock), F6 (code paste), F10 (default-Watch), the §3.5 input-security checks, secure-input handling, focus-assist.
5. **Phase 4 — Draw + terminal.** F9, F12 (PTY path + redaction; iOS terminal client).
6. **Phase 5 — iOS sharing + fallback audio + polish.** iOS broadcast-extension full-screen share (with the §3.3 transport-location benchmark), Messages-start Opus voice fallback, permission onboarding, persistent rooms/recents/invites (F13/F14), settings.
7. **Phase 6 — Hardening + F7 at the bound.** Reconnection + coordination-plane-loss recovery, late-joiner resync, relay/admission-control at the claimed F7 upper bound, encode/network adaptation, decode-budget pausing, energy/CPU, error surfaces, accessibility, pause-on-Space-switch, and a full multi-device manual test pass against every F-criterion.

At each phase, run `/code-review` (ultra where warranted) and a `verify`-style end-to-end check; where hardware is unavailable, verify the machine sub-gate and extend the `TESTING.md` run-book.

---

## §8. Known gotchas / guardrails (paste these into your working notes — they are landmines)

*Landmine index — a fast checklist cross-referencing §2/§3, not new requirements.*

1. **Never push video/frames through `GroupSessionMessenger` or `GroupSessionJournal`.** 256 KB cap + burst-throttle; journal is async ≤100 MB attachments. Media = custom transport only.
2. **Gate SharePlay start on `prepareForActivation()` + `isEligibleForGroupSession`**, not on "`activate()` throws." On macOS prefer `GroupActivitySharingController`.
3. **Signaling fails from BURST, not size:** batch/coalesce ICE candidates, queue+retry+backoff on the messenger, stagger per-peer handshakes (§3.1). This is the #1 "connected but no video" cause.
4. **Mesh doesn't scale — relay is required** for F7/multi-window; enforce the uplink admission check and encode/decode budgets (§3.2). Don't defer to Phase 6.
5. **Per-channel semantics are opposite:** cursor = unreliable/unordered, discrete input = reliable/ordered+seq. Wrong channel silently corrupts input (§3.2 matrix).
6. **macOS input injection ⇒ non-sandboxed Developer-ID build.** Day-one decision. Gated by `kTCCServicePostEvent` (not `AXIsProcessTrusted`'s `kTCCServiceAccessibility`) — may need both; screen capture alone doesn't force non-sandbox, injection does.
7. **Input plane is the top security surface:** authenticate control/input messages to the DTLS peer + owner capability, enforce on the owner against local state, clamp coordinates to the window (§3.5). In-band flags alone are forgeable.
8. **Secure Event Input is process-global** and silently eats synthetic keystrokes; **`CGEventPostToPid` to an unfocused window is per-app unreliable** (AX focus-assist, accept gaps); **tag synthetic `CGEvent`s** so local input wins.
9. **TURN is mandatory over the open internet** (STUN can't do symmetric NAT) — deploy it or scope v1 to STUN+LAN and say so.
10. **Coordination-plane loss:** media must survive `GroupSession` invalidation and re-signal; late-joiners get no messenger backlog (resync on join).
11. **iOS can't be remote-controlled — ever;** iOS shares full-screen only; **broadcast extension ≤ ~50 MB** (empirical, undocumented — budget conservatively; encode in-extension, hand encoded buffers to the host via App Group; extension can't join SharePlay).
12. **Codec conflict:** hardware HEVC/H.264 = low CPU, weaker text; VP9/AV1 = best text, software+CPU. Don't reuse Multi.app's VP9 QP numbers on HEVC. Set `contentHint = .detail`.
13. **Capture edge cases:** ScreenCaptureKit audio is **app-level not per-window**; **DRM/HDCP windows capture as black frames**; **minimize must be handled as unshare**; off-Space windows stop delivering frames = **pause, not disconnect**.
14. **macOS 15 recurring screen-recording prompt** can't be disabled without the gated entitlement — design onboarding around it.
15. **`NSPasteboard` needs polling; Bonjour needs the Local Network prompt (silently deniable) + plist keys; QUIC needs TLS 1.3 certs.**
16. **Low-latency `VTCompressionSession` needs an explicit `AverageBitRate`** — not `ConstantBitRate` (incompatible with low-latency H.264).
17. **Can't test the networked product in one simulator** — real multi-device, multi-Apple-ID testing is mandatory (human run-book); keep non-networked seams unit-testable.

---

## §9. Definition of done (two tiers — the agent owns the machine tier; the hardware tier is a human run-book)

**Machine sub-gate (you must reach all of this):**
- The whole graph **builds**; non-networked package targets are **`swift build`/`swift test`-clean**; capture→encode→decode→render is proven **single-device**; wire-protocol, session logic, and input mapping have unit tests.
- Architecture is complete: SharePlay used *only* for coordination/signaling/presence/voice-bootstrap; **all media over the custom transport**; the §3.2 topology (relay for F7), channel matrix, budgets, and §3.5 input-security are implemented (not stubbed).
- The Mac app is configured as a **notarized Developer-ID** target with a permission-onboarding flow; the iOS app has a **working broadcast extension** wired to the App-Group transport bridge.
- `DECISIONS.md`, `RISKS.md`, `TESTING.md`, `docs/architecture.md`, and a `README` (build/run/test commands, Xcode floor, signing placeholder) are current.
- **No feature claims coverage it lacks** (secure fields, iOS-as-target, mesh scaling, internet persistence without TURN/server) — limitations are surfaced in-product and documented.

**Hardware sub-gate (recorded PENDING in `TESTING.md` as a run-book; do NOT fabricate results):**
- All **F1–F14** meet their §4 acceptance criteria on real hardware (2 Macs + 1 iPad minimum), F14 in adapted Apple-native form, F7 exercised **at the claimed upper bound through the relay**.
- **Latency metric (define once, reference everywhere):** *glass-to-glass* = capture-timestamp → on-screen-render, measured via an injected timecode diff (or a second-camera frame-counter); **target ≤~150 ms on a quiet LAN** for screen video, and the terminal visibly snappier than screen share; record method + numbers in `TESTING.md`.

---

## §10. First actions for the implementing session

1. Confirm current API availability by fetching the live Apple docs for: GroupActivities (`GroupSession`, `GroupSessionMessenger`, `GroupActivity.prepareForActivation()` **and its exact result type/cases — confirm, don't assume**, `GroupActivitySharingController`, `GroupSessionJournal`), ScreenCaptureKit (`SCStream`, `SCContentFilter`, `SCContentSharingPicker`), VideoToolbox low-latency encoding (`EnableLowLatencyRateControl` + `AverageBitRate`), ReplayKit broadcast extensions, and Network.framework peer-to-peer. Reconcile version annotations with your deployment targets, **and also diff against macOS 26 / iOS 26 release notes** (the recommended targets are older than the shipping OS — check for e.g. new SwiftUI group-activity modifiers and any TCC/ScreenCaptureKit changes).
2. Confirm WebRTC as the default transport, keep the `MediaTransport` seam for the LAN QUIC path (do **not** build both in parallel — §3.2), and record it in `DECISIONS.md`.
3. Scaffold the workspace/package graph (§3.6, §5) with pinned dep versions, both app targets + the iOS broadcast extension + Mac Developer-ID signing (with the `TEAM_ID` placeholder strategy), the Group Activities capability, and the green `swift build`/`swift test` machine gate.
4. Execute **Phase 0** spikes — including the integration spike (e) and scaling micro-spike (f) — and report measured results (or the machine-gate + pending run-book) before writing Phase 1 code.

> Remember: the product's soul is the **shared desktop feeling** — real native windows you can arrange and drive, not a meeting grid. Optimize latency and the window-recreation UX above everything else.
