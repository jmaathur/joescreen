// Provision JoeScreen's App Store Connect / Developer-portal identifiers via the ASC API.
// IDEMPOTENT: every step lists-before-creating, so re-running is safe and only fills gaps.
//
//   bun scripts/asc-provision.mjs [--dry-run]
//
// Reads creds from env (APPLE_TEAM_ID, ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_PATH),
// which scripts/testflight-setup.sh loads from .env.testflight.
//
// What it does (all safe / repeatable, via the official ASC API):
//   1. Register bundle IDs   com.joescreen.app.ios (IOS) and com.joescreen.app (MAC_OS)
//   2. Create App Store Connect app records for both (if missing)
//
// What it does NOT do (Apple exposes no ASC-API path):
//   • App Group creation — the ASC API has NO /v1/appGroups endpoint. Use `fastlane produce group`
//     (legacy portal API) or the portal UI. NOTE: the App Group is only needed by the future
//     ReplayKit broadcast extension; the iOS viewer+voice build signs/uploads WITHOUT it, so it does
//     NOT block the first TestFlight. Printed as a (non-blocking) manual TODO.
//   • SharePlay / Group Activities (com.apple.developer.group-session) — a MANAGED capability
//     requiring manual Apple approval. Not settable via API. Printed as a manual TODO.
import { ascJwt, asc } from "./asc-jwt.mjs";

const DRY = process.argv.includes("--dry-run");

const IOS_BUNDLE = "com.joescreen.app.ios";
const MAC_BUNDLE = "com.joescreen.app";
const APP_GROUP = "group.com.joescreen.app";

const cred = {
	keyPath: process.env.ASC_API_KEY_PATH,
	keyId: process.env.ASC_API_KEY_ID,
	issuerId: process.env.ASC_API_ISSUER_ID,
};
for (const [k, v] of Object.entries(cred)) {
	if (!v) {
		console.error(`✖ missing credential ${k} (set it in .env.testflight)`);
		process.exit(1);
	}
}
const token = ascJwt(cred);

const log = (...a) => console.log("  ", ...a);
const step = (s) => console.log(`\n── ${s}`);

// ── bundle IDs ──────────────────────────────────────────────────────────────
async function ensureBundleId(identifier, name, platform) {
	// Apple's filter[identifier] is a PREFIX/substring match (com.joescreen.app matches
	// com.joescreen.app.ios), so fetch candidates and require an EXACT identifier match.
	const existing = await asc(
		token,
		"GET",
		`/v1/bundleIds?filter[identifier]=${encodeURIComponent(identifier)}&limit=50`,
	);
	const exact = existing.data?.find((b) => b.attributes?.identifier === identifier);
	if (exact) {
		log(`✓ bundle id exists: ${identifier} (${exact.id})`);
		return exact.id;
	}
	if (DRY) {
		log(`[dry-run] would register bundle id: ${identifier} (${platform})`);
		return null;
	}
	const created = await asc(token, "POST", "/v1/bundleIds", {
		data: { type: "bundleIds", attributes: { identifier, name, platform, seedId: process.env.APPLE_TEAM_ID } },
	});
	log(`＋ registered bundle id: ${identifier} (${created.data.id})`);
	return created.data.id;
}

// ── App Store Connect app record ─────────────────────────────────────────────
async function ensureAppRecord(bundleIdRecordId, bundleIdentifier, platform, name) {
	const existing = await asc(
		token,
		"GET",
		`/v1/apps?filter[bundleId]=${encodeURIComponent(bundleIdentifier)}&limit=1`,
	);
	if (existing.data?.length) {
		log(`✓ ASC app record exists: ${bundleIdentifier} (${existing.data[0].id})`);
		return existing.data[0].id;
	}
	if (DRY || !bundleIdRecordId) {
		log(`[dry-run] would create ASC app record for ${bundleIdentifier}`);
		return null;
	}
	// Creating an app record via API requires a primary locale + the bundleId relationship + a SKU.
	// Some ASC accounts restrict app creation to the UI — if this 403s, fall back to a manual note.
	try {
		const created = await asc(token, "POST", "/v1/apps", {
			data: {
				type: "apps",
				attributes: {
					bundleId: bundleIdentifier,
					name,
					primaryLocale: "en-US",
					sku: bundleIdentifier,
					platforms: [platform === "MAC_OS" ? "MAC_OS" : "IOS"],
				},
				relationships: { bundleId: { data: { type: "bundleIds", id: bundleIdRecordId } } },
			},
		});
		log(`＋ created ASC app record: ${bundleIdentifier} (${created.data.id})`);
		return created.data.id;
	} catch (e) {
		log(`⚠ could not auto-create ASC app record for ${bundleIdentifier}: ${e.message}`);
		log(`  → create it manually: App Store Connect → Apps → + → New App (bundle ${bundleIdentifier})`);
		return null;
	}
}

// ── run ──────────────────────────────────────────────────────────────────────
console.log(`App Store Connect provisioning${DRY ? " (DRY RUN — no writes)" : ""}`);
console.log(`  team: ${process.env.APPLE_TEAM_ID}`);

step("Bundle IDs");
const iosId = await ensureBundleId(IOS_BUNDLE, "JoeScreen iOS", "IOS");
const macId = await ensureBundleId(MAC_BUNDLE, "JoeScreen macOS", "MAC_OS");

step("App Store Connect app records");
await ensureAppRecord(iosId, IOS_BUNDLE, "IOS", "JoeScreen");
await ensureAppRecord(macId, MAC_BUNDLE, "MAC_OS", "JoeScreen");

step("Manual steps that CANNOT be automated via the ASC API");
console.log(
	`  1. App Group "${APP_GROUP}" — the ASC API has no endpoint for App Groups. It is only needed\n` +
		"     by the (not-yet-built) ReplayKit broadcast extension, so it does NOT block the iOS\n" +
		"     TestFlight build. When you need it, run:  fastlane produce group -g " + APP_GROUP + " -n \"JoeScreen App Group\"\n" +
		"     (fastlane uses the legacy portal API; it may prompt for your Apple ID + 2FA), or add it\n" +
		"     in the developer portal → Identifiers → App Groups, then enable App Groups on both App IDs.\n" +
		"  2. SharePlay (Group Activities / com.apple.developer.group-session) — a MANAGED capability\n" +
		"     requiring Apple approval; no API. Request it for BOTH App IDs. TestFlight build/install\n" +
		"     works without it; only SharePlay session-start is gated on approval.",
);
console.log(`\n${DRY ? "Dry run complete — re-run without --dry-run to apply." : "✓ Provisioning complete."}`);
