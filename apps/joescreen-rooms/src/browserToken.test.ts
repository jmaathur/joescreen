import { describe, it, expect } from "vitest";
import { mintViewOnlyToken } from "./browserToken";

function decodeClaims(jwt: string): any {
	const seg = jwt.split(".")[1];
	return JSON.parse(Buffer.from(seg.replace(/-/g, "+").replace(/_/g, "/"), "base64").toString());
}

describe("mintViewOnlyToken", () => {
	it("mints a subscribe-only grant — no publish, no data publish", async () => {
		const jwt = await mintViewOnlyToken({
			apiKey: "devkey", apiSecret: "secret", room: "demo", identity: "web-1", nowSeconds: 1000,
		});
		const claims = decodeClaims(jwt);
		expect(claims.video.roomJoin).toBe(true);
		expect(claims.video.canSubscribe).toBe(true);
		expect(claims.video.canPublish).toBe(false); // view-only
		expect(claims.video.canPublishData).toBe(false); // no cursor/input from the browser
		expect(claims.video.room).toBe("demo");
		expect(claims.sub).toBe("web-1");
	});

	it("sets nbf/exp from the injected clock + ttl", async () => {
		const jwt = await mintViewOnlyToken({
			apiKey: "k", apiSecret: "s", room: "r", identity: "web-2", nowSeconds: 5000, ttlSeconds: 60,
		});
		const claims = decodeClaims(jwt);
		expect(claims.nbf).toBe(5000);
		expect(claims.exp).toBe(5060);
	});

	it("includes a name claim when provided", async () => {
		const jwt = await mintViewOnlyToken({
			apiKey: "k", apiSecret: "s", room: "r", identity: "web-3", name: "Watcher", nowSeconds: 0,
		});
		expect(decodeClaims(jwt).name).toBe("Watcher");
	});
});
