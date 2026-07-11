import type { Release } from "./changelog";

function esc(s: string): string {
	return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}

/** Render the "What's new" version-history section from the release list (newest first). */
function changelogSection(releases: Release[]): string {
	if (releases.length === 0) return "";
	const fmtDate = (iso: string) => {
		const d = new Date(iso + "T00:00:00Z");
		return isNaN(d.getTime()) ? iso : d.toLocaleDateString("en-US", { year: "numeric", month: "short", day: "numeric", timeZone: "UTC" });
	};
	const entries = releases
		.map(
			(r) => `
      <li class="release">
        <div class="release-head">
          <span class="ver">v${esc(r.version)}</span>
          ${r.tag ? `<span class="badge">${esc(r.tag)}</span>` : ""}
          <span class="date">${esc(fmtDate(r.date))}</span>
        </div>
        <ul class="notes">
          ${r.highlights.map((h) => `<li>${esc(h)}</li>`).join("\n          ")}
        </ul>
      </li>`,
		)
		.join("\n");
	return `
    <section class="changelog" aria-label="Version history">
      <h2>What's new</h2>
      <ol class="releases">${entries}
      </ol>
    </section>`;
}

// The landing page HTML, inlined so the worker has no build step / asset pipeline.
export function landingPage(opts: { version: string; releases?: Release[]; testflightURL?: string }): string {
	const { version, releases = [], testflightURL } = opts;
	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>JoeScreen — shared desktops over a live call</title>
<meta name="description" content="JoeScreen for macOS: share individual app windows over a live call, with per-window cursors and voice. Download for macOS." />
<style>
  :root {
    --brand: #4c34cc;
    --brand-2: #6a4dff;
    --bg: #0e0e12;
    --panel: #17171d;
    --text: #f5f5f7;
    --muted: #a1a1aa;
    --border: rgba(255,255,255,0.09);
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: radial-gradient(1200px 600px at 50% -10%, rgba(106,77,255,0.18), transparent 60%), var(--bg);
    color: var(--text);
    -webkit-font-smoothing: antialiased;
    min-height: 100vh;
    display: flex;
    flex-direction: column;
  }
  .wrap { max-width: 720px; margin: 0 auto; padding: 64px 24px 48px; text-align: center; flex: 1; }
  .logo {
    width: 92px; height: 92px; border-radius: 22px;
    background: linear-gradient(160deg, var(--brand-2), var(--brand));
    display: grid; place-items: center; margin: 0 auto 28px;
    box-shadow: 0 12px 40px rgba(76,52,204,0.45);
  }
  .logo span { font-size: 58px; font-weight: 800; color: #fff; line-height: 1; margin-top: 4px; }
  h1 { font-size: 40px; line-height: 1.1; margin: 0 0 14px; letter-spacing: -0.02em; }
  .tagline { font-size: 18px; color: var(--muted); margin: 0 auto 36px; max-width: 520px; line-height: 1.5; }
  .cta {
    display: inline-flex; align-items: center; gap: 10px;
    background: linear-gradient(160deg, var(--brand-2), var(--brand));
    color: #fff; text-decoration: none; font-weight: 650; font-size: 17px;
    padding: 15px 28px; border-radius: 12px;
    box-shadow: 0 8px 28px rgba(76,52,204,0.45);
    transition: transform .12s ease, box-shadow .12s ease;
  }
  .cta:hover { transform: translateY(-1px); box-shadow: 0 12px 34px rgba(76,52,204,0.55); }
  .cta svg { width: 20px; height: 20px; }
  .cta-row { display: flex; gap: 12px; justify-content: center; align-items: center; flex-wrap: wrap; }
  .cta.secondary {
    background: transparent; color: var(--text);
    border: 1px solid var(--border); box-shadow: none; font-weight: 600;
  }
  .cta.secondary:hover { background: var(--panel); box-shadow: none; transform: translateY(-1px); }
  .meta { margin-top: 16px; color: var(--muted); font-size: 13px; }
  .meta code { color: var(--text); background: var(--panel); padding: 2px 7px; border-radius: 6px; border: 1px solid var(--border); }
  .features { margin: 56px auto 0; display: grid; grid-template-columns: 1fr; gap: 14px; text-align: left; max-width: 560px; }
  @media (min-width: 620px) { .features { grid-template-columns: 1fr 1fr; } }
  .feature { background: var(--panel); border: 1px solid var(--border); border-radius: 12px; padding: 18px 18px; }
  .feature h3 { margin: 0 0 6px; font-size: 15px; }
  .feature p { margin: 0; color: var(--muted); font-size: 13.5px; line-height: 1.5; }
  .steps { margin-top: 44px; color: var(--muted); font-size: 14px; line-height: 1.7; }
  .steps b { color: var(--text); }
  .changelog { margin: 56px auto 0; max-width: 560px; text-align: left; }
  .changelog h2 { font-size: 18px; margin: 0 0 16px; letter-spacing: -0.01em; }
  .releases { list-style: none; margin: 0; padding: 0; }
  .release { background: var(--panel); border: 1px solid var(--border); border-radius: 12px; padding: 16px 18px; margin-bottom: 12px; }
  .release-head { display: flex; align-items: center; gap: 10px; margin-bottom: 8px; flex-wrap: wrap; }
  .release-head .ver { font-weight: 700; font-size: 15px; }
  .release-head .badge { font-size: 11px; font-weight: 650; color: #fff; background: linear-gradient(160deg, var(--brand-2), var(--brand)); padding: 3px 9px; border-radius: 999px; letter-spacing: .02em; }
  .release-head .date { margin-left: auto; color: var(--muted); font-size: 12.5px; }
  .notes { margin: 0; padding-left: 18px; }
  .notes li { color: var(--muted); font-size: 13.5px; line-height: 1.6; margin: 3px 0; }
  footer { text-align: center; color: var(--muted); font-size: 12.5px; padding: 28px 24px 40px; border-top: 1px solid var(--border); }
  footer a { color: var(--muted); }
</style>
</head>
<body>
  <main class="wrap">
    <div class="logo"><span>J</span></div>
    <h1>JoeScreen</h1>
    <p class="tagline">Share individual app windows over a live call — each one appears on every desktop as a real, movable window, with per-window cursors and voice.</p>

    <div class="cta-row">
      <a class="cta" href="/download" download>
        <svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
          <path d="M12 3v12m0 0 4-4m-4 4-4-4M4 21h16" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
        </svg>
        Download for macOS
      </a>${testflightURL ? `
      <a class="cta secondary" href="${esc(testflightURL)}" target="_blank" rel="noopener">
        <svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
          <path d="M12 2 3 7v10l9 5 9-5V7l-9-5Z" stroke="currentColor" stroke-width="2" stroke-linejoin="round"/>
          <path d="M12 7v10M8.5 9.5 12 7l3.5 2.5" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
        </svg>
        iOS beta on TestFlight
      </a>` : ""}
    </div>
    <div class="meta">Version <code>${esc(version)}</code> · Apple Silicon &amp; Intel · macOS 14+ · notarized${testflightURL ? ` · iOS is a viewer + voice client` : ""}</div>

    <section class="features">
      <div class="feature"><h3>Real native windows</h3><p>Shared windows aren't a screenshare rectangle — they're live, movable windows on your desktop.</p></div>
      <div class="feature"><h3>Multiplayer cursors</h3><p>See everyone's pointer, per window, in real time.</p></div>
      <div class="feature"><h3>Click &amp; type in</h3><p>Interact with any shared window — routed back to the owner's Mac without stealing focus.</p></div>
      <div class="feature"><h3>Built-in voice</h3><p>Talk while you work, on the same live connection.</p></div>
    </section>
${changelogSection(releases)}
    <p class="steps">
      <b>To install:</b> open the downloaded <code>.dmg</code>, drag <b>JoeScreen</b> to Applications, and launch it.<br/>
      Grant <b>Screen&nbsp;Recording</b> (and <b>Accessibility</b> to control shared windows) when prompted.
    </p>
  </main>
  <footer>JoeScreen · a shared-desktop tool for macOS. Notarized by Apple — no security warnings on launch.</footer>
</body>
</html>`;
}
