import { Hono } from "hono";
import { invitePage } from "./page";
import { roomPresence } from "./presence";
import { isValidSlug, makeSlug, normalizeCustomSlug, deepLink, type RoomRecord } from "./slug";

type Bindings = {
	ROOMS: KVNamespace;
	ENVIRONMENT: string;
	LIVEKIT_URL: string;
	LIVEKIT_API_URL: string;
	DOWNLOAD_URL: string;
	// Secrets (may be absent in dev → presence reports unknown).
	LIVEKIT_API_KEY?: string;
	LIVEKIT_API_SECRET?: string;
};

const app = new Hono<{ Bindings: Bindings }>();

// Health/version.
app.get("/", (c) => c.json({ service: "joescreen-rooms", env: c.env.ENVIRONMENT }));

// Create a room slug. Body: { room?, title?, slug? }. `room` defaults to the slug; a custom `slug`
// is normalized + checked for collisions. Returns { slug, url, deepLink }.
app.post("/rooms", async (c) => {
	const body = await c.req
		.json<{ room?: string; title?: string; slug?: string }>()
		.catch(() => ({}) as { room?: string; title?: string; slug?: string });
	let slug: string | null = null;

	if (body.slug) {
		slug = normalizeCustomSlug(body.slug);
		if (!slug) return c.json({ error: "invalid slug" }, 400);
		if (await c.env.ROOMS.get(slug)) return c.json({ error: "slug taken" }, 409);
	} else {
		// Random slug; retry on the rare collision.
		for (let i = 0; i < 5 && !slug; i++) {
			const candidate = makeSlug(crypto.getRandomValues(new Uint8Array(12)));
			if (!(await c.env.ROOMS.get(candidate))) slug = candidate;
		}
		if (!slug) return c.json({ error: "could not allocate slug" }, 500);
	}

	const record: RoomRecord = {
		room: (body.room && body.room.trim()) || slug,
		sfu: c.env.LIVEKIT_URL,
		title: body.title?.trim() || undefined,
		createdAt: Date.now(),
	};
	await c.env.ROOMS.put(slug, JSON.stringify(record));
	const origin = new URL(c.req.url).origin;
	return c.json({ slug, url: `${origin}/r/${slug}`, deepLink: deepLink(record) }, 201);
});

// JSON view of a room (for the app / integrations).
app.get("/api/rooms/:slug", async (c) => {
	const slug = c.req.param("slug");
	if (!isValidSlug(slug)) return c.json({ error: "invalid slug" }, 400);
	const raw = await c.env.ROOMS.get(slug);
	if (!raw) return c.json({ error: "not found" }, 404);
	const record = JSON.parse(raw) as RoomRecord;
	const presence = await roomPresence({
		apiUrl: c.env.LIVEKIT_API_URL,
		apiKey: c.env.LIVEKIT_API_KEY ?? "",
		apiSecret: c.env.LIVEKIT_API_SECRET ?? "",
		room: record.room,
		nowSeconds: Math.floor(Date.now() / 1000),
	});
	return c.json({ slug, room: record.room, sfu: record.sfu, title: record.title, presence, deepLink: deepLink(record) });
});

// The shareable invite landing page.
app.get("/r/:slug", async (c) => {
	const slug = c.req.param("slug");
	if (!isValidSlug(slug)) return c.text("Invalid room link.", 400);
	const raw = await c.env.ROOMS.get(slug);
	if (!raw) return c.html(`<!doctype html><meta charset=utf-8><title>Room not found</title><body style="font:16px system-ui;text-align:center;margin:20vh auto;max-width:30rem"><h1>Room not found</h1><p>This invite link isn't valid (or the room was removed). <a href="${c.env.DOWNLOAD_URL}">Get JoeScreen</a>.</p>`, 404);
	const record = JSON.parse(raw) as RoomRecord;
	const presence = await roomPresence({
		apiUrl: c.env.LIVEKIT_API_URL,
		apiKey: c.env.LIVEKIT_API_KEY ?? "",
		apiSecret: c.env.LIVEKIT_API_SECRET ?? "",
		room: record.room,
		nowSeconds: Math.floor(Date.now() / 1000),
	});
	const origin = new URL(c.req.url).origin;
	return c.html(invitePage({ slug, record, presenceCount: presence.count, downloadURL: c.env.DOWNLOAD_URL, origin }));
});

export default app;
