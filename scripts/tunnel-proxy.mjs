// One-port reverse proxy so a SINGLE ngrok tunnel serves BOTH the token server and the LiveKit SFU
// for a Release/TestFlight build (which fetches a token over HTTP, then WebSockets to the SFU).
//
//   bun scripts/tunnel-proxy.mjs            # listen :9090, route /token→:8080, else→:7880
//   PROXY_PORT=9090 TOKEN_PORT=8080 SFU_PORT=7880 bun scripts/tunnel-proxy.mjs
//
// Then: ngrok http 9090  → point the app's server URL at the ngrok https URL. The token server must
// return that SAME ngrok URL as the SFU url (LIVEKIT_URL=wss://<ngrok-host>), so signaling comes back
// through this proxy and is routed to the SFU.
//
// Routing:
//   • /token[...]            → token server (plain HTTP)
//   • everything else        → SFU (LiveKit signaling lives at /rtc, /rtc/validate, etc.)
//   • WebSocket upgrades      → SFU (the /rtc signaling socket)
const PROXY_PORT = Number(process.env.PROXY_PORT || 9090);
const TOKEN = `http://127.0.0.1:${process.env.TOKEN_PORT || 8080}`;
const SFU = `http://127.0.0.1:${process.env.SFU_PORT || 7880}`;

// Bun's fetch upgrades ws automatically when we proxy the raw request; for LiveKit signaling we need
// to forward the WebSocket. We use a manual ws bridge for upgrade requests and plain fetch otherwise.
const server = Bun.serve({
	port: PROXY_PORT,
	async fetch(req, srv) {
		const url = new URL(req.url);
		const isToken = url.pathname === "/token" || url.pathname.startsWith("/token/");
		const upstreamBase = isToken ? TOKEN : SFU;

		// WebSocket upgrade (LiveKit /rtc signaling) → bridge to the SFU.
		if (req.headers.get("upgrade")?.toLowerCase() === "websocket") {
			if (srv.upgrade(req, { data: { target: url.pathname + url.search } })) return;
			return new Response("upgrade failed", { status: 500 });
		}

		// Plain HTTP → forward to the chosen upstream, preserving method/headers/body.
		const target = upstreamBase + url.pathname + url.search;
		const headers = new Headers(req.headers);
		headers.set("host", new URL(upstreamBase).host);
		const resp = await fetch(target, {
			method: req.method,
			headers,
			body: req.method === "GET" || req.method === "HEAD" ? undefined : req.body,
			redirect: "manual",
		}).catch((e) => new Response(`proxy error: ${e}`, { status: 502 }));
		return resp;
	},
	websocket: {
		// Bridge browser/app ↔ SFU WebSocket. `open` dials the SFU; messages relay both ways.
		open(ws) {
			const target = `ws://127.0.0.1:${process.env.SFU_PORT || 7880}${ws.data.target}`;
			const upstream = new WebSocket(target);
			ws.data.upstream = upstream;
			const q = [];
			ws.data.q = q;
			upstream.addEventListener("open", () => { for (const m of q) upstream.send(m); q.length = 0; });
			upstream.addEventListener("message", (e) => ws.send(e.data));
			upstream.addEventListener("close", (e) => { try { ws.close(e.code, e.reason); } catch {} });
			upstream.addEventListener("error", () => { try { ws.close(); } catch {} });
		},
		message(ws, msg) {
			const up = ws.data.upstream;
			if (up && up.readyState === 1) up.send(msg);
			else ws.data.q.push(msg);
		},
		close(ws) { try { ws.data.upstream?.close(); } catch {} },
	},
});

console.log(`tunnel-proxy on :${server.port}  →  /token → ${TOKEN}   else/ws → ${SFU}`);
