# CoScreen Parity Plan — JoeScreen macOS

**Status:** approved plan, ready for implementation · **Authored:** 2026-07-10
**Execution:** by a Claude Code session per `docs/COSCREEN_PARITY_PROMPT.md` (Opus 4.8 + ultracode)
**Provenance:** produced by a 6-agent codebase-mapping pass, a live crawl of coscreen.co
(5 pages), and a 4-architect design panel, all verified against the repo at commit `aee502b`.

CoScreen (Datadog) is EOL **2026-07-31**. JoeScreen's goal is to be the replacement its users
reach for. This plan takes the app from "single-window sharing works" to CoScreen's core
experience: **everyone's webcam in tiles in the main window, share a window or the whole screen,
every remote share a freely movable native window** — then the wider use-case backlog
(remote control, clipboard, rooms/links, browser join, draw, terminal).

---

## 1. Where the app stands today (verified against source)

**Works end-to-end (Direct Session Mode, LiveKit SFU):**
- Per-window sharing: `SCContentSharingPicker` (single-window mode) → `WindowCaptureService`
  (ScreenCaptureKit, 420v, 30fps, Retina-native) → LiveKit buffer track named `window:<uuid>` →
  each remote share opens as **its own movable NSWindow** (`RemoteWindowManager` /
  `RemoteVideoWindow`, owner-color border, `SwiftUIVideoView`). Multiple simultaneous local
  shares supported (`localCaptures: [WindowID: WindowCaptureService]`).
- Voice (LiveKit `setMicrophone`), camera **self**-preview + device pickers (`MediaControlBar`),
  multi-cursor presence over remote windows (~60fps, click-through overlays, participant colors),
  pause/unshare semantics (off-Space = pause, minimize = unshare), roster, join via launch args /
  `joescreen://` deep link / join sheet.
- Machine gate: `swift build` + `swift test` green — 120 tests, 7 skipped offline
  (LiveKit-gated + TCC-gated), 0 failures, re-verified 2026-07-10 at `aee502b`. The LiveKit
  integration suite (now 7 gated tests) passed with `LIVEKIT_URL` per TESTING.md's 2026-07-07
  record; re-run it against a live SFU before relying on it.

**The three asks, precisely:**
| Ask | Current state |
|---|---|
| Webcam tiles for everyone | **Missing.** Remote `.camera` tracks are subscribed then silently dropped — `AppModel`'s `onTrackSubscribed` hook keeps only names parsing as `window:<uuid>`. Only local self-preview exists. |
| Share window **or whole screen** | **Missing.** Only `SCContentFilter(desktopIndependentWindow:)` exists; picker is `[.singleWindow]`; `wholeDisplay` is a bool that is always `false`. |
| Movable per-window shares | **Built and working** — but with correctness bugs that make it feel broken in real sessions (dead windows on sharer crash, fixed 800×500 size, cursor drift, wrong owner attribution; see M9). |

