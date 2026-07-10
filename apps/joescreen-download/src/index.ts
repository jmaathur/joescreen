import { Hono } from "hono";
import { landingPage } from "./page";

type Bindings = {
	// Optional so the worker still deploys (and /download 404s gracefully) if the R2 binding
	// is ever removed — e.g. R2 disabled on the account (see docs/CLOUDFLARE_SETUP.md).
	DMG?: R2Bucket;
	DMG_KEY: string;
	APP_VERSION: string;
	ENVIRONMENT: string;
};

const app = new Hono<{ Bindings: Bindings }>();

// Landing page.
app.get("/", (c) => {
	return c.html(landingPage({ version: c.env.APP_VERSION }));
});

// Stream the notarized .dmg from R2. HEAD is supported so the page can show the size.
app.on(["GET", "HEAD"], "/download", async (c) => {
	const key = c.env.DMG_KEY || "JoeScreen.dmg";
	const object = c.env.DMG ? await c.env.DMG.get(key) : null;
	if (!object) {
		return c.text("Download not available yet — no build has been published.", 404);
	}
	const headers = new Headers();
	object.writeHttpMetadata(headers);
	headers.set("etag", object.httpEtag);
	headers.set("content-type", "application/x-apple-diskimage");
	headers.set("content-disposition", `attachment; filename="${key}"`);
	headers.set("content-length", String(object.size));
	// Immutable per build; a new build replaces the object, so cache briefly then revalidate.
	headers.set("cache-control", "public, max-age=300");
	if (c.req.method === "HEAD") {
		return new Response(null, { headers });
	}
	return new Response(object.body, { headers });
});

// Lightweight health/version endpoint (handy for the release script to verify a deploy).
app.get("/version", (c) => c.json({ version: c.env.APP_VERSION, env: c.env.ENVIRONMENT }));

export default app;
