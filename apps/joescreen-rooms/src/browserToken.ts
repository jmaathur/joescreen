// Browser view-only token minting (backlog #8, DECISIONS §5.4: browser tokens are minted
// Worker-side). A subscribe-only grant — canSubscribe:true, canPublish:false, canPublishData:false —
// so a web viewer can WATCH shares but never publish media/data into the room. HS256 with the
// server-resident LiveKit secret.

import { signHS256 } from "./jwt";

/**
 * Mint a view-only LiveKit access token for `room`. The identity is a fresh, obviously-view-only
 * string so the app roster can distinguish web watchers.
 */
export async function mintViewOnlyToken(opts: {
	apiKey: string;
	apiSecret: string;
	room: string;
	identity: string;
	name?: string;
	nowSeconds: number;
	ttlSeconds?: number;
}): Promise<string> {
	const { apiKey, apiSecret, room, identity, name, nowSeconds } = opts;
	const ttl = opts.ttlSeconds ?? 2 * 60 * 60; // 2h
	const claims: Record<string, unknown> = {
		iss: apiKey,
		sub: identity,
		nbf: nowSeconds,
		exp: nowSeconds + ttl,
		video: {
			room,
			roomJoin: true,
			canSubscribe: true,
			canPublish: false, // view-only: never publishes media
			canPublishData: false, // ...nor data (no cursor/input/etc from the browser)
		},
	};
	if (name) claims.name = name;
	return signHS256(claims, apiSecret);
}
