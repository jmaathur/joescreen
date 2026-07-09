# JoeScreen — Implementation prompt: make calls work (Phase 1+)

ultracode

You are picking up **JoeScreen** — a native macOS + iOS CoScreen-style shared-desktop app — at the
end of its **Phase-0 foundation**. Your mission this session: take it from "green tests, no app" to
**working calls between users**: two or more people in a session with live voice and shared
windows, each shared window rendered as a real, movable native window on every peer's desktop.

Work in this repo. It is a git repo with a public remote (`github.com/jmaathur/joescreen`). Commit
locally at every green milestone; **ask before pushing.**

**If time runs out:** a green M4 (the two-instance demo, without voice) is the acceptable stopping
point. Cut from the back: M8 → M7 → M6 → M5. Never trade a green M4 for partial later milestones.

---

## §0. Ground truth — read these BEFORE writing any code

The foundation was built with live-doc API verification and every choice is recorded. These files
are **binding** — do not contradict them without recording a superseding decision:

1. `DECISIONS.md` — D1–D14. Especially D3/D4 (LiveKit SFU transport), D5 (codec), D8 (package-first
   layout), D9 (SharePlay = coordination only), D12 (input security).
2. `RISKS.md` — R1–R30. Every UNVERIFIED API assumption has a shim/convention; honor them.
3. `TESTING.md` — the two-tier gate. **The Tier-1 suite (84 tests at handoff) must stay green as
   you extend it.** Tier-2 (hardware) rows stay PENDING unless actually observed.
4. `docs/architecture.md` — the two-plane model.
5. `BUILD_PROMPT.md` §2 — the hard platform constraints (SharePlay can't stream media; iOS can't be
   controlled; injection forces non-sandboxed Developer-ID; etc.).

**Discipline carried over from Phase 0 (non-negotiable):**
- Verify any Apple/SDK API you use beyond what §3/§4 below already verify — live docs, WWDC
  transcripts, or the SDK `.swiftinterface`/source. Never implement unverified surface from memory;
  mark what you can't verify in `RISKS.md` behind a narrow shim. §3 flags its own known gaps —
  verify those the moment you touch them.
- **Never fabricate "verified on hardware."** You have ONE dev Mac. Anything needing a second
  device/iCloud account goes in the `TESTING.md` run-book as PENDING. One-time TCC grants on the
  dev Mac itself (Screen Recording, mic) are acceptable local human steps — record them.
