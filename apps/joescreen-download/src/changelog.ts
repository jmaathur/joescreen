// Version history for the download page's "What's new" section. Inlined (no runtime fetch / no build
// step) to match the worker's asset-free philosophy. Keep in sync with the repo's /CHANGELOG.md when
// cutting a release: bump `APP_VERSION` in wrangler.jsonc AND prepend a release here.

export interface Release {
	version: string;
	date: string; // ISO yyyy-mm-dd
	/** Optional tag shown next to the version (e.g. "early beta"). */
	tag?: string;
	/** Short user-facing highlights (the page shows these; full notes live in CHANGELOG.md). */
	highlights: string[];
}

// Newest first.
export const RELEASES: Release[] = [
	{
		version: "0.3.1",
		date: "2026-08-07",
		tag: "early beta",
		highlights: [
			"Fix: transcription produced no text in 0.3.0 (recognizer ignored the call's Int16 audio, and results only flush at utterance boundaries — both fixed)",
			"Captions now appear per utterance, ~1 second after each speaker pauses",
		],
	},
	{
		version: "0.3.0",
		date: "2026-08-07",
		tag: "early beta",
		highlights: [
			"Multiplayer dictation: one person enables Transcribe and the whole call is captioned, every line tagged with the speaker's name",
			"Speakers who also transcribe publish their own captions, which take precedence automatically",
			"Fix: local mic transcription produced no text (now taps the call's echo-cancelled capture; muted mics are never transcribed)",
			"Fix: transcription no longer gives up after quiet stretches",
		],
	},
	{
		version: "0.2.1",
		date: "2026-08-07",
		tag: "early beta",
		highlights: [
			"Fix: enabling Transcribe crashed the app for first-time users (Speech permission callback)",
			"Transcription now fails soft (with a visible reason) when no usable microphone input exists",
		],
	},
	{
		version: "0.2.0",
		date: "2026-08-06",
		tag: "early beta",
		highlights: [
			"Shared live transcript + recording notes — on-device speech-to-text, merged per speaker",
			"Co-located audio: mark same-room participants and your mic auto-yields (no doubled voices)",
			"⌘⇧M global mute hotkey + Call menu; mic state always matches what the room hears",
			"Share list stays in sync with simultaneous sharers; late joiners see every live share",
			"Screen Recording permission fixes: no re-prompts, auto-recovery after app updates",
			"Live self-preview of your own shared window",
		],
	},
	{
		version: "0.1.0",
		date: "2026-07-10",
		tag: "early beta",
		highlights: [
			"Everyone's webcam in tiles — names, mic + speaking indicators",
			"Share a window or your whole screen as movable native windows",
			"Draw, annotate, and cross-user clipboard on shared windows",
			"Rooms + invite links that unfurl in Slack/iMessage",
			"Menu-bar residency with recent sessions",
			"Reliable shares: no frozen ghost windows, cursors aligned per-pixel",
		],
	},
];

/** The current (newest) version string, used for the download badge. */
export const CURRENT_VERSION = RELEASES[0]?.version ?? "0.1.0";
