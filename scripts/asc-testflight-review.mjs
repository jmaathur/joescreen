// Submit JoeScreen's latest VALID build to TestFlight review + set up tester groups, via the ASC API.
// Adapted from golf-app's ensureDistributionLink (apps/builder-api/src/lib/apple-app-id.ts).
//
//   bun run testflight:review [ios|mac]
//
// Idempotent. Two kinds of TestFlight testing:
//   • INTERNAL (your team, ≤100): INSTANT, no review. Ensures an internal beta group + attaches the
//     latest VALID build. Add testers (App Store Connect users) in the ASC UI or via TESTFLIGHT env.
//   • EXTERNAL (public link, ≤10k): needs a one-time Beta App Review (~1 day). Ensures an external
//     group with a public link, fills the required Test Information, attaches the build, and submits
//     it for Beta App Review — but ONLY when TESTFLIGHT_SUBMIT_EXTERNAL=1 and a full review contact
//     is provided (Apple rejects the review without one).
//
// Env (from .env.testflight / shell): ASC_API_KEY_ID/ISSUER_ID/KEY_PATH (required).
//   Optional: TESTFLIGHT_GROUP (external group name, default "External Testers"),
//   TESTFLIGHT_SUBMIT_EXTERNAL=1, TESTFLIGHT_DESCRIPTION, TESTFLIGHT_FEEDBACK_EMAIL,
//   TESTFLIGHT_CONTACT_FIRST/LAST/PHONE/EMAIL.
import { ascJwt, asc } from "./asc-jwt.mjs";

const platform = (process.argv[2] || "ios").toLowerCase();
const BUNDLE = platform === "mac" ? "com.joescreen.app" : "com.joescreen.app.ios";

const token = ascJwt({
	keyPath: process.env.ASC_API_KEY_PATH,
	keyId: process.env.ASC_API_KEY_ID,
	issuerId: process.env.ASC_API_ISSUER_ID,
});

const log = (...a) => console.log("  ", ...a);
const step = (s) => console.log(`\n── ${s}`);

// Resolve the ASC app record id from the bundle id.
async function appId() {
	const r = await asc(token, "GET", `/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE)}&limit=1`);
	if (!r.data?.length) throw new Error(`no App Store Connect app record for ${BUNDLE} (create it first)`);
	return r.data[0].id;
}

// Latest build that finished ASC processing (VALID) — the only kind TestFlight can use.
async function latestValidBuild(id) {
	const r = await asc(token, "GET",
		`/v1/builds?filter[app]=${id}&filter[processingState]=VALID&sort=-version&limit=1`);
	return r.data?.[0]; // {id, attributes:{version}} or undefined
}

// Find or create a beta group (internal or external). External groups carry the public link.
async function ensureGroup(id, name, external) {
	const r = await asc(token, "GET", `/v1/betaGroups?filter[app]=${id}&limit=200`);
	const hit = (r.data ?? []).find((g) => g.attributes?.name === name);
	if (hit) {
		log(`✓ ${external ? "external" : "internal"} group "${name}" exists (${hit.id})`);
		return hit;
	}
	const attributes = external
		? { name, publicLinkEnabled: true }
		: { name, isInternalGroup: true };
	const created = await asc(token, "POST", "/v1/betaGroups", {
		data: { type: "betaGroups", attributes, relationships: { app: { data: { type: "apps", id } } } },
	});
	log(`＋ created ${external ? "external" : "internal"} group "${name}" (${created.data.id})`);
	return created.data;
}

// Attach a build to a group (idempotent — 409 = already attached).
async function attachBuild(groupId, buildId) {
	try {
		await asc(token, "POST", `/v1/betaGroups/${groupId}/relationships/builds`, {
			data: [{ type: "builds", id: buildId }],
		});
		log(`＋ attached build to group`);
	} catch (e) {
		if (String(e).includes("409")) { log("✓ build already attached"); return; }
		throw e;
	}
}

