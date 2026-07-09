// cheffing.dev hub page — lists the dev tools. Add a card to TOOLS as you ship each one.
type Tool = {
	name: string;
	blurb: string;
	href: string;
	badge: string; // e.g. "macOS", "coming soon"
	initial: string;
	live: boolean;
};

const TOOLS: Tool[] = [
	{
		name: "JoeScreen",
		blurb: "Share individual app windows over a live call — real, movable windows with cursors and voice.",
		href: "https://joescreen.cheffing.dev",
		badge: "macOS",
		initial: "J",
		live: true,
	},
	// Add future tools here — flip live:true and give them a subdomain.
	{
		name: "More soon",
		blurb: "More cheffing dev tools are on the way.",
		href: "#",
		badge: "coming soon",
		initial: "+",
		live: false,
	},
];

export function hubPage(): string {
	const cards = TOOLS.map((t) => {
		const tag = t.live ? "a" : "div";
		const href = t.live ? ` href="${t.href}"` : "";
		return `<${tag} class="card${t.live ? "" : " soon"}"${href}>
      <div class="badge-icon">${t.initial}</div>
      <div class="card-body">
        <div class="card-head"><h3>${t.name}</h3><span class="badge">${t.badge}</span></div>
        <p>${t.blurb}</p>
      </div>
    </${tag}>`;
	}).join("\n");

	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>cheffing — dev tools</title>
<meta name="description" content="A set of dev tools by cheffing." />
<style>
  :root { --accent:#6a4dff; --bg:#0c0c10; --panel:#16161c; --text:#f5f5f7; --muted:#a1a1aa; --border:rgba(255,255,255,0.09); }
  * { box-sizing:border-box; } html,body{margin:0;padding:0;}
  body { font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
    background:radial-gradient(1000px 500px at 50% -10%, rgba(106,77,255,0.15), transparent 60%), var(--bg);
    color:var(--text); -webkit-font-smoothing:antialiased; min-height:100vh; }
  .wrap { max-width:760px; margin:0 auto; padding:72px 24px 56px; }
  .mark { font-size:15px; letter-spacing:0.14em; text-transform:uppercase; color:var(--muted); text-align:center; margin-bottom:10px; }
  h1 { font-size:38px; letter-spacing:-0.02em; text-align:center; margin:0 0 10px; }
  .sub { text-align:center; color:var(--muted); font-size:17px; margin:0 auto 44px; max-width:460px; line-height:1.5; }
  .grid { display:grid; grid-template-columns:1fr; gap:14px; }
  @media (min-width:600px){ .grid { grid-template-columns:1fr 1fr; } }
  .card { display:flex; gap:14px; align-items:flex-start; text-decoration:none; color:inherit;
    background:var(--panel); border:1px solid var(--border); border-radius:14px; padding:18px; transition:transform .12s ease, border-color .12s ease; }
  a.card:hover { transform:translateY(-2px); border-color:rgba(106,77,255,0.6); }
  .card.soon { opacity:0.55; }
  .badge-icon { flex:0 0 auto; width:44px; height:44px; border-radius:11px; background:linear-gradient(160deg,#6a4dff,#4c34cc);
    display:grid; place-items:center; font-weight:800; font-size:22px; color:#fff; }
  .card-head { display:flex; align-items:center; gap:8px; margin-bottom:4px; }
  .card-head h3 { margin:0; font-size:16px; }
  .badge { font-size:11px; color:var(--muted); border:1px solid var(--border); border-radius:99px; padding:1px 8px; }
  .card p { margin:0; color:var(--muted); font-size:13.5px; line-height:1.5; }
  footer { text-align:center; color:var(--muted); font-size:12.5px; margin-top:48px; }
</style>
</head>
<body>
  <main class="wrap">
    <div class="mark">cheffing</div>
    <h1>Dev tools</h1>
    <p class="sub">A small set of tools for building software, by cheffing.</p>
    <div class="grid">
${cards}
    </div>
    <footer>cheffing.dev</footer>
  </main>
</body>
</html>`;
}
