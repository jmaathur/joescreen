import type { RoomRecord } from "./slug";
import { deepLink } from "./slug";

function esc(s: string): string {
	return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}

/**
 * The /r/<slug> landing page: OpenGraph tags for a rich Slack/iMessage unfurl, a "Join in JoeScreen"
 * button that fires the joescreen:// deep link, and a download fallback for anyone without the app.
 * A tiny script attempts the deep link immediately and shows the fallback if the app doesn't grab it.
 */
export function invitePage(opts: {
	slug: string;
	record: RoomRecord;
	presenceCount: number | null;
	downloadURL: string;
	origin: string;
}): string {
	const { slug, record, presenceCount, downloadURL, origin } = opts;
	const link = deepLink(record);
	const title = record.title || `Join room “${slug}” on JoeScreen`;
	const presenceText =
		presenceCount === null ? "" : presenceCount === 0 ? "No one here yet — be the first." : `${presenceCount} ${presenceCount === 1 ? "person" : "people"} in the room now.`;
	const canonical = `${origin}/r/${slug}`;

	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<link rel="canonical" href="${esc(canonical)}">
<meta property="og:type" content="website">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="Screen-share and collaborate live in JoeScreen. ${esc(presenceText)}">
<meta property="og:url" content="${esc(canonical)}">
<meta name="twitter:card" content="summary">
<style>
  :root { color-scheme: light dark; }
  body { font: 16px/1.5 -apple-system, system-ui, sans-serif; max-width: 34rem; margin: 12vh auto; padding: 0 1.25rem; text-align: center; }
  h1 { font-size: 1.6rem; margin-bottom: .25rem; }
  .slug { font-family: ui-monospace, monospace; opacity: .7; }
  .presence { margin: 1rem 0; opacity: .8; }
  .btn { display: inline-block; margin: .5rem; padding: .7rem 1.4rem; border-radius: .6rem; text-decoration: none; font-weight: 600; }
  .primary { background: #2563eb; color: #fff; }
  .secondary { border: 1px solid currentColor; opacity: .8; }
  .fallback { margin-top: 2rem; font-size: .9rem; opacity: .7; }
</style>
</head>
<body>
  <h1>${esc(record.title || "Join on JoeScreen")}</h1>
  <div class="slug">room · ${esc(slug)}</div>
  <p class="presence">${esc(presenceText)}</p>
  <a class="btn primary" id="join" href="${esc(link)}">Join in JoeScreen</a>
  <a class="btn secondary" href="${esc(`${origin}/watch/${slug}`)}">Watch in browser</a>
  <a class="btn secondary" href="${esc(downloadURL)}">Get JoeScreen</a>
  <p class="fallback">Don't have the app? <a href="${esc(downloadURL)}">Download it</a>, then reopen this link.</p>
  <script>
    // Fire the deep link on load; if the app grabs it the page is backgrounded, otherwise the
    // buttons remain. (No auto-redirect to download — that would be jarring if the app IS installed.)
    (function () {
      try { window.location.href = ${JSON.stringify(link)}; } catch (e) {}
    })();
  </script>
</body>
</html>`;
}
