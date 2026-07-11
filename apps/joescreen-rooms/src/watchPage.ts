function esc(s: string): string {
	return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}

/**
 * The view-only browser watch page (backlog #8). Uses `livekit-client` (CDN) with a subscribe-only
 * token to render the room's window:/display: SHARE tracks (camera tracks ignored for now). The
 * SDK's element-size-driven adaptiveStream holds R24/R32 automatically. Renders each share as a
 * `<video>`; a track that goes away removes its tile. No publish path — view-only.
 */
export function watchPage(opts: { slug: string; room: string; sfu: string; token: string }): string {
	const { slug, room, sfu, token } = opts;
	// The token/sfu/room are injected as a JSON blob the inline script reads (no eval, no leakage
	// beyond this page which the viewer already loaded).
	const config = JSON.stringify({ sfu, token, room });
	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Watching “${esc(slug)}” · JoeScreen</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; background: #0b0b0d; color: #eee; font: 14px/1.5 system-ui, sans-serif; }
  header { padding: .6rem 1rem; display: flex; gap: .6rem; align-items: center; border-bottom: 1px solid #222; }
  header .dot { width: 8px; height: 8px; border-radius: 50%; background: #f59e0b; }
  header .dot.live { background: #22c55e; }
  #grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 10px; padding: 10px; }
  .tile { background: #000; border: 1px solid #222; border-radius: 8px; overflow: hidden; }
  .tile video { width: 100%; height: auto; display: block; background: #000; }
  .tile .cap { padding: 4px 8px; font-size: 12px; color: #aaa; }
  #empty { padding: 2rem; text-align: center; color: #888; }
</style>
</head>
<body>
<header><span class="dot" id="status"></span><strong>${esc(room)}</strong><span style="color:#888">· view-only</span></header>
<div id="empty">Connecting…</div>
<div id="grid"></div>
<script type="module">
  import { Room, RoomEvent, Track } from "https://cdn.jsdelivr.net/npm/livekit-client@2/dist/livekit-client.esm.mjs";
  const cfg = ${config};
  const grid = document.getElementById("grid");
  const empty = document.getElementById("empty");
  const statusDot = document.getElementById("status");
  const tiles = new Map(); // trackSid -> element

  function isShareName(name) {
    return /^(window|display):/.test(name || "");
  }
  function refreshEmpty() {
    empty.style.display = tiles.size ? "none" : "block";
    if (!tiles.size) empty.textContent = "No windows are being shared yet.";
  }

  // R24/R32: adaptiveStream is element-size-driven in the browser SDK, so an attached (visible)
  // <video> is what makes the SFU forward frames — exactly what a native SwiftUIVideoView does.
  const room = new Room({ adaptiveStream: true, dynacast: true });

  room.on(RoomEvent.TrackSubscribed, (track, pub, participant) => {
    if (track.kind !== Track.Kind.Video || !isShareName(pub.trackName)) return;
    const tile = document.createElement("div");
    tile.className = "tile";
    const el = track.attach();
    const cap = document.createElement("div");
    cap.className = "cap";
    cap.textContent = (participant.name || participant.identity?.slice(0, 4) || "peer") + " · " + pub.trackName.split(":")[0];
    tile.appendChild(el);
    tile.appendChild(cap);
    grid.appendChild(tile);
    tiles.set(pub.trackSid, tile);
    refreshEmpty();
  });
  room.on(RoomEvent.TrackUnsubscribed, (track, pub) => {
    const tile = tiles.get(pub.trackSid);
    if (tile) { track.detach(); tile.remove(); tiles.delete(pub.trackSid); refreshEmpty(); }
  });
  room.on(RoomEvent.Disconnected, () => { statusDot.classList.remove("live"); });
  room.on(RoomEvent.Connected, () => { statusDot.classList.add("live"); refreshEmpty(); });

  room.connect(cfg.sfu, cfg.token).catch((e) => { empty.textContent = "Couldn't connect: " + e; });
</script>
</body>
</html>`;
}
