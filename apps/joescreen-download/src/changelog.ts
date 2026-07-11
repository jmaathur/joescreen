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