**Load-bearing latent bugs found during mapping (fix, don't rediscover):**
1. `LiveKitTransport.remoteVideoTracks` is keyed by track **name**; LiveKit names every camera
   track `"camera"`, so two remote webcams overwrite each other. Re-key by track **SID**.
2. No unsubscribe path reaches the app: `handleTrackUnsubscribed` clears a dict and tells nobody.
   A sharer that crashes leaves a frozen NSWindow forever.
3. Codec-context ordering: `AppModel.startSharing` calls `publishVideoTrack` (which snapshots
   publish options) **before** `updateShareContext` — the D5 multi-window→H.264 rule never
   applies to the track being published.
4. `AdmissionController` and `CodecSelector.evaluate()` are dead code at runtime (tested,
   never called). `AdmissionController.maxEncodeSessions` defaults to 1 and would refuse the
   already-working second share if wired naively.
5. Owner attribution: if a track subscribes before the first `RoomSnapshot`, `ownerID` falls
   back to the windowID and is never repaired (wrong border color/title forever).

---

## 2. Hard constraints (violating any of these is a defect)

- **R22 one-libwebrtc:** `JoeScreenLiveKit` is the only **package library target** that links
  LiveKit; `JoeScreenKit` stays LiveKit-free and CoreMedia-free; never introduce a dependency
  that links a second libwebrtc; capture → kit → app dependency direction preserved.
  App targets **may** import LiveKit for rendering-layer types (`SwiftUIVideoView`,
  `RemoteVideoTrackRef`) — `AppModel`/`RemoteVideoWindow`/`MediaControlBar` already do.
  (A stale comment in `LiveKitTransport.swift:6-8` claims the transport is "the ONLY
  libwebrtc-linking type in the process" — the imports above contradict it; don't let a
  pre-flight pass trip on that comment.)
- **Swift 6 strict concurrency** in JoeScreenKit; `AppModel` is `@MainActor @Observable`;
  transport is an actor. Hooks are `@Sendable`, hop to main via `Task { @MainActor in }`.
- **Track-name contract:** window shares `window:<WindowID uuid>` (source `.screenShareVideo`),
  cameras LiveKit-default naming (source `.camera`). **Extend, never break** — new prefixes
  (e.g. `display:`) are additive; old receivers must degrade gracefully (parse nil → ignore).
- **R24:** `RoomOptions(adaptiveStream: true, dynacast: true)` is load-bearing correctness.
  Never disable. Never call `RemoteTrackPublication.set(enabled:)` — it **throws
  `.invalidState` while adaptiveStream is on** (verified in SDK source); use
  `set(subscribed:)` for hard unsubscribe and renderer attach/detach for soft.
- **R32:** every attached video renderer must report `isAdaptiveStreamEnabled == true` and a
  non-zero `adaptiveStreamSize`, or it silently receives no frames. `SwiftUIVideoView`
  complies by construction — prefer it; any custom renderer must implement this.
- **D5 codec:** VP9 only for a single-window Mac share; ≥2 windows or any display share ⇒
  H.264 for **all** share tracks. `degradationPreference .maintainResolution`, simulcast **off**
  for share tracks. (Camera tracks are exempt: keep the SDK default **simulcast on** so
  adaptive-stream can downshift tiles cheaply.)
- **Media invariants:** pixel format 420v mandatory (silently dropped otherwise);
  frame-before-publish handshake mandatory; timestamps 0 (SDK clock).
- **D12 input security:** owner-Mac enforcement at injection time against trusted local state;
  capability tokens; Watch is the default mode. Coordination-plane flags are display-only.
- **Wire protocol:** new message kinds are appended (never renumber; tags 1–10 reserved);
  new Codable fields are optional + `decodeIfPresent` (old peers must keep decoding).
  `RoomModel.revision` must never be bumped receiver-locally (breaks last-writer-wins).
- **TESTING.md discipline:** every feature = pure-logic seam in JoeScreenKit with Tier-1 unit
  tests + a green machine gate (`swift build && swift test` from `apps/joescreen/`) + PENDING
  Tier-2 hardware rows. **Never claim hardware-verified** — anything not run on hardware is
  written as PENDING with the exact expected outcome.
- **Pinned deps (D7):** livekit client-sdk-swift 2.15.1, bump-only policy. No new deps without
  a decision entry (SwiftTerm 1.13.0 is pre-pinned but commented for M-terminal).

---

## 3. Milestones

Sequencing rationale: M9 first because it fixes correctness bugs the other milestones would
otherwise inherit and lands the shared contracts (`RemoteTrackDescriptor`, `ShareInfo`,
`ShareTrackName`) that M10/M11 build on. Each milestone compiles and keeps the machine gate
green at every ordered step.

### M9 — Receive-side lifecycle correctness + share metadata (effort L)

Makes "movable window shares" production-grade and lands the shared plumbing.

**New pure seams (JoeScreenKit, Tier-1 tested):**
- `RemoteWindowLifecycle` — per-window reducer `reduce(state, event) → (state, [Effect])`.
  States: `subscribing / open / closedByUser / hidden(miniaturized|occluded) / stale(grace) /
  gone`. Events: `trackSubscribed / trackGone(reason) / userClosed / userReopened /
  miniaturized(Bool) / occluded(Bool) / shareRemovedFromSnapshot / ownerDisconnected /
  transportReconnecting / graceExpired`. Effects: `openWindow / closeWindow / unsubscribe /
  resubscribe / pauseRendering / resumeRendering / purge`. Every dead-window/desync bug class
  becomes an enumerable unit test; `AppModel` just executes effects.
- `VideoFitMath` — aspect-fit rect + letterbox-aware normalized↔view coordinate mapping with
  clamping (fixes cursor drift; tightens `NormalizedPoint` semantics to "relative to the video
  content rect" with no wire change).
- `WindowCascade` — deterministic per-owner window placement (owner-index anchor + per-window
  cascade, clamped to `visibleFrame`).
- `ResizeStabilizer` — jitter suppression (<4pt) + stable-confirmation for source-resize.
- `ShareInfo: Codable` — `{kind, title?, appName?, sourcePixelWidth?, sourcePixelHeight?}`.
- `ShareTrackName` — `encode/decode` for `window:<uuid>` (byte-identical to today) and the
  future `display:<uuid>`; `ShareKind { window, display }`.

**Wire/model changes (all additive, `decodeIfPresent` back-compat):**
- `RoomModel.shareInfo: [WindowID: ShareInfo]` + `setShareInfo` (revision bump iff changed),
  cascade-cleared on share/participant removal; `ShareEvent.info: ShareInfo?`.
- `RoomModel.pruneParticipant(_:)` — receive-side cleanup that does **not** bump revision.

**Transport (JoeScreenLiveKit — concrete hooks, `MediaTransport` protocol unchanged):**
- Unified subscribe hook: `RemoteTrackDescriptor {trackSID, trackName, sourceKind, ownerID?}`
  (owner from the delegate's participant identity; sourceKind mapped to a framework-free enum).
  Registry re-keyed by **SID** (fixes latent bug #1). Two in-repo call sites updated.
- `trackGone` hook fired from **both** `didUnsubscribeTrack` **and** `didUnpublishTrack`
  (verified: if a track was locally unsubscribed, a later sharer crash fires only
  `didUnpublishTrack` — hooking one alone leaks). Dedupe via a per-generation `reportedGone`
  set; suppress self-inflicted events via a `locallyUnsubscribed` set marked before calling
  `set(subscribed:false)`.
- `setWindowTrackSubscribed(windowID:Bool)` → `RemoteTrackPublication.set(subscribed:)`.
- Dimension observer: small `NSObject` `TrackDelegate` per window track
  (`track(_:didUpdateDimensions:)`, delegates held weakly — transport retains observers),
  seeded from `publication.dimensions` at subscribe.

**Capture (sharer side):**
- `WindowResizeWatcher` (CGWindowList polling at 4 Hz, same pattern as
  `MinimizeUnshareWatcher`) → `ResizeStabilizer` → rebuild `SCStreamConfiguration` →
  `stream.updateConfiguration` (async; available since macOS 12.3) → update `capturedWindowFrame` +
  re-broadcast `ShareInfo` dimensions. Receivers get new dimensions automatically via the
  capturer's dimension propagation.
- Populate `ShareInfo` at `startSharing` from `SCWindow.title` /
  `owningApplication.applicationName`.

**App/UI:**
- `NSWindowDelegate` per remote window: `windowWillClose` → lifecycle `.closedByUser`
  (entry kept, frame remembered, SFU-side `set(subscribed:false)` = zero downlink);
  `SharedWindowTile` gains a state-aware **Reopen / Focus** button; Window menu gets one item
  per share + "Bring All Shared Windows to Front". Reopen routes the **new** `RemoteVideoTrack`
  the SDK delivers into the existing entry (no duplicate windows).
- Sharer crash/disconnect: `trackGone` → close + purge; while `mediaState == .reconnecting`,
  park in `.stale` (frozen frame + "Reconnecting…" badge, 10s grace) so SFU blips don't flap.
  Belt-and-braces: participant-set diff → `pruneParticipant`.
- Aspect-true windows: initial size = source aspect fitted to ~55% of `visibleFrame`
  (fallback 800×500 until first dimensions), `contentAspectRatio` locked, updated on
  dimension changes (debounced, never during `inLiveResize`).
- Cursor mapping through `VideoFitMath` both directions (outbound hover + inbound overlay).
- Owner repair: subscribe-time identity → `room.owner(of:)` → placeholder, then repaired by
  every `applyRoom`; `RemoteVideoWindow` becomes `@Observable` so border/title recolor live.
- Pause badge + "Reconnecting…" overlay on the NSWindow (state already broadcast, ignored today).
- Focus policy: open with `orderFrontRegardless()` (never steals focus); optional
  "Follow new shares" AppStorage toggle for `makeKeyAndOrderFront`; per-window Always-on-Top
  toggle (`window.level = .floating`, session-only).
- Soft visibility tier: miniaturize/full-occlusion (1s debounce) detaches the
  `SwiftUIVideoView` from the hierarchy (placeholder keeps aspect) — adaptive-stream's own
  0.3s timer then tells the SFU to stop forwarding; re-show re-attaches (keyframe ≈0.5s).
  **Do not** use `set(enabled:)` (throws under adaptiveStream; see constraints).

**Tier-1 tests:** lifecycle reducer transition table (every event in every state);
`VideoFitMath` round-trips + clamping incl. letterbox cases; `WindowCascade` determinism +
clamping; `ResizeStabilizer` jitter/confirm; `ShareInfo`/`RoomSnapshot` old↔new decode
matrix; `pruneParticipant` no-revision-bump; `ShareTrackName` window/display/garbage.
**Tier-2 rows (PENDING):** sharer force-quit closes viewer windows ≤2s (no frozen ghosts);
user-close then Reopen restores at remembered frame with live video; source resize keeps
remote aspect within one stabilizer confirmation; two owners × two windows each → per-owner
cascade groups; letterbox cursor alignment (portrait window on landscape viewer) —
pointer tips align on the same pixel feature at both ends.

### M10 — Participant video tile strip (effort M)

The "see everyone" ask. Depends on M9's `RemoteTrackDescriptor` + trackGone hooks.

**Routing:** pure `TrackClassifier.classify(name:sourceKind:) → .windowShare(WindowID) /
.camera / .ignore`. Precedence: parseable share name wins regardless of source; else
`sourceKind == .camera` → `.camera`; else ignore (forward-compatible). `.camera` tracks land
in `cameraTracks: [ParticipantID: RemoteVideoTrackRef]` keyed by owner (identity → UUID rule
as today); `.windowShare` keeps the exact existing path.

**Display names (decision):** LiveKit `participant.name` via a top-level `name` JWT claim —
the SFU distributes it to everyone including late joiners, needs no `canUpdateOwnMetadata`
grant and zero wire-protocol surface. Rejected: participant metadata (more plumbing, same
result), state-channel profile message (non-sharers never broadcast today; late-join needs new
machinery). Plumbing: `DirectJoinParameters.displayName?` ← `--name` arg + `joescreen://…&name=`
+ a "Your name" JoinSheet field defaulting to `NSFullUserName()`; DEBUG `DevTokenMinter.mint(…,
name:)`; `TokenClient` passes `&name=`; `apps/livekit/token-server/main.go` calls `.SetName`.
Fallback everywhere: existing 4-char UUID label. `RosterView` uses the same helper.

**Participant media state:** framework-free `ParticipantMediaState {displayName?, isSpeaking,
micLive, cameraOn}` computed inside the transport actor from delegate events
(`didUpdateSpeakingParticipants`, publication `didUpdateIsMuted`, `didUpdateName`,
connect/disconnect, publish changes) and pushed via one hook. **Semantic trap (verified):**
`setCamera(false)`/`setMicrophone(false)` **mute** rather than unpublish — camera-off/mic-off
detection must read `publication.isMuted`, never track un/subscription (a muted camera track
stays subscribed → frozen frame otherwise). Late joiners derive initial state from
`room.remoteParticipants` at hook install and on `.connected`.

**UI:** `ParticipantTileStrip` — horizontal `ScrollView` + `LazyHStack` of ~176×110 (16:10)
tiles between the connection banner and the roster/shares split. Self tile first (mirrored;
absorbs `SelfPreviewTile` from SharesPane), then remotes ordered by a pure
`TileSubscriptionPlanner` (displayName-lowercased, UUID tiebreak — tiles never jump on churn).
Tile = `SwiftUIVideoView` when a renderable camera track exists, else avatar (participant-color
circle + initials); 3pt color ring; name caption; red `mic.slash` badge when `!micLive`;
green speaking ring on `isSpeaking` (update smoothing/cadence comes from the SFU's speaker
detection, not the client SDK — fine with our self-hosted defaults; add a debounce only if
the ring flickers in Tier-2).
**Share thumbnails + focus:** `SharedWindowTile` upgrades from placeholder to a live
mini-thumbnail by attaching a **second** `SwiftUIVideoView` to the already-held remote track
(one decode, two renderers; adaptive stream reports the max renderer size so the big window
keeps its quality; R32 satisfied by construction). Tap thumbnail → `RemoteWindowManager.focus`;
tap participant tile → raise all that owner's share windows.

**Subscription economics:** camera tracks keep SDK-default **simulcast on** (D5's
simulcast-off rule governs share tracks only) — 8 remote cameras ≈ 8 thumbnail-layer decodes.
Off-screen tiles: `LazyHStack` detaches views → zero renderers → adaptive stream stops SFU
forwarding automatically. Hard cap: wire `AdmissionController.canDecodeAnotherWindow`-style
budget — cameras beyond the cap (default 6 decoded windows total, shares take priority) park
as avatar tiles with a "camera parked" affordance until budget frees.

**Tier-1 tests:** `TrackClassifier` matrix (window name + camera source, display name,
garbage, camera-source-with-share-name precedence); tile ordering determinism; media-state
reduction from event sequences (mute→unmute, late-join seeding); SID-keyed registry
(two `"camera"`-named tracks coexist); name-claim JWT encode (DevTokenMinter) round-trip.
**Tier-2 rows (PENDING):** 3 Macs, all cameras on — each sees the other two live tiles with
correct names ≤2s after join; mute mic on A → badge on B/C ≤1s; camera off → avatar (not
frozen frame); speaking ring tracks actual speech ≈300ms; 8-participant decode-budget parking.

### M11 — Share the whole screen (display share) (effort L)

**Picker:** `SCContentSharingPicker` stays the single production entry (R4 exemption — no
recurring macOS-15 re-approval; R5 independence). `allowedPickerModes = [.singleWindow,
.singleDisplay]`; completion becomes `enum SharePick { window(CGWindowID), display(CGDirectDisplayID) }`.
**macOS-14 floor fix (verified):** `filter.includedWindows/includedDisplays` are **15.2+**;
classify with `filter.style`, then on 14.0–15.1 resolve displays by matching `filter.contentRect`
against `SCShareableContent.displays[].frame` (pure `DisplayPickResolver`; display frames are
unique in global space), windows best-effort by frame match with a "please retry" notice on
ambiguity. Picker also sets `excludedWindowIDs` = JoeScreen's own windows. Debug bypass
`--share-display-id` / `--share-main-display` mirrors `--share-window-id`.

**Capture:** new `DisplayCaptureService` actor (sibling of `WindowCaptureService`, shared
`CaptureStreamBridge` extracted for the SCStream delegate/output plumbing; both conform to
`ShareCaptureService` so `AppModel` holds `[WindowID: any ShareCaptureService]`).
Filter: `SCContentFilter(display:excludingApplications:[ownApp]exceptingWindows:[])` —
excludes **all** JoeScreen windows including future remote-share viewers = the
hall-of-mirrors fix. Resolution: pure `DisplayResolutionPolicy` — source pixels =
`SCDisplay.width/height` (points) × `pointPixelScale`; cap at a 4.096 Mpx budget
(≈2560×1600; a 5K display captures at ≈2389×1344), snap even, never upscale. 420v, 30fps,
queueDepth 5. `showsCursor = true` for displays (deviation from the window path — the overlay
plane never carries the sharer's own pointer; decided in §5). Lifecycle: display
removal (1 Hz `CGGetActiveDisplayList` poll) = terminal unshare; screen lock
(`DistributedNotificationCenter` screenIsLocked/Unlocked) = pause (SCK keeps delivering
lock-screen frames, so `PauseDetector` alone would never fire); display-resolution change →
`stream.updateConfiguration`.

**Naming/receive:** `display:<uuid>` via `ShareTrackName` (same minted `WindowID` identity —
RoomModel/cursors/state channel untouched by construction). Display shares open as **another
movable aspect-locked NSWindow** (CoScreen model), initial ≈60% of receiver screen width.
Old receivers parse nil and ignore gracefully.

**Codec (fixes latent bug #3, implements D5 structurally):**
1. `ShareContext` reducer computes `(windowCount, wholeDisplay)` **including the pending
   share**; `AppModel` calls `updateShareContext` **before** `publishVideoTrack`.
2. `LiveKitTransport` defers building `VideoPublishOptions` until `completePublish`
   (after first frame) so options reflect actual publish-time context.
3. **Structural renegotiation:** `PublishedTrack` records its codec; a context change that
   flips the structural codec (e.g. VP9 window track live when a display share joins ⇒ all
   H.264) unpublishes and republishes the same `LocalVideoTrack`/name/sink. Receiver sees
   unsubscribe+resubscribe of the same name ⇒ `RemoteWindowManager.openOrReplace` swaps the
   track in the existing window (~1s freeze, no flicker).

**Admission (revives dead code #4):** pure `ShareBitratePolicy` —
`clamp(pixelArea × 30 × 0.04 bits, 1, 8 Mbps)` (1080p window ≈2.5 Mbps, capped 5K ≈3.9 Mbps).
`AdmissionController` gains one heterogeneous overload `admitShare(existingBitrates:requested:…)`
(uniform-scale degrade, floor, refuse) — old signature delegates to it, all existing tests
hold. Call-site config `maxEncodeSessions: 3` with an explicit reconciliation comment (type
default stays 1 pending Phase-0(f) hardware measurement); uplink constant 20 Mbps labeled
ASSUMED until measurement exists. Admitted bitrate becomes real via
`VideoPublishOptions.screenShareEncoding = VideoEncoding(maxBitrate:maxFps:30)` (verified the
2.15.1 SDK applies `screenShareEncoding` to `.screenShareVideo` tracks). Refusal = visible
alert, no publish, no dangling capture.

**Sharer affordance:** no PiP in v1. `ShareBorderOverlay` — borderless click-through NSWindow
at `.statusBar` level drawing a 3pt border around the shared display (invisible to receivers
because our app is excluded from the filter) + a "Sharing Display" chip with stop button in
the control bar.

**Tier-1 tests:** `DisplayResolutionPolicy` (5K/1080p/even-snap/never-upscale);
`DisplayPickResolver` frame matching; `ShareContext` including-pending math;
`ShareBitratePolicy` clamps; admission overload (degrade/floor/refuse + legacy delegation);
`ShareTrackName` display round-trip; renegotiation decision table (which live tracks flip).
**Tier-2 rows (PENDING):** share a 5K display → receiver window ≈2389×1344 aspect-true and
readable; window+display simultaneous from one Mac → both H.264 (webrtc-internals/stats),
existing window track renegotiates with ~1s freeze and no window flicker; JoeScreen's own
windows absent from the shared display (hall-of-mirrors); screen lock pauses (badge) and
unlock resumes ≤2s; display unplug unshares ≤2s; R27 observation row — DRM window inside the
display renders as black region (document, no detector in v1); macOS 14.x picker resolution
tier exercised if hardware available.

### Milestone ordering & shared contracts

M9 → M10 → M11. Contracts introduced in M9 and consumed later: `RemoteTrackDescriptor`
(M10 classification), `trackGone` (M10 camera pruning), `ShareInfo` (M11 display naming/titles),
`ShareTrackName` (M11 `display:` prefix), lifecycle reducer (M11 `openOrReplace` path).
Where the design panel's individual proposals differed on hook shape, the **superset**
`RemoteTrackDescriptor {trackSID, trackName, sourceKind, ownerID?}` is the single contract.

---

## 4. Post-core backlog (ordered by user value × feasibility)

From the roadmap architect; each lands with the same seam+tests+PENDING-rows discipline.

| # | Item | Verdict / effort | Sketch |
|---|---|---|---|
| 1 | **Remote control MVP (F4)** | spike-gated · L | `InputAuthorizer`/`CoordinateMapper`/`ControlCapability` are built+tested; missing runtime: `InputEventPlanner` (pure: click→down+up, drags, text chunking), `CGEventInjector` (JoeScreenInputMac; `InjectionStrategy` hidTap/postToPid/hybrid — default **hidTap**, runtime-switchable; the **Phase-0(c) spike** goes on the Human TODO ledger and later just flips the config — R26: postToPid unreliable to unfocused windows; HID-tap moves the owner's physical cursor, CoScreen-equivalent), `SecureInputDetector` (R8 banner, named in RISKS but nonexistent), `InputPump` on the already-open `.input` channel (CursorPump template), owner consent UI + "X is driving" badge. Wire: append `mouseMove`/`mouseDrag` kinds + optional `text:` payload **with tolerant decoding** (`.unsupported` case — the plain String enum throws on unknown raw values today; without the shim old peers break), optional kind 13 `controlRequest`. Autonomous scope: everything is buildable and Tier-1-testable without the spike; only strategy selection + live injection rows are human-gated. |
| 2 | Audio niceties | now · S | Join-muted default (flip the `setMicrophone(true)` on connect behind a pref), speaking rings ride M10's state hook. |
| 3 | **Cross-user clipboard (F6)** | now · M | `ClipboardSyncEngine` tested; add MainActor `changeCount` poller + pump on `.clipboard` channel + session-scoped default-OFF toggle. Exfiltration posture: never persisted-on; size limits + echo suppression already tested. |
| 4 | Window isolation blocklist | now · S | Pure `SensitiveAppPolicy` (1Password/Bitwarden/Keychain/…, exact+prefix); enforce at picker `excludedBundleIDs`, `shareWindow(cgWindowID:)` resolution, and capture start. |
| 5 | Menu-bar residency | now · S | `MenuBarExtra` + app delegate (`applicationShouldTerminateAfterLastWindowClosed = false`); mic toggle, share, copy-invite-link, recents (`RecentsStore` pure seam), leave. Teardown paths must still run from the status menu. |
| 6 | Multi-user control + soft lock (F5/F10) | after #1 · M | `ActiveControllerLock` exists; add display-only `controllerByWindow` to snapshots (authorization never reads it — D12). |
| 7 | **Rooms + HTTPS invite links + presence-lite (F13-lite)** | now · M | New `apps/joescreen-rooms` Cloudflare Worker (cheffing.dev pattern, deploys via the existing CI): KV slug directory, `/r/<slug>` page with OpenGraph + `joescreen://` redirect + download fallback, presence via LiveKit RoomService `ListParticipants` (Twirp, server-resident key). Decision needed: token minting consolidates into the Worker (WebCrypto HS256) or stays in the Go token server (add CORS + viewOnly param). |
| 8 | **Browser view-only join** | now · M | The SFU already speaks WebRTC. Static `livekit-client` page on the Worker: subscribe-only token (`canPublish:false, canPublishData:false`), parses `window:*` names, element-size-driven adaptiveStream holds R24/R32 automatically. Tier-2 row: Safari VP9 decode of single-window shares (D5) — escape hatch is the structural H.264 path. |
| 9 | Draw/annotation (F9) | now · M | `DrawModel` built (TODO(Phase2) pump comment); add runtime authorSeq, coalesced send on `.draw`, SwiftUI Canvas ink overlay in participant colors over `RemoteVideoView`, per-author undo/clear, late-joiner ink snapshot. |
| 10 | Hover "Share" tab | spike-gated · M | The CoScreen signature gesture. Global mouseMoved monitor + `WindowHitTester` (pure z-order/pid/layer resolution) + non-activating floating panel → `shareWindow`. **Gated on an R4 spike:** non-picker capture prompt cadence on macOS 15; fallback = tab pre-seeds the picker. |
| 11 | Slack deep-link lite | after #7 · S | Copy-invite-link button; `/r/<slug>` unfurls via OpenGraph in Slack. Full Slack app deferred. |
| 12 | CoTerm-lite terminal (F12) | defer-last · XL | PTY spike first (`posix_openpt` host → `SecretRedactor` → `.terminal` channel; SwiftTerm renderer; pure `WriterArbiter` on `TerminalControl.writerID`). Most novel, least parity-critical. |
| — | Contacts/direct-call | deferred | Needs identity+push infrastructure (or the hardware-blocked SharePlay path, H1). Revisit after #7 proves the link loop. |

---

## 5. Autonomous operation policy (no human in the loop)

The implementation session runs unattended. Nothing in this plan may block on a human;
work that genuinely needs one is **deferred, never faked and never waited on**.

**The Human TODO ledger.** Maintain a `## Human TODO` section at the bottom of this file.
Every time work hits something only a human can do — a TCC grant (Screen Recording,
camera/mic, `kTCCServicePostEvent`/Accessibility), the Phase-0(c) injection spike, the R4
prompt-cadence spike, any Tier-2 row needing a second Mac or different iCloud accounts —
implement everything up to that boundary, write the corresponding TESTING.md row as
PENDING with the exact expected outcome, add a ledger entry (what to do, how long it
takes, what it unblocks), and **continue with the next item**. Never simulate a grant,
never mark a Tier-2 row passed, never sit idle waiting.

**Spike-gated code paths** are built behind runtime switches so the human result slots in
later without rework: e.g. `CGEventInjector` ships with the `InjectionStrategy` enum and a
default (hidTap) plus a config override, so the Phase-0(c) spike later picks the strategy
by flipping a value, not by restructuring code.

**Product decisions — decided now for autonomous execution** (each is deliberately the
reversible option; record any further decisions the run must make in DECISIONS.md with a
one-paragraph rationale, choosing the reversible option when uncertain):
1. **Display-share `showsCursor` = true** (sharer's pointer baked into display shares).
   Window shares keep `false` + overlay cursors. Revisit if overlay-everywhere is wanted.
2. **Renegotiation: strict D5** — live VP9 window tracks republish as H.264 when a display
   share joins; the ~1s freeze is accepted. A single flag can soften this later.
3. **One display share per sharer** in v1 (window+display mix allowed; display+display
   refused with a visible reason). Simplifies admission; lift later if wanted.
4. **Token residency:** the Go token server (`apps/livekit/token-server`) stays the minter
   for app tokens; browser view-only tokens (backlog #8) are minted Worker-side via
   WebCrypto HS256 with the LiveKit secret stored as a Worker secret. Consolidate later
   only if operating two minters proves annoying.
5. **Clipboard toggle: session-scoped, default OFF, never persisted.** Security posture
   wins; persistence can be added behind a preference later.

## 6. Definition of done, per milestone

1. Machine gate green: `swift build && swift test` from `apps/joescreen/` (all existing 120+
   tests plus the milestone's new Tier-1 suites; integration suite green with `LIVEKIT_URL`).
   Known environment trap: if `swift build` spews identical "property does not override any
   property from its superclass" errors from inside `.build/checkouts/client-sdk-swift`, the
   SPM incremental state is poisoned — delete `.build/build.db`, the `LiveKit.build` dir,
   `LiveKit.swiftmodule` and the ModuleCache and rebuild. Do NOT conclude the pinned SDK is
   broken and do NOT bump it.
2. `xcodegen generate --spec Apps/project.yml && xcodebuild … -scheme JoeScreen-macOS … build`
   succeeds (the app target compiles, not just the package).
3. TESTING.md updated: milestone row with the exact gate command + result; new Tier-2 rows
   written as PENDING with expected outcomes.
4. DECISIONS.md updated when a milestone makes a choice this plan marks as open.
5. Commit per ordered step (each step compiles); milestone summary commit message references
   this plan's section.

---

## Human TODO

Work that genuinely needs a human (TCC grants, a second Mac, spikes) — deferred, never faked. Each
entry: what to do, rough time, what it unblocks. The corresponding TESTING.md rows are PENDING with
exact expected outcomes.

### M9 — receive-side lifecycle (all need a real Screen-Recording grant; most need 2 Macs)
- **TCC: grant Screen Recording to JoeScreen.app** (~1 min, once). Unblocks EVERY capture/share Tier-2
  row (M9-1…M9-8, F1-F3). The `xctest` host can't hold this grant (transient CLI, error −3801); the
  app path needs a human to click Allow in System Settings → Privacy → Screen Recording, then relaunch
  (ad-hoc re-signing may re-prompt — R4).
- **TESTING.md M9-1 sharer force-quit → viewer closes ≤2 s** (~5 min, 2 Macs). Verifies the trackGone
  frozen-ghost fix live.
- **TESTING.md M9-2 close-then-Reopen at remembered frame with live video** (~5 min, 2 Macs).
- **TESTING.md M9-3 source resize keeps remote aspect within one stabilizer confirmation** (~5 min, 2 Macs).
- **TESTING.md M9-4 two owners × two windows → per-owner cascade groups** (~10 min, 3 Macs or 2 Macs +
  2 windows each).
- **TESTING.md M9-5 letterbox cursor alignment (portrait on landscape viewer)** (~5 min, 2 Macs).
- **TESTING.md M9-6 reconnect grace: badge over frozen frame, 10 s hold, recover** (~10 min, 2 Macs +
  a way to blip the network).
- **TESTING.md M9-7 miniaturize/occlude releases SFU downlink (webrtc-internals)** (~10 min, 2 Macs +
  chrome://webrtc-internals or the SFU stats).
- **TESTING.md M9-8 viewer title bar shows window title + app + owner; aspect-true tile** (~3 min, 2 Macs).

### M10 — participant tile strip (need 2–3 Macs with cameras + mic TCC)
- **TCC: grant camera + mic to JoeScreen.app** (~1 min, once, per Mac). Unblocks every M10 tile row.
- **TESTING.md M10-1 3 Macs, distinct names, all tiles + correct names ≤2 s** (~10 min, 3 Macs).
- **TESTING.md M10-2 mute mic on A → red badge on B/C ≤1 s** (~3 min, 2 Macs).
- **TESTING.md M10-3 camera off → avatar, NOT a frozen frame** (~3 min, 2 Macs). Verifies the
  isMuted semantic trap live.
- **TESTING.md M10-4 speaking ring tracks the actual speaker ≈300 ms** (~5 min, 2–3 Macs). Add a
  debounce only if it flickers.
- **TESTING.md M10-5 8-participant decode-budget parking** (~15 min, needs ~8 clients — can be
  several instances across a couple of Macs). Confirms cameras beyond budget park as avatars.
- **TESTING.md M10-6 live share thumbnail + tap-to-focus; big window keeps quality** (~5 min, 2 Macs +
  webrtc-internals to confirm one decode, and that a soft-hidden window drops the downlink even with
  the thumbnail visible — the review-fixed R24/R32 path).

### M11 — whole-screen (display) share (need 2 Macs; a 5K display for M11-1)
- **TESTING.md M11-1 5K display → receiver ≈2389×1344 aspect-true** (~5 min, 2 Macs + a 5K display).
- **TESTING.md M11-2 window+display both H.264; window renegotiates ~1s freeze no flicker** (~10 min,
  2 Macs + webrtc-internals). The single most important M11 verification.
- **TESTING.md M11-3 hall-of-mirrors: JoeScreen's own windows absent from the shared display** (~5 min,
  2 Macs).
- **TESTING.md M11-4 screen lock pauses (badge), unlock resumes ≤2s** (~5 min, 2 Macs).
- **TESTING.md M11-5 display unplug unshares ≤2s** (~5 min, 2 Macs + a detachable display).
- **TESTING.md M11-6 second-display refused with a reason** (~2 min, 2 Macs + 2 displays on the sharer).
- **TESTING.md M11-7 R27 observation: DRM window → black region** (~5 min, 2 Macs + a DRM source).
- **TESTING.md M11-8 macOS 14.x picker resolution tier** (~10 min, needs a macOS 14.0–15.1 Mac —
  exercise the DisplayPickResolver floor path). Skippable if no 14.x hardware.
- **TESTING.md M11-9 sharer border overlay + "Sharing Display" chip/stop** (~3 min, 2 Macs — confirm
  the border is invisible to the receiver).

### Backlog #1 — Remote control MVP (F4)
- **TCC: grant `kTCCServicePostEvent` (Accessibility → "Allow the app to control your computer")**
  (~1 min, once). Unblocks ALL live injection. The app preflights via
  `InjectionPermissions.requestPostEventAccess()`; a human must approve in System Settings and
  relaunch (ad-hoc re-signing may re-prompt — R4). Optional: `kTCCServiceAccessibility` for AX
  focus-assist.
- **SPIKE: Phase-0(c) injection-strategy validation** (~30–60 min, 1 Mac). Verify `CGEvent` injection
  reaches an unfocused target window under each `InjectionStrategy` (hidTap / postToPid / hybrid),
  incl. tagged-event local-override. The result flips `CGEventInjector.strategy` (default hidTap) — a
  config change, not a rewrite. Until run, the app ships hidTap.
- **WIRING: owner grant path.** The InputPump currently ships `remoteControlEnabled=false` (safe
  default) with a nil bounds provider, so nothing injects. Wiring the consent approval to actually set
  `remoteControlEnabled` + a `.write` capability + real window bounds is a ~1–2h follow-up once the
  TCC grant + spike confirm injection works — the authorizer/injector/pump are all built and tested.
- **TESTING.md F4/F5 rows (below)** need 2–3 Macs with the grant.
