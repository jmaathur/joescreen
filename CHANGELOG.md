# Changelog

All notable changes to JoeScreen (macOS). JoeScreen is in **early beta**. Format based on
[Keep a Changelog](https://keepachangelog.com); this project uses [Semantic Versioning](https://semver.org).

The user-facing highlights from each version are also shown in the "What's new" section of
[joescreen.cheffing.dev](https://joescreen.cheffing.dev) — keep that section (in
`apps/joescreen-download/src/changelog.ts`) in sync with the entries here when you cut a release.

## [0.2.0] — 2026-08-06 · early beta

Live transcripts, smarter same-room audio, and a big batch of sharing/permission fixes. Also the
first cycle where the iOS companion (TestFlight) can share its camera and whole screen.

### New
- **Shared live transcript + recording notes** — everyone's speech, transcribed on each person's own
  Mac (Apple Speech, on-device when supported) and merged into one speaker-attributed live
  transcript in the new Notes pane. Anyone can cut a recording note; the notes list stays in sync
  for the whole room. Opt-in per person; nothing but text ever leaves your machine.
- **Co-located audio mitigation** — mark a participant as co-located (same physical room) from the
  roster; your mic automatically yields while they're the dominant speaker and releases when they
  go quiet or you clearly take over. No more doubled voices from two laptops in one room.
- **Mute from anywhere** — ⌘⇧M toggles your mic globally (plus a Call menu with the same shortcut),
  and the mic button/menus now always reflect what the room actually hears.
- **Live self-preview** for your own shared window in the shares pane (was a placeholder).
- **iOS (TestFlight):** share your camera, toggle mic/camera, and share your whole screen via the
  system broadcast picker.

### Fixed
- **Share list stays in sync**: shares from two people sharing at once no longer vanish from the
  list, late joiners now see every already-live share (video *and* list entry), and phantom
  participants no longer appear in the roster.
- **Late-join video reliability**: a track that was already live when you joined could stay
  invisible until re-shared (LiveKit join race) — now recovered automatically with bounded retries.
- A newcomer's mic/camera no longer shows muted/off to peers until they toggle.
- The sharer's red border now covers the correct region on multi-display setups, and an orphaned
  border/"Sharing Display" pill can no longer outlive the share after a retry/desync.
- Screen Recording: no more re-prompt on every share when already granted, and automatic recovery
  from a stale grant after an app update.
- No more spurious "Couldn't join" when a single track renegotiation timed out mid-call.
- The system share picker no longer lingers on screen after you pick a window/screen.
- Release builds: mic/camera were blocked by missing device entitlements.

### Under the hood
- Explicit echo-cancellation/auto-gain/noise-suppression capture configuration (VoiceProcessingIO
  pinned on macOS).
- Room-state sync moved from revision-gated snapshot replace to per-window union merge with ordered
  share events (fixes concurrent-sharer collisions by design; D20).

[0.2.0]: https://joescreen.cheffing.dev

## [0.1.0] — 2026-07-10 · early beta

The first public build. Everyone's webcam in tiles, share a window _or_ your whole screen, and every
remote share is a real, movable native window on your desktop — plus a wide collaboration toolset.

### Screen sharing
- **Share a window _or_ your whole screen** — shared surfaces open as movable, aspect-true windows on
  every desktop (not a screenshare rectangle). Multiple simultaneous shares supported.
- **Live share thumbnails** in the shares pane — tap to bring a shared window to the front.
- **Reliable windows** — a crashed/disconnected sharer's window closes cleanly (no frozen "ghosts");
  windows resize with their source, reopen at their remembered spot, and never open off-screen.
- **Password-manager windows are never shareable** (1Password, Bitwarden, Keychain, …).

### See everyone
- **Participant webcam tiles** — everyone live, or an avatar when their camera is off, with names,
  mic-muted badges, and a green speaking ring.
- **Display names** — set "Your name" on join; peers (and late joiners) see it everywhere.
- **Multiplayer cursors** — see everyone's pointer, per window, aligned to the exact pixel at both ends.

### Collaborate
- **Draw / annotate** on any shared window — live ink in each author's color, with per-author undo/clear.
- **Cross-user clipboard** — opt in per session (off by default, never persisted).
- **Remote control groundwork** — click and type into a shared window (owner grants control; ships off
  by default pending the accessibility grant).
- **Rooms + invite links** — shareable links that unfurl in Slack/iMessage, a browser view-only "watch"
  page, and live presence.

### Voice & app
- **Built-in voice** on the same live connection; self camera preview + device pickers; **Join muted**
  preference.
- **Menu-bar residency** — quick mic/share/leave and a Recent-sessions list from the menu bar.
- Join via a launch argument, a `joescreen://` deep link, or the join sheet.
- Notarized Developer-ID `.dmg` for direct download (macOS 14+, Apple Silicon &amp; Intel).

### Under the hood
- Whole-screen and multi-window shares use H.264 for reliability; a single window stays VP9 for crisp
  small text — adding a screen share transparently renegotiates existing shares.
- Upload-bandwidth admission is enforced: a share that won't fit is refused with a clear reason rather
  than silently degrading everyone.

[0.1.0]: https://joescreen.cheffing.dev
