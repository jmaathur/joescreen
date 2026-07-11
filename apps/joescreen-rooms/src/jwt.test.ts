import { describe, it, expect } from "vitest";
import { signHS256 } from "./jwt";
import { roomPresence } from "./presence";

// WebCrypto is available in Node 18+ (globalThis.crypto).

describe("signHS256", () => {
	it("produces a 3-segment base64url JWT with the expected header + claims", async () => {
		const jwt = await signHS256({ iss: "devkey", room: "demo" }, "secret");
		const parts = jwt.split(".");
		expect(parts).toHaveLength(3);
		// base64url: no +, /, or = padding.
		for (const p of parts) expect(p).not.toMatch(/[+/=]/);
		// Decode the header + claims.
		const dec = (s: string) => JSON.parse(Buffer.from(s.replace(/-/g, "+").replace(/_/g, "/"), "base64").toString());
		expect(dec(parts[0])).toEqual({ alg: "HS256", typ: "JWT" });
		expect(dec(parts[1])).toEqual({ iss: "devkey", room: "demo" });
	});

	it("is deterministic (same claims + secret → same token)", async () => {
		const a = await signHS256({ iss: "k", exp: 100 }, "s");
		const b = await signHS256({ iss: "k", exp: 100 }, "s");
		expect(a).toBe(b);
	});

	it("differs when the secret differs", async () => {
		const a = await signHS256({ iss: "k" }, "s1");
		const b = await signHS256({ iss: "k" }, "s2");
		expect(a).not.toBe(b);
	});
});

describe("roomPresence degradation", () => {
	it("returns count:null (not an error) when the RoomService is unconfigured", async () => {
		const p = await roomPresence({ apiUrl: "", apiKey: "", apiSecret: "", room: "demo", nowSeconds: 0 });
		expect(p.count).toBeNull();
	});

	it("returns count:null when the call fails, never throws", async () => {
		const p = await roomPresence({
			apiUrl: "https://sfu.example.com", apiKey: "k", apiSecret: "s", room: "demo", nowSeconds: 0,
			fetchImpl: async () => new Response("nope", { status: 500 }),
		});
		expect(p.count).toBeNull();
	});

	it("counts participants on a successful ListParticipants", async () => {
		const p = await roomPresence({
			apiUrl: "https://sfu.example.com", apiKey: "k", apiSecret: "s", room: "demo", nowSeconds: 0,
			fetchImpl: async () => new Response(JSON.stringify({ participants: [{}, {}, {}] }), { status: 200 }),
		});
		expect(p.count).toBe(3);
	});
});
