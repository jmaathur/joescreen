// Pure slug logic (unit-tested) — no Worker/KV/network. A room slug is a short, URL-safe,
// human-shareable handle mapping to a LiveKit room name via the KV directory.

/** The record a slug points at in KV. */
export interface RoomRecord {
	/** The LiveKit room name every joiner shares. */
	room: string;
	/** The SFU URL the app dials (wss://…). */
	sfu: string;
	/** Optional display title for the OpenGraph unfurl. */
	title?: string;
	/** Creation timestamp (ms), stamped by the caller (Date is injected — Workers have Date). */
	createdAt?: number;
}

const SLUG_ALPHABET = "abcdefghijkmnpqrstuvwxyz23456789"; // no ambiguous 0/o/1/l
const SLUG_LEN = 7;

/** Whether a string is a well-formed slug (lowercase alnum from the unambiguous alphabet, 4–24). */
export function isValidSlug(slug: string): boolean {
	if (slug.length < 4 || slug.length > 24) return false;
	return /^[a-z0-9-]+$/.test(slug) && !slug.startsWith("-") && !slug.endsWith("-");
}

/** Generate a random slug from `randomBytes` (injected so it's deterministic in tests). */
export function makeSlug(randomBytes: Uint8Array, len: number = SLUG_LEN): string {
	let out = "";
	for (let i = 0; i < len; i++) {
		out += SLUG_ALPHABET[randomBytes[i % randomBytes.length] % SLUG_ALPHABET.length];
	}
	return out;
}

/** Normalize a user-supplied custom slug (lowercase, spaces→dashes, strip invalid), or null. */
export function normalizeCustomSlug(input: string): string | null {
	const s = input
		.toLowerCase()
		.trim()
		.replace(/\s+/g, "-")
		.replace(/[^a-z0-9-]/g, "")
		.replace(/-+/g, "-")
		.replace(/^-|-$/g, "");
	return isValidSlug(s) ? s : null;
}

/** Build the `joescreen://join?…` deep link for a room record (identity omitted — fresh per joiner). */
export function deepLink(record: RoomRecord): string {
	const params = new URLSearchParams({ server: record.sfu, room: record.room });
	return `joescreen://join?${params.toString()}`;
}
