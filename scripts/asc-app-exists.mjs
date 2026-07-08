// Exit 0 if an App Store Connect app record exists for the given bundle id, else exit 1.
// Read-only; used by testflight-setup.sh to decide whether to invoke fastlane produce (which needs
// an interactive Apple ID login) — so re-runs don't prompt once the record exists.
//
//   bun scripts/asc-app-exists.mjs com.joescreen.app.ios
import { ascJwt, asc } from "./asc-jwt.mjs";

const bundleId = process.argv[2];
if (!bundleId) {
	console.error("usage: bun scripts/asc-app-exists.mjs <bundleId>");
	process.exit(2);
}

const token = ascJwt({
	keyPath: process.env.ASC_API_KEY_PATH,
	keyId: process.env.ASC_API_KEY_ID,
	issuerId: process.env.ASC_API_ISSUER_ID,
});

const res = await asc(
	token,
	"GET",
	`/v1/apps?filter[bundleId]=${encodeURIComponent(bundleId)}&limit=1`,
);
if (res.data?.length) {
	console.log(res.data[0].id);
	process.exit(0);
}
process.exit(1);