// Fill the Test Information Apple requires before an EXTERNAL review (description + feedback email),
// and the review contact (first/last/phone/email) — required for the first external review.
async function ensureBetaInfo(id) {
	const description = process.env.TESTFLIGHT_DESCRIPTION || "JoeScreen beta — screen sharing over a live call.";
	const feedbackEmail = process.env.TESTFLIGHT_FEEDBACK_EMAIL || process.env.TESTFLIGHT_CONTACT_EMAIL;
	const attrs = { description, ...(feedbackEmail ? { feedbackEmail } : {}) };

	const loc = await asc(token, "GET", `/v1/apps/${id}/betaAppLocalizations`);
	const locales = loc.data ?? [];
	if (locales.length === 0) {
		await asc(token, "POST", "/v1/betaAppLocalizations", {
			data: { type: "betaAppLocalizations", attributes: { ...attrs, locale: "en-US" },
				relationships: { app: { data: { type: "apps", id } } } },
		});
		log("＋ set beta app description (en-US)");
	} else {
		for (const l of locales) {
			await asc(token, "PATCH", `/v1/betaAppLocalizations/${l.id}`, {
				data: { type: "betaAppLocalizations", id: l.id, attributes: attrs },
			});
		}
		log("✓ beta app description updated");
	}

	const full = process.env.TESTFLIGHT_CONTACT_FIRST && process.env.TESTFLIGHT_CONTACT_LAST &&
		process.env.TESTFLIGHT_CONTACT_PHONE && process.env.TESTFLIGHT_CONTACT_EMAIL;
	if (!full) {
		log("⚠ no full review contact (TESTFLIGHT_CONTACT_FIRST/LAST/PHONE/EMAIL) — external review submit will be skipped");
		return false;
	}
	const det = await asc(token, "GET", `/v1/apps/${id}/betaAppReviewDetail`);
	if (det.data) {
		await asc(token, "PATCH", `/v1/betaAppReviewDetails/${det.data.id}`, {
			data: { type: "betaAppReviewDetails", id: det.data.id, attributes: {
				demoAccountRequired: false,
				contactFirstName: process.env.TESTFLIGHT_CONTACT_FIRST,
				contactLastName: process.env.TESTFLIGHT_CONTACT_LAST,
				contactPhone: process.env.TESTFLIGHT_CONTACT_PHONE,
				contactEmail: process.env.TESTFLIGHT_CONTACT_EMAIL,
			} },
		}).catch((e) => { if (!String(e).includes("409")) throw e; });
		log("✓ review contact set");
	}
	return true;
}

// Submit a build for external Beta App Review (idempotent).
async function submitReview(buildId) {
	const existing = await asc(token, "GET", `/v1/builds/${buildId}/betaAppReviewSubmission`).catch(() => ({}));
	if (existing.data) return existing.data.attributes?.betaReviewState ?? "SUBMITTED";
	try {
		const r = await asc(token, "POST", "/v1/betaAppReviewSubmissions", {
			data: { type: "betaAppReviewSubmissions", relationships: { build: { data: { type: "builds", id: buildId } } } },
		});
		return r.data?.attributes?.betaReviewState ?? "WAITING_FOR_REVIEW";
	} catch (e) {
		const s = String(e);
		if (s.includes("409")) return "WAITING_FOR_REVIEW";
		if (s.includes("ANOTHER_BUILD_IN_REVIEW")) return "ANOTHER_BUILD_IN_REVIEW";
		throw e;
	}
}

// ── run ───────────────────────────────────────────────────────────────────────
console.log(`TestFlight review setup for ${BUNDLE}`);
const id = await appId();
log(`app record: ${id}`);

const build = await latestValidBuild(id);
if (!build) {
	console.error("\n✖ no VALID (processed) build found. Upload one first (bun run testflight " + platform + "),\n  then wait a few minutes for ASC processing and re-run.");
	process.exit(1);
}
log(`latest VALID build: ${build.attributes?.version} (${build.id})`);

// Internal testing — instant, no review.
step("Internal testing (instant, no review)");
const internal = await ensureGroup(id, process.env.TESTFLIGHT_INTERNAL_GROUP || "Internal Testers", false);
await attachBuild(internal.id, build.id);
log("→ add internal testers in App Store Connect → TestFlight → this group (they install immediately)");

// External testing — needs Beta App Review.
step("External testing (public link, needs Beta App Review)");
const external = await ensureGroup(id, process.env.TESTFLIGHT_GROUP || "External Testers", true);
await attachBuild(external.id, build.id);
const link = external.attributes?.publicLink;
if (link) log(`public link: ${link}`);

if (process.env.TESTFLIGHT_SUBMIT_EXTERNAL === "1") {
	const haveContact = await ensureBetaInfo(id);
	if (haveContact) {
		const state = await submitReview(build.id);
		log(`✓ submitted build ${build.attributes?.version} for Beta App Review → state: ${state}`);
		log("  (external testers can install once Apple approves it, ~1 day the first time.)");
	}
} else {
	await ensureBetaInfo(id); // fill description at least
	log("ℹ external review NOT submitted (set TESTFLIGHT_SUBMIT_EXTERNAL=1 + review contact to submit).");
}

console.log("\n✓ done.");