- Orchestrate with workflows (this prompt's `ultracode` keyword enables that): fan out independent
  readers/implementers, adversarially verify risky assumptions, stay in the loop between phases.
- Build **vertically**: a thin working call first, then widen. Every milestone below has a machine
  gate — advance only on green.

**Known repo doc-drift to fix in passing:** `Spikes/README.md` lists `VTLowLatencyH264Encoder` and
`EventInjector` as existing "wrapper stubs" — **neither exists anywhere in the repo**; you will
write them when their milestones come. `Package.swift` line ~39 comments reference a target
"JoeScreenKitCore" that doesn't exist (the target is `JoeScreenKit`). Fix both when you touch those
files.

---

## §1. THE key unblock: Direct Session Mode (build this FIRST)

SharePlay requires two Apple devices on different iCloud accounts — which you don't have. If you
build SharePlay-first you will write weeks of code you can never run. So:

**Mandate: sessions must be joinable WITHOUT SharePlay** via explicit parameters — server URL +
room name + identity — through (a) a join sheet, (b) a `joescreen://join?...` URL, and (c)
**launch arguments** (`--join-url ws://… --room … --identity …`) so automation can drive a join
with zero clicks. Call it **Direct Session Mode**. It is not a test hack; it is a real product path
("join by link") and the only reason this session's work is demoable and machine-verifiable:

- Two app instances on ONE Mac + `livekit-server --dev` = a real call: voice + window share,
  end-to-end, today.
- Two users on the internet + the deployed `infra/` server = real calls between users **without
  waiting for SharePlay**.
- SharePlay (M7) then becomes a *bootstrap layer* that auto-fills what Direct Mode types manually
  — the media plane is identical.

**Identity rule (demo-critical):** default the identity field to a **fresh `UUID()` per app
launch**. Identities MUST be unique per participant — **LiveKit disconnects the previous holder
when a duplicate identity joins**, so two instances sharing a default identity silently kills
instance A the moment B connects.

For `--dev` servers, mint HS256 JWTs locally behind a `#if DEBUG` `DevTokenMinter` — do not require
the `lk` CLI for the demo path. **The token must be a standard LiveKit access token**: header
`{"alg":"HS256","typ":"JWT"}`; claims `iss` = API key (`devkey`), `sub` = identity
(`ParticipantID.uuidString`), `nbf` = now, `exp` = now + a few hours, and a `video` grant object
`{"room":"<room>","roomJoin":true,"canPublish":true,"canSubscribe":true,"canPublishData":true}`;
HMAC-SHA256 with the secret (`secret`); base64url **without padding** on all three segments.
⚠️ This claims structure is NOT among §3's pre-verified facts — verify it against
`docs.livekit.io` authentication docs (or the server's auth package) before implementing, and
cross-check by diffing your output against `lk token create --api-key devkey --api-secret secret
--join --room demo --identity test` if the CLI is available. A rejected token fails M2 and M4 with
only an opaque auth error. Production tokens come from `infra/token-server` via a small
`TokenClient`.

---

## §2. What already exists — wire into these EXACT APIs (do not reinvent)

All of this is on `main`, compiles under Swift 6 strict concurrency, and the pure logic is tested.
Read the files; signatures below are the audited truth.

**The transport seam you must implement** — `Sources/JoeScreenKit/Transport/MediaTransport.swift`:
```swift
protocol MediaTransport: Sendable {
  func connect(_ configuration: MediaTransportConfiguration) async throws   // {serverURL, authToken}
  func disconnect() async
  func connectionStates() -> AsyncStream<MediaConnectionState>
  func bindIdentity(_ participantID: ParticipantID, transportIdentity: String) async
  func publishVideoTrack(for windowID: WindowID) async throws -> any VideoFrameSink
  func unpublishVideoTrack(for windowID: WindowID) async
  func openDataChannel(_ channel: DataChannel) async throws -> any WireDataChannel
}
// VideoFrameSink.submit(_:) is async and takes OpaqueVideoFrame whose `box` is `any Sendable`.
// CMSampleBuffer is NOT Sendable under Swift 6 — you will need a small @unchecked Sendable
// wrapper box (document why it is safe: the buffer is transferred, never shared).
// WireDataChannel: { channel; send(Data) async throws; incoming() -> AsyncStream<Data> }
```

**The wire protocol** (`Sources/JoeScreenKit/WireProtocol/`) — all payloads round-trip-tested:
- `Envelope {version, kind, senderID, seq?, body}`, JSON keys `v/k/s/q/b`; unknown kinds decode to
  `kind == nil` (skip, never crash). Pack/unpack ONLY via `WireCodec.pack/unpack` — it enforces the
  seq-presence contract.
- `MessageKind` (UInt16 wire tags 1–10) → fixed `DataChannel`; `ChannelPolicy.policy(for:)` is the
  authoritative matrix: cursor=unreliable/unordered · input=reliable/ordered(+seq) ·
  clipboard/terminal=reliable/ordered · draw=reliable/orderedPerAuthor. **Appending new tags is the
  sanctioned way to extend** (M0 adds 11–12); tags 1–10 are reserved history, never renumbered.
- `SequenceTracker.offer(sender:seq:) -> {accept|duplicate|gap(missing:)}` + `SequenceGenerator`
  for the input channel. **Known dead code:** the declared `.outOfOrder` case is unreachable
  (`seq <= last` returns `.duplicate` first) — remove or restructure it in M0, update its tests AND
  the `SequenceTrackerTests` row in TESTING.md (which currently claims "out-of-order handling").
- Payloads: `CursorMove`, `InputEvent`, `CapabilityGrant/Revoke`, `ClipboardPayload`,
  `TerminalData/Control`, `DrawOp/Clear/Undo`. Coordinates are ALWAYS `NormalizedPoint` [0,1].

**The session seam** — `Sources/JoeScreenKit/Session/SessionProviding.swift`:
`start(_ activity:) / join() / leave() / localParticipantID / stateUpdates() /
participantUpdates()` (participant set INCLUDES local). No implementation exists yet. Note:
`JoeScreenActivity` in JoeScreenKit **already conditionally conforms to `GroupActivity`** behind
`#if canImport(GroupActivities)` + `@available` — reuse that conformance in M7; do NOT re-declare
it in the app target (duplicate-conformance error).

**Ready to wire (implemented + tested — respect the division of labor):**
- `InputAuthorizer` — owner-side authorization: peer-identity binding, Watch-default, capability +
  lock checks. **Its `.inject` decision does NOT clamp coordinates** — the caller must map through
  `CoordinateMapper.toGlobalCGPoint`, which applies the out-of-bounds **security clamp** (that's
  where the clamp lives, tested in `CoordinateMapperTests`).
- `CoordinateMapper`, `AdmissionController`, `CodecSelector` (VP9→H.264 one-way fallback),
  `ClipboardSyncEngine`, `SecretRedactor`, `SignalingSendQueue`, `ICECandidateBatcher`,
  `PauseDetector`, `EncodedFrameRingBuffer`, `RoomModel` (revision-countered state), `DrawModel`,
  `ParticipantColor` (deterministic FNV-1a → hue).

**Does not exist at all (your work):** the Xcode app layer (`Apps/` dirs are EMPTY), any `@main`
entry point, any `MediaTransport`/`SessionProviding` conformance, capture engine (only
`PauseDetector` exists in CaptureMac), encoder/decoder code (no `VTLowLatencyH264Encoder`), an
`EventInjector` (despite Spikes/README claiming otherwise), renderer/UI views (JoeScreenUI has one
model file), channel pumps connecting `WireCodec` ↔ `WireDataChannel`, token client, PTY, iOS
extension `SampleHandler`.

---

## §3. Verified SDK facts (pre-verified for you — with the known gaps flagged inline)

**LiveKit `client-sdk-swift` 2.15.1** (pinned in DECISIONS D7; verified against the tag source):
- `Room.connect(url: String, token: String, connectOptions: ConnectOptions? = nil, roomOptions:
  RoomOptions? = nil) async throws`. `RoomOptions(adaptiveStream:dynacast:...)` — **set both true**
  (R24 selective subscription is load-bearing).
- Publish a window: `LocalVideoTrack.createBufferTrack(name:source:options:)` with
  `source: .screenShareVideo`, then `(track.capturer as? BufferCapturer)?.capture(_ sampleBuffer:
  CMSampleBuffer)` (a `CVPixelBuffer` overload exists too). Two constraints from the SAME SDK doc
  comment: **(a) at least one frame must be captured BEFORE `publish(videoTrack:options:)` or the
  publish times out; (b) the buffer's pixel format must be in `VideoCapturer.supportedPixelFormats`
  or the SDK SILENTLY skips the capture** — no error; it manifests as (a)'s publish timeout. The
  concrete format list at 2.15.1 is UNVERIFIED: before locking M3 to 420v, read
  `Sources/LiveKit/Track/Capturers/VideoCapturer.swift` at the 2.15.1 tag, confirm
  `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` is listed, and record the finding in RISKS.md.
  Name tracks `"window:<windowID uuid>"` so receivers map track→window (confirm `.name` is visible
  on `RemoteTrackPublication` and `.identity` on `RemoteParticipant` when writing the adapter —
  near-certain but not in the audited fact list).
- `VideoPublishOptions(simulcast: false, preferredCodec: .vp9, degradationPreference:
  .maintainResolution)` (labels in declaration order) — VP9 IS requestable. **`contentHint` is NOT
  exposed at 2.15.1** (zero hits in the tag tarball) — record this as a new RISK (D5's contentHint
  invariant is unachievable through the SDK; `source: .screenShareVideo` is the closest lever) and
  move on.
- Voice: `localParticipant.setMicrophone(enabled: true)` (needs `NSMicrophoneUsageDescription`).
- Data: `localParticipant.publish(data:options:)` with
  `DataPublishOptions(topic: String?, reliable: Bool)` — **`reliable` defaults to FALSE** and the
  payload limit is **~15 KB per message** (NOT the messenger's 256 KB). Receive via
  `RoomDelegate.room(_:participant:didReceiveData:forTopic:encryptionType:)`.
  ⇒ Your `WireDataChannel` adapter: topic = `DataChannel.rawValue`, `reliable` from
  `ChannelPolicy`, demux incoming by topic, **iterate `DataChannel.allCases`** (M0 makes it six —
  do not hardcode five). ⇒ **Build a pure, unit-tested `Chunker` in JoeScreenKit**
  (`{groupID, index, count}` framing) for reliable-channel payloads >14 KB — clipboard images/RTF
  will exceed the limit.
- Events: `RoomDelegate` only (no public async-sequence API at 2.15.1) — `didSubscribeTrack/
  didUnsubscribeTrack/participantDidConnect/didUpdateConnectionState`. Bridge delegate→
  `AsyncStream` inside your adapter to satisfy `MediaTransport`.
- Rendering: `SwiftUIVideoView(track)` (macOS + iOS; pinch-zoom options built in). For M2's
  *programmatic* receive assertion you'll need a renderer hook (`track.add(videoRenderer:)` /
  `VideoRenderer`) — that surface is UNVERIFIED; check the 2.15.1 source before relying on it.
- Identity binding: mint tokens with `identity = ParticipantID.uuidString`; map the remote
  participant's identity string back to `ParticipantID` — that mapping is the `transportPeer`
  argument `InputAuthorizer` requires. Reject unparseable identities.

**livekit-server `--dev`**: API key `devkey`, secret `secret` (confirmed in server source; install
via `brew install livekit` — it is NOT preinstalled on this machine). CLI token minting (if `lk` is
installed): `lk token create --api-key devkey --api-secret secret --join --room <r> --identity
<id>` (subcommand shape verified on livekit-cli main, not a pinned release).

**XcodeGen**: `/opt/homebrew/bin/xcodegen` **2.42.0 is already installed — use it**; do not chase
a newer pin (Homebrew can't install back-versions; record the actual version used in
DECISIONS.md/README). The four features you need (target `entitlements:`/`info:` plist generation,
`app-extension` product type, local packages via `packages: {JoeScreen: {path: ..}}`,
`${DEVELOPMENT_TEAM}` env substitution) were doc-verified at 2.45.4 and are long-standing — confirm
against 2.42.0's docs if anything errors. Commit `project.yml`; **add the generated `.xcodeproj` to
`.gitignore` yourself** (the existing file only ignores `xcuserdata`); document `xcodegen generate
--spec Apps/project.yml` in the README.

---

## §4. Milestones (each has a machine gate; advance only on green)

**M0 — Deps + wire-protocol extension.** Uncomment the LiveKit pin in `Package.swift`; add a new
target `JoeScreenLiveKit` (depends: JoeScreenKit + LiveKit product) so **JoeScreenKit itself stays
dependency-free** (`swift test` needs the network once for first resolution, then `Package.resolved`
— commit it — keeps it reproducible). In JoeScreenKit: add the `Chunker` (+tests); fix
`SequenceTracker.outOfOrder` (+tests, + the TESTING.md row); **extend the wire protocol for
coordination state**: `DataChannel.state` (reliable / ordered / `requiresSequence == false`) in the
`ChannelPolicy` switch, and `MessageKind.roomSnapshot = 11` + `.shareEvent = 12` mapping to
`.state`, with `WireMessage` payload types (a `RoomModel` snapshot message; share/unshare events),
round-trip tests, and `testChannelMatrixIsCorrect` extended.
*Gate:* `swift build && swift test` green (84+new).

**M1 — Xcode layer.** `Apps/project.yml` (XcodeGen 2.42.0): target `JoeScreen-macOS` (SwiftUI app,
NOT sandboxed per D6, `NSMicrophoneUsageDescription`, URL scheme `joescreen`), consuming the local
package. **Signing (Killed-9 landmine):** when `TEAM_ID` is unset, ship an **EMPTY entitlements
file** and set `CODE_SIGN_IDENTITY: "-"` — the restricted `com.apple.developer.group-session`
entitlement in an ad-hoc-signed app with no provisioning profile gets the binary killed by AMFI at
launch (`Killed: 9`) on Apple Silicon, and the failure would surface two milestones later at the
demo. Gate the group-session entitlement on `TEAM_ID` being set (it isn't needed until M7).
iOS/extension targets come in M8 — don't block the Mac slice on them.
*Gate:* `xcodegen generate --spec Apps/project.yml && xcodebuild -project Apps/JoeScreen.xcodeproj
-scheme JoeScreen-macOS -derivedDataPath build build` succeeds and the built app **launches**
(no Killed: 9).

**M2 — LiveKitTransport.** `brew install livekit` first. An actor in `JoeScreenLiveKit` conforming
to `MediaTransport` exactly (§2/§3). Room lifecycle, delegate→AsyncStream bridging, topic-mapped
data channels honoring `ChannelPolicy` + Chunker (iterate `allCases` — six channels), buffer-track
publish with the frame-before-publish handshake, VP9/degradation options fed from `CodecSelector`,
`DevTokenMinter` (`#if DEBUG`, §1's claim structure, verified).
*Gate:* an integration test target that **skips (not fails) unless `LIVEKIT_URL` is set** (document
`livekit-server --dev & LIVEKIT_URL=ws://localhost:7880 swift test`): two `Room`s in one process —
synthetic frames A→B received (via the verified renderer hook; if two-Rooms-one-process misbehaves,
fall back to two test processes and note it); all six channels round-trip an Envelope with correct
topic/reliability; identity binding surfaces the right `ParticipantID`.

**M3 — Capture.** `WindowCaptureService` in JoeScreenCaptureMac: `SCContentSharingPicker` primary,
`SCContentFilter(desktopIndependentWindow:)`, pixel format per the §3 verification (420v if
supported — debug-assert, R14), `showsCursor false`, `minimumFrameInterval 1/30`; wire
`PauseDetector` (pause ≠ disconnect — R13) and a `MinimizeUnshareWatcher` (minimize ⇒ stop stream +
unshare event). Add a `--share-window-id <CGWindowID>` debug path bypassing the picker so
automation doesn't need a click.
*Gate:* on this Mac (Screen Recording is a one-time local TCC grant — record it in TESTING.md;
note: ad-hoc re-signing changes the cdhash each rebuild, so macOS may re-prompt after rebuilds —
expected, not a regression): a capture smoke-run receives ≥N `.complete` frames from a real window
and forwards them into a `VideoFrameSink`.

**M4 — THE CALL (vertical slice).** Mac app UI: join sheet (Direct Mode per §1: URL/room/identity,
identity defaulting to a fresh UUID; plus `joescreen://join` and the `--join-url/--room/--identity`
launch args), roster with `ParticipantColor`, Share button → picker, and per remote video track a
**real movable/resizable `NSWindow`** (SwiftUIVideoView content, owner-color border, local-only
scaling). Session state rides the `state` channel from M0: the sharer broadcasts `RoomModel`
snapshots (revision-countered, last-writer-wins) + share/unshare events; joiners apply.
*Gate — THE DEMO:*
```bash
livekit-server --dev &
APP=build/Build/Products/Debug/JoeScreen.app
open -n "$APP" --args --join-url ws://localhost:7880 --room demo --identity "$(uuidgen)"
open -n "$APP" --args --join-url ws://localhost:7880 --room demo --identity "$(uuidgen)"
```
(`open -n` is REQUIRED — plain `open` focuses the running instance instead of spawning a second;
the URL-scheme route is ambiguous with two identical instances, which is why the launch-arg path
exists.) Instance A shares a window (picker click or `--share-window-id`); instance B (view-only,
no TCC needed) renders it live in a movable native window. Screenshot into TESTING.md. This gate
makes "calls between JoeScreen users" REAL.

**M5 — Voice.** `setMicrophone(enabled:)` on join. Mic permission onboarding. This supersedes
D13's hand-built AVAudioEngine+Opus pipeline for the Direct-Mode/fallback voice path — **record a
superseding decision in DECISIONS.md** (LiveKit's SDK owns mic capture/AEC; D13's pipeline remains
the reference for any future non-LiveKit path).
*Gate:* integration test asserts the audio track's publication + cross-Room subscription
**without opening the capture device** (publication metadata or a synthetic/silent track) — live
mic in a headless test host would hang on an unclickable TCC prompt. The audible check and the
first live-mic run are one-time local human steps — record both in TESTING.md.

**M6 — Cursors.** `CursorMove` pump: coalesce-to-latest ~60 fps out, latest-wins in (drop stale
timestamps); click-through overlay window (`ignoresMouseEvents`, `.statusBar` level,
`.canJoinAllSpaces`) rendering every participant's pointer via `ParticipantColor` in per-window
normalized coords.
*Gate:* coalescing unit tests + cursor messages flowing in the two-instance demo.

**M7 — SharePlay layer.** `GroupSessionCoordinator: SessionProviding` in the app target. R12
correctly stated: **the broadcast extension links only JoeScreenBridge**; GroupSession/messenger
*use* lives only in app targets behind `SessionProviding` — and JoeScreenKit already conditionally
conforms `JoeScreenActivity: GroupActivity` (reuse it, don't re-conform). Activation:
`prepareForActivation()` → `GroupActivityActivationResult` (it is NOT Bool) → `activate()`;
`GroupActivitySharingController` presenter with the eligibility-gated fallback (R9);
`TransportBootstrap {serverURL, roomName, jwt}` via the existing `SignalingSendQueue` over
`GroupSessionMessenger` (≤200 KB, retry/backoff — R10); late-joiner state re-broadcast; media
survives session invalidation (R28). `TokenClient` for `infra/token-server`. Requires `TEAM_ID`
set + the group-session entitlement (see M1's gating).
*Gate:* compiles + unit tests against a `FakeSessionProvider`; runtime rows go to the TESTING.md
hardware run-book (2 devices, different iCloud accounts) as PENDING.

**M8 — iOS viewer (stretch).** iOS app target: join sheet + zoomable `SwiftUIVideoView` (viewer +
voice only; NO control target — R6 is permanent). Broadcast extension stays a later phase.
*Gate:* `xcodebuild -project Apps/JoeScreen.xcodeproj -scheme JoeScreen-iOS -destination
'generic/platform=iOS Simulator' build` + run in simulator against the LAN `--dev` server.

Remaining phases (input injection F4/F5 — wiring the already-tested `InputAuthorizer` +
`CoordinateMapper` clamp to a **new** `EventInjector` you will write; clipboard F6; draw F9;
terminal F12; iOS sharing; hardening) follow `BUILD_PROMPT.md` §7 — same milestone/gate pattern.
Do not start them before M4 is demonstrably green.

---

## §5. Landmine digest (violating any of these is a review-blocking bug)
1. Media NEVER rides `GroupSessionMessenger`; bootstrap/state only; ≤200 KB; queue+retry (R10).
2. LiveKit data ≤15 KB/message; `reliable` defaults FALSE — always set it from `ChannelPolicy`.
3. Watch is the default mode; injection later must flow through `InputAuthorizer` on the owner with
   the transport-bound peer identity — and clamp via `CoordinateMapper` AFTER `.inject` (the
   authorizer does not clamp). In-band flags never authorize (D12).
4. Never a second libwebrtc in the graph (D7). JoeScreenKit stays dependency-free.
5. Minimize ⇒ unshare; off-Space frame gap ⇒ pause, not disconnect (R13).
6. Don't preflight injection with `AXIsProcessTrusted()` — wrong TCC service (R26). Use the
   existing `InjectionPermissions`.
7. `swift test` must pass with no server running (integration tests skip via `LIVEKIT_URL`
   absence, not fail).
8. Unique participant identities per instance — LiveKit evicts duplicate-identity holders.
9. No restricted entitlements in ad-hoc-signed builds (Killed: 9). Entitlements are TEAM_ID-gated.
10. Keep `DECISIONS.md`/`RISKS.md`/`TESTING.md`/`docs/index.html` truthful as you go — including
    flipping docs/index.html's "runs today" section when the demo works, adding the new
    verified-SDK facts + the contentHint gap + the pixel-format finding to the risk register, and
    the M5 superseding decision.

## §6. Definition of done for THIS session
A user on one Mac can run:
```bash
brew install livekit && livekit-server --dev &
xcodegen generate --spec Apps/project.yml
xcodebuild -project Apps/JoeScreen.xcodeproj -scheme JoeScreen-macOS -derivedDataPath build build
APP=build/Build/Products/Debug/JoeScreen.app
open -n "$APP" --args --join-url ws://localhost:7880 --room demo --identity "$(uuidgen)"
open -n "$APP" --args --join-url ws://localhost:7880 --room demo --identity "$(uuidgen)"
# instance A: Share → pick a window   →   instance B: watch it live in a native window
```
…and see a live shared window (+ hear voice if M5 landed) between the two instances — with
`swift test` and the M2 integration suite green, every commit made at a green gate, the README's
quickstart updated to exactly these commands, and everything not runnable on one machine recorded
PENDING in `TESTING.md`. Ask before pushing to the public remote.
