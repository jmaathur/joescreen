// Mint a short-lived ES256 JWT for the App Store Connect API from a .p8 key.
// Exported for use by asc-provision.mjs; also runnable standalone to print a token:
//   bun scripts/asc-jwt.mjs <keyPath> <keyId> <issuerId>
import { readFileSync } from "node:fs";
import crypto from "node:crypto";

const b64u = (b) => Buffer.from(b).toString("base64url");

/** Sign an App Store Connect API JWT (valid ~19 min, the max ASC allows is 20). */
export function ascJwt({ keyPath, keyId, issuerId }) {
	const header = b64u(JSON.stringify({ alg: "ES256", kid: keyId, typ: "JWT" }));
	const now = Math.floor(Date.now() / 1000);
	const payload = b64u(
		JSON.stringify({ iss: issuerId, iat: now, exp: now + 19 * 60, aud: "appstoreconnect-v1" }),
	);
	const signer = crypto.createSign("SHA256");
	signer.update(`${header}.${payload}`);
	// ASC requires the raw ieee-p1363 (r||s) signature, not DER.
	const sig = signer.sign({ key: readFileSync(keyPath), dsaEncoding: "ieee-p1363" });
	return `${header}.${payload}.${b64u(sig)}`;
}

/** Thin fetch wrapper: signed GET/POST/PATCH against the ASC API, JSON in/out. */
export async function asc(token, method, path, body) {
	const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
		method,
		headers: {
			Authorization: `Bearer ${token}`,
			"Content-Type": "application/json",
		},
		body: body ? JSON.stringify(body) : undefined,
	});
	const text = await res.text();
	let json;
	try {
		json = text ? JSON.parse(text) : {};
	} catch {
		json = { raw: text };
	}
	if (!res.ok) {
		const detail = json?.errors?.map((e) => `${e.title}: ${e.detail}`).join("; ") || text;
		throw new Error(`ASC ${method} ${path} → ${res.status}: ${detail}`);
	}
	return json;
}

if (import.meta.main) {
	const [keyPath, keyId, issuerId] = process.argv.slice(2);
	if (!keyPath || !keyId || !issuerId) {
		console.error("usage: bun scripts/asc-jwt.mjs <keyPath> <keyId> <issuerId>");
		process.exit(1);
	}
	process.stdout.write(ascJwt({ keyPath, keyId, issuerId }));
}
