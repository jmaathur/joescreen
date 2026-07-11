// Presence via the LiveKit RoomService (Twirp over HTTPS). The Worker mints a short-lived admin JWT
// (roomAdmin grant) with the server-resident API key/secret and calls ListParticipants. Read-only;
// NO app tokens are minted here (that's the Go token server — DECISIONS §5.4).

import { signHS256 } from "./jwt";

export interface Presence {
	/** null when presence couldn't be determined (no API URL / call failed) — the page degrades. */
	count: number | null;
}

/**
 * Query the live participant count for a room. Returns { count: null } (not an error) when the
 * RoomService isn't configured or the call fails, so the invite page never 500s over presence.
 */
export async function roomPresence(opts: {
	apiUrl: string;
	apiKey: string;
	apiSecret: string;
	room: string;
	nowSeconds: number;
	fetchImpl?: typeof fetch;
}): Promise<Presence> {
	const { apiUrl, apiKey, apiSecret, room, nowSeconds } = opts;
	if (!apiUrl || !apiKey || !apiSecret) return { count: null };
	const doFetch = opts.fetchImpl ?? fetch;

	try {
		// A short-lived roomAdmin token scoped to this room (read is enough for ListParticipants).
		const token = await signHS256(
			{
				iss: apiKey,
				nbf: nowSeconds,
				exp: nowSeconds + 60,
				video: { roomAdmin: true, room },
			},
			apiSecret,
		);
		const res = await doFetch(`${apiUrl.replace(/\/$/, "")}/twirp/livekit.RoomService/ListParticipants`, {
			method: "POST",
			headers: {
				"content-type": "application/json",
				authorization: `Bearer ${token}`,
			},
			body: JSON.stringify({ room }),
		});
		if (!res.ok) return { count: null };
		const data = (await res.json()) as { participants?: unknown[] };
		return { count: Array.isArray(data.participants) ? data.participants.length : 0 };
	} catch {
		return { count: null };
	}
}
