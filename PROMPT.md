# JoeScreen — build a CoScreen replica for Mac + iOS on Apple's SharePlay stack

ultracode

## 0. Mission

Build **JoeScreen**, a native Swift app for **macOS and iOS only** that fully replicates the core experience of CoScreen (coscreen.co — Datadog's multi-user collaborative screen sharing tool, EOL July 31 2026): a **joint team desktop** where every participant can share individual app windows simultaneously, everyone sees everyone's shared windows as real native windows on their own desktop, and everyone can click, type, draw, and copy/paste into any shared window at the same time — no presenter handoff, no "can you drive?" permission dances.

Session management, presence, invitations, and the control plane run on **Apple's Group Activities (SharePlay) framework**. Voice/video chat comes free from FaceTime when the session runs over a call. Real-time window video runs on a custom peer-to-peer plane (ScreenCaptureKit → VideoToolbox → QUIC), because SharePlay cannot carry video — see §2.

Work in this repo from scratch. There is no existing code. You have full autonomy: scaffold, build, test, and verify milestone by milestone (§6). Use plan → implement → adversarial-review workflows for each milestone. Do not stop at the first working version of a milestone; meet its acceptance criteria and verify before moving on.

## 1. What CoScreen was — the experience you are replicating

The six differentiators from CoScreen's marketing (your feature north star):

| # | Feature | User journey |
|---|---------|--------------|
| 1 | Single-user screen sharing | Alice shares her VS Code window (or any app window) with Bob. |
| 2 | **Multi-user screen sharing** | Alice shares VS Code; *at the same time* Bob shares his Terminal; both see both windows side-by-side. |
| 3 | Single-user remote control | Alice and Bob can both interact with Alice's window using mouse & keyboard without taking each other's window focus away. |
| 4 | **Multi-user remote control** | Alice and Bob can interact with Alice's window *and* with Bob's window. |
| 5 | **Cross-user copy & paste** | Alice copies text from her window and pastes it into Bob's window, and vice versa. |
| 6 | **Mob collaboration (>2 users)** | Chris, Dennis, and Eve join Alice and Bob and collaborate, share, and contribute just like they do. |

The signature UX mechanics (verified from CoScreen's docs, blog, and HN threads — replicate these, they are the product):

- **Hover "Share" tab**: after joining a session, hovering over any of your OS windows shows a small tab attached above the window; one click shares it, click again to unshare. Nothing is shared by default when you join. A "Share windows" dialog also allows multi-select and whole-display sharing (display sharing auto-shares windows dragged onto that display).
- **Remote windows are real native windows** (the core magic): each shared window appears on every other participant's desktop as an individual, movable, resizable native window filled with that window's live video — *not* one big screen-share tile. Recipients arrange remote windows freely; resizing is local scaling only. A **"Bring to front"** button raises all shared windows above local clutter.
- **Participant color coding**: each participant gets a color; every shared window is outlined with its sharer's color on both sides (so sharers also always see which of their own windows are live).
- **Multi-cursor**: every participant's mouse pointer is rendered over shared windows in real time (CoScreen v5 did 60 fps cursors), translated into the window's coordinate space.
- **Watch / Control / Draw modes per remote window**: a tab on each remote window switches between passively watching, controlling (clicks + keyboard are injected on the owner's machine), and drawing (ink annotations over the window). A one-click **write-access toggle** lets a user disable their own input to avoid accidental typing into teammates' windows; sharers can disable remote control of their windows.
- **Sessions are persistent rooms** joined via link, with a recent-rooms list; joining shares nothing by default.
- **Built-in, deliberately subtle voice/video chat** — thumbnail camera bubbles that stay out of the way, never a wall of faces.
- **Shared collaborative terminal** (CoScreen's "CoTerm"): a terminal streamed as PTY text data instead of video (~80% lower latency), which every participant can view, type into, and annotate.

Known CoScreen weaknesses to avoid repeating: high CPU/latency before their Rust rewrite (use hardware encode from day one — they never shipped it); accidental typing into remote windows (their fix: explicit Control mode + write toggle — keep it); minimizing a shared window silently unshared it (make unshare explicit and visible).

## 2. Non-negotiable architecture

### 2.1 SharePlay is the control plane — never the video plane

Group Activities is a session-coordination and small-data-sync framework, **not a media transport**. These are hard platform facts, verified against Apple docs and WWDC sessions — treat them as ground truth and do not rediscover them:

- `GroupSessionMessenger` messages are capped at **256 KB** and rate-limited (bursts make `send()` throw; no numeric rate is documented). Apple explicitly says it "should not be used for streaming large assets like files, images, or videos."
- `GroupSessionJournal` (iOS 17+/macOS 14+) transfers attachments up to 100 MB with late-joiner catch-up — file sync, not streaming.
- There is **no API** to stream arbitrary real-time video/audio through SharePlay, no access to FaceTime's AV streams, and no programmatic access to FaceTime's system screen sharing.
- Participants are opaque UUIDs — no names, no network addresses. Max 33 participants per session.

So JoeScreen uses SharePlay for exactly what it is good at:

1. **Grouping & invitation**: define a `JoeScreenActivity: GroupActivity` (Codable, `activityIdentifier`, metadata with `.generic` type). Start via FaceTime call (`activate()`), Messages, or the share sheet / `GroupActivitySharingController` (NSViewController variant on macOS 13+). Gate custom start buttons on `GroupStateObserver.isEligibleForGroupSession`.
2. **Presence & roster**: `session.activeParticipants` drives the participant list and color assignment (deterministic order: sort participant UUIDs, assign palette indices).
3. **Voice/video chat**: when the session runs over a FaceTime call, FaceTime *is* the A/V chat — build none of it. If the session started from Messages (no call), show a "voice is off — escalate to FaceTime" hint. Do not build custom voice in v1.
4. **Control-plane state sync** over `GroupSessionMessenger`: who is sharing which windows (window IDs, titles, sizes), share/unshare events, write-access toggles, remote-control permission state, participant colors — small Codable messages, `.reliable` mode.
5. **Signaling for the video plane**: participants exchange transport bootstrap info (addresses, ports, QUIC certificate fingerprints) over the messenger. SharePlay's channel is end-to-end encrypted, which makes this an *authenticated* key exchange: pin the exchanged certificate fingerprints when establishing QUIC connections.
6. **Input, cursor, clipboard, and drawing events**: these are small and fit the messenger — but they are latency-sensitive and the messenger's rate limits are undocumented. Architect them behind the same event-channel abstraction as video (§2.3) so they ride QUIC when a direct connection exists, with the messenger as fallback. Use `.unreliable` delivery (macOS 13+/iOS 16+) for cursor positions, `.reliable` for input/clipboard.

### 2.2 The video plane: ScreenCaptureKit → VideoToolbox → QUIC

- **Capture (macOS)**: one `SCStream` per shared window with `SCContentFilter(desktopIndependentWindow:)` (macOS 12.3+; captures just that window wherever it lives, even moved across displays/Spaces — this gives you CoScreen v5's "windows keep streaming across displays" behavior for free). Multiple simultaneous SCStreams are supported and cheap on Apple Silicon (~2% of a core each). Configure `minimumFrameInterval` for 30–60 fps, `showsCursor = false` (cursors are rendered as overlays, not baked into video), `queueDepth` ~5. For whole-display sharing use a display filter. Screen Recording TCC permission required (`CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`); macOS 15 re-prompts roughly monthly — handle re-denial gracefully.
- **Encode**: `VTCompressionSession` with `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` (one-in-one-out, no B-frames, infinite GOP; H.264 everywhere, HEVC available on Apple Silicon). Realtime + ExpectedFrameRate properties; request keyframes on demand for late joiners and loss recovery. Do NOT combine low-latency mode with ConstantBitRate (H.264 restriction). Target adaptive bitrate ~2–10 Mbps per window scaled by resolution; text legibility beats smoothness — prefer resolution over frame rate under constraint (CoScreen/Multi learned this the hard way).
- **Transport**: `Network.framework` QUIC (`NWProtocolQUIC`), one connection per peer pair: reliable QUIC streams for control/input/clipboard, **QUIC datagrams** (iOS 16+/macOS 13+) for video frames (fragment + sequence encoded frames; drop stale, request keyframe on gap). QUIC requires TLS 1.3 with real certificates — generate a self-signed cert per device with `swift-certificates`, exchange fingerprints over SharePlay (§2.1.5), and pin them in `sec_protocol_options` verify blocks. Connection strategy, in order: (a) direct on LAN via Bonjour (`NWListener`/`NWBrowser`, service `_joescreen._udp`; add a short retry delay after discovery — immediate connect is flaky), (b) direct via addresses exchanged over signaling (attempt UDP/QUIC simultaneous open for NAT traversal), (c) relay: include a tiny Swift executable (`joescreen-relay`, a dumb QUIC datagram/stream forwarder) in the repo that anyone can run on a VPS; the app accepts a relay URL in settings. Set `includePeerToPeer = true` only when no LAN/internet path exists (AWDL hurts latency — hundreds of ms; prefer infrastructure Wi-Fi). Declare `NSLocalNetworkUsageDescription` + `NSBonjourServices` on iOS or connections silently fail.
- **Decode/render**: feed compressed samples to `AVSampleBufferDisplayLayer` (it decodes internally; set `kCMSampleAttachmentKey_DisplayImmediately` for zero-delay display). On the Mac, each remote shared window is a real `NSWindow` (titled, resizable, closable) whose content view hosts the layer plus overlays (cursors, borders, ink). On iOS, remote windows render in zoomable views (§3 F9).
- **Latency budget**: glass-to-glass ≤ 150 ms on LAN, ≤ 350 ms over internet relay. Measure it (embed capture timestamps in frame headers; log p50/p95).

### 2.3 The remote-control plane

- **Injection (macOS is the only controllable platform)**: synthesize `CGEvent`s from remote input. Requires the **Accessibility** TCC permission (`AXIsProcessTrusted`), which is **impossible in a sandboxed app** — see §2.5. Tag every synthetic event via `.eventSourceUserData` (or a custom event source) so the local input pipeline can distinguish remote from local input and local input wins fights. Approach: map remote coordinates (normalized per shared window) to current window frame; for clicks/typing, raise + focus the target window on the *owner's* machine (use AX APIs / `NSRunningApplication.activate` as needed), post events at the HID tap. `CGEvent.postToPid` without focusing is unreliable per-app — treat no-focus-steal injection as a stretch refinement, not the MVP. The CoScreen guarantee you MUST keep: the *controller's* machine never loses focus while typing into a remote window view, and two remote participants interacting with two different shared windows don't fight each other's focus (input router serializes per-target-window, and only raises when the target differs from the currently focused window).
- **Keyboard**: transmit layout-independent key events (keycode + modifiers + character payload); replay modifiers as flag-change events. Modifier correctness is the known-hard part — build a keyboard-event round-trip unit test suite early.
- **Secure input**: password fields (`EnableSecureEventInput`) silently swallow synthetic keystrokes — detect (`IsSecureEventInputEnabled`) and surface a "secure input active — remote typing blocked" badge instead of failing mysteriously.
- **Write-access model**: per-participant global write toggle (one click, like CoScreen) + per-shared-window "allow remote control" toggle on the sharer side. Default: control enabled, Watch mode selected — the first click into a remote window switches to Control with a subtle affordance.
- **Cross-user clipboard**: when a controller issues ⌘C/⌘X into a controlled window, the owner's app watches `NSPasteboard.general.changeCount` (poll ~300 ms — there is no notification API) and ships new *text* content (cap 256 KB, v1 is text-only) back over the reliable channel to the controller's pasteboard, and vice versa on ⌘V. iOS uses `UIPasteboard`. Make sync directional and event-scoped (only around control interactions) — do not build a promiscuous always-on clipboard mirror.

### 2.4 Platform asymmetry — design the product around it honestly

| Capability | macOS | iOS/iPadOS |
|---|---|---|
| Share individual windows out | ✅ ScreenCaptureKit per-window | ❌ impossible (no window concept exposed; ReplayKit is full-screen only) |
| Share full screen out | ✅ | ✅ ReplayKit broadcast upload extension |
| View others' shared windows | ✅ native NSWindows | ✅ zoomable remote-window views |
| Control others' shared windows | ✅ (sends input) | ✅ (touch → pointer/keyboard events) |
| **Be controlled** by others | ✅ CGEvent injection | ❌ **platform-impossible** — iOS has no input-injection API (DTS-confirmed). Do not attempt. |
| Voice via FaceTime+SharePlay | ✅ | ✅ |

iOS specifics: the broadcast upload extension has a hard **~50 MB memory ceiling** — downscale to ≤720p and hardware-encode each frame immediately inside the extension; never queue pixel buffers. The extension cannot join a GroupSession (the `com.apple.developer.group-session` entitlement applies to app targets only) — the host app does signaling; the extension gets transport bootstrap via App Group `UserDefaults` and sends video directly over its own QUIC connection. `RPSystemBroadcastPickerView` is the only sanctioned way to start a broadcast (the programmatic subview-tap hack is fragile — don't rely on it); broadcasting pauses when the device locks. iOS shared screens are view-only for other participants (no remote control back into iOS) — label them accordingly in the UI.

### 2.5 Distribution & entitlements

- The Mac app **cannot be sandboxed**: Accessibility (input injection) is unavailable to sandboxed apps, period. Ship it **Developer ID signed + notarized**, outside the Mac App Store. Disable App Sandbox in the target.
- Group Activities requires the `com.apple.developer.group-session` entitlement (enable the Xcode "Group Activities" capability) on the Mac and iOS *app* targets. It needs a real signing team; scaffold entitlements files and document signing setup in the README rather than blocking on it.
- macOS permissions to request and gracefully re-request: Screen & System Audio Recording (capture), Accessibility (injection). Build a first-run permissions checklist screen that deep-links to the right System Settings panes and live-updates as permissions land.
- iOS: Group Activities capability, App Group (app ↔ broadcast extension), `NSLocalNetworkUsageDescription`, `NSBonjourServices`.
- Deployment targets: **macOS 15, iOS 18** (everything above is available; no availability gymnastics).

## 3. Feature spec with acceptance criteria

Build features in milestone order (§6). Each feature is DONE only when its acceptance criteria pass.

**F1 — Session lifecycle (SharePlay).** Create/join a JoeScreen session from the app UI via FaceTime call or share sheet; roster with names-if-known (fall back to "Participant N" + color), join/leave events, session end. *Accept:* two devices on a FaceTime call join the same session; roster updates within 2 s of join/leave; app relaunches cleanly mid-session (rejoin from the FaceTime SharePlay affordance works).

**F2 — Single-window sharing.** Hover "Share" tab over the user's own windows (floating overlay panel tracking window frames via SCShareableContent polling + CGWindowList; skip other apps' overlay-level windows) plus a "Share windows…" dialog with live thumbnails (SCScreenshotManager) and whole-display option. *Accept:* clicking the tab starts the stream in <1 s; tab reflects shared state with the participant color; unshare is one click; nothing shared on join by default.

**F3 — Remote native windows.** Every shared window appears as a movable/resizable native window on all other Macs, video-filled, title = "\<window title\> — \<participant\>", colored border, "Bring to front" command raising all remote windows. *Accept:* two-instance loopback demo (§7) shows a shared window rendering ≥30 fps at native aspect; resize rescales locally without renegotiating; sharer-side border shows own shared windows.

**F4 — Multi-user simultaneous sharing.** N participants × M windows each, all live at once. *Accept:* 3 participants each share 2 windows; all 6 render simultaneously on every other participant's desktop; per-stream teardown works independently; CPU stays sane (measure and report).

**F5 — Remote control.** Watch/Control/Draw mode tab on each remote window; input injection per §2.3; write-access toggles; multi-user: two participants control two different windows of a third participant concurrently without focus fights. *Accept:* loopback demo — click a button and type a sentence into a remote TextEdit window with correct modifiers (test: shifted chars, ⌘-shortcuts, arrows); owner sees input applied; controller's local focus never leaves their machine; write toggle instantly blocks own input; sharer's "disallow control" blocks everyone's.

**F6 — Multi-cursor presence.** All participants' pointers render over shared windows (owner side *and* every viewer side) with participant color + name label, ≥30 Hz, via transparent click-through overlay windows (`ignoresMouseEvents`, `.statusBar` level, `.canJoinAllSpaces`). *Accept:* cursors visibly track with no perceptible stutter in loopback; disappear when a pointer leaves the shared window.

**F7 — Cross-user copy & paste.** Per §2