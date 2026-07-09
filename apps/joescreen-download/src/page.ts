// The landing page HTML, inlined so the worker has no build step / asset pipeline.
export function landingPage(opts: { version: string }): string {
	const { version } = opts;
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
  .meta { margin-top: 16px; color: var(--muted); font-size: 13px; }
  .meta code { color: var(--text); background: var(--panel); padding: 2px 7px; border-radius: 6px; border: 1px solid var(--border); }
  .features { margin: 56px auto 0; display: grid; grid-template-columns: 1fr; gap: 14px; text-align: left; max-width: 560px; }
  @media (min-width: 620px) { .features { grid-template-columns: 1fr 1fr; } }
  .feature { background: var(--panel); border: 1px solid var(--border); border-radius: 12px; padding: 18px 18px; }
  .feature h3 { margin: 0 0 6px; font-size: 15px; }
  .feature p { margin: 0; color: var(--muted); font-size: 13.5px; line-height: 1.5; }
  .steps { margin-top: 44px; color: var(--muted); font-size: 14px; line-height: 1.7; }
  .steps b { color: var(--text); }
  footer { text-align: center; color: var(--muted); font-size: 12.5px; padding: 28px 24px 40px; border-top: 1px solid var(--border); }
  footer a { color: var(--muted); }
</style>
</head>
<body>
  <main class="wrap">
    <div class="logo"><span>J</span></div>
    <h1>JoeScreen</h1>
    <p class="tagline">Share individual app windows over a live call — each one appears on every desktop as a real, movable window, with per-window cursors and voice.</p>

    <a class="cta" href="/download" download>
      <svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
        <path d="M12 3v12m0 0 4-4m-4 4-4-4M4 21h16" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
      </svg>
      Download for macOS
    </a>
    <div class="meta">Version <code>${version}</code> · Apple Silicon &amp; Intel · macOS 14+ · notarized</div>

    <section class="features">
      <div class="feature"><h3>Real native windows</h3><p>Shared windows aren't a screenshare rectangle — they're live, movable windows on your desktop.</p></div>
      <div class="feature"><h3>Multiplayer cursors</h3><p>See everyone's pointer, per window, in real time.</p></div>
      <div class="feature"><h3>Click &amp; type in</h3><p>Interact with any shared window — routed back to the owner's Mac without stealing focus.</p></div>
      <div class="feature"><h3>Built-in voice</h3><p>Talk while you work, on the same live connection.</p></div>
    </section>

    <p class="steps">
      <b>To install:</b> open the downloaded <code>.dmg</code>, drag <b>JoeScreen</b> to Applications, and launch it.<br/>
      Grant <b>Screen&nbsp;Recording</b> (and <b>Accessibility</b> to control shared windows) when prompted.
    </p>
  </main>
  <footer>JoeScreen · a shared-desktop tool for macOS. Notarized by Apple — no security warnings on launch.</footer>
</body>
</html>`;
}
