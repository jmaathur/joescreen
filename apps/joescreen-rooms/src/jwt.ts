// Minimal HS256 JWT signing via WebCrypto (available in Workers). Used for the RoomService presence
// admin token here, and for browser view-only tokens in backlog #8 (DECISIONS §5.4: browser tokens
// are minted Worker-side). base64url without padding, per RFC 7515.

function base64url(bytes: Uint8Array): string {
	let bin = "";
	for (const b of bytes) bin += String.fromCharCode(b);
	return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function utf8(s: string): Uint8Array {
	return new TextEncoder().encode(s);
}

/** Sign a claims object as an HS256 JWT with `secret`. Deterministic given the same claims/secret. */
export async function signHS256(claims: Record<string, unknown>, secret: string): Promise<string> {
	const header = { alg: "HS256", typ: "JWT" };
	const headerSeg = base64url(utf8(JSON.stringify(header)));
	const claimsSeg = base64url(utf8(JSON.stringify(claims)));
	const signingInput = `${headerSeg}.${claimsSeg}`;

	const key = await crypto.subtle.importKey(
		"raw",
		utf8(secret),
		{ name: "HMAC", hash: "SHA-256" },
		false,
		["sign"],
	);
	const sig = await crypto.subtle.sign("HMAC", key, utf8(signingInput));
	return `${signingInput}.${base64url(new Uint8Array(sig))}`;
}
