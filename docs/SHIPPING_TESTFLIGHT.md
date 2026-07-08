# Shipping JoeScreen to TestFlight

A plan to get the **macOS** and **iOS** apps onto TestFlight. Researched against the current
codebase (`apps/joescreen/Apps/project.yml`, the two `.entitlements` files, `DECISIONS.md` D6/D11/D14,
`RISKS.md` R2/R4/R5/R6) and Apple's current TestFlight rules (DTS forum threads 733942 / 698208).

---

## TL;DR

- **Both targets can ship to TestFlight.** The macOS app being **non-sandboxed is NOT a blocker** —
  App Sandbox is required for the *Mac App Store release*, **not** for TestFlight. TestFlight needs an
  **App Store distribution provisioning profile + a restricted entitlement + App Store signing**, all
  of which a non-sandboxed app can have. (This corrects the repo's own docs, which assume macOS ships
  only as notarized Developer-ID *outside* the store — that was a distribution *choice*, not a
  TestFlight limitation.)
- **The critical path is Apple approvals, not code.** SharePlay's `com.apple.developer.group-session`
  is a **managed capability requiring Apple approval** (days–weeks, Apple-controlled). Request it on
  day 1; everything else can proceed in parallel.
- **iOS is the fastest, lowest-risk first ship.** It's already sandboxed, self-contained, viewer+voice
  only, builds today. macOS follows once signing + the group-session approval land.
- **~10 concrete config blockers** exist in `project.yml` / entitlements (below). All are
  agent-fixable except the ones needing a real Team ID / Apple approval / a human at App Store Connect.

---

## The one fact that changes everything

> **TestFlight does NOT require the App Sandbox.** (Apple DTS, forum/thread/733942.)
> "Your Mac App Store apps must be signed with the App Sandbox Entitlement… However, to submit an app
> to TestFlight, it must have a provisioning profile." App Store *release* ⇒ sandbox. TestFlight ⇒
> provisioning profile + a **restricted entitlement** to force the profile to embed.

JoeScreen already declares a restricted entitlement (`com.apple.developer.group-session`), so the
profile-embedding requirement is naturally satisfied on macOS once real signing is turned on. The
non-sandboxed design (needed for future CGEvent input injection, D6) stays intact on TestFlight.

Consequence: **we do NOT need a sandboxed "viewer-only" macOS variant to reach TestFlight.** (We would
only need that for a Mac *App Store* public release — out of scope here.)

---

## Prerequisites (human / account — cannot be automated)

1. **Apple Developer Program membership** (paid, $99/yr) with an **App Manager/Admin** role.
2. A **Team ID** (10-char, e.g. `ABCDE12345`). Feeds `TEAM_ID` env → `DEVELOPMENT_TEAM`.
3. **Two App IDs** registered in Certificates, Identifiers & Profiles:
   - `com.joescreen.app` (macOS) and `com.joescreen.app.ios` (iOS). ← match current bundle IDs.
   - Enable the **SharePlay (Group Activities)** capability on both.
   - Register the **App Group** `group.com.joescreen.app` and enable it on both App IDs.
4. **App Store Connect app records** for both bundle IDs (name, primary language, category, privacy).
5. **Signing assets** — simplest is **Xcode-managed (Automatic) signing** with an App-Manager Apple ID;
   otherwise manually create an *App Store distribution* cert + *App Store* provisioning profiles for
   both App IDs (with the group-session + app-group entitlements).
6. **App Store Connect API key** (`.p8` + Key ID + Issuer ID) for headless `xcrun altool`/`notarytool`
   uploads from CI. Store as secrets; never commit.

### Apple-approval gates (start these FIRST — they're the long pole)

- **`com.apple.developer.group-session` (SharePlay)** — a **managed capability requiring Apple
  approval** before it appears in a provisioning profile (verified: developer.apple.com docs +
  forum). Request via the developer account capability form on **day 1**. Until approved, SharePlay
  won't function and macOS profiles can't include it.
- **`com.apple.developer.persistent-content-capture`** (macOS 14.4+, RISKS R5) — Apple-approval form,
  Apple-controlled timeline. **NOT needed for TestFlight** (the app functions without it; it only
  removes the R4 recurring screen-recording prompt). Request early but it does **not** block shipping.

---

## Current config blockers (in `apps/joescreen/Apps/project.yml` + entitlements)

| # | Blocker | Where | Fix (who) |
|---|---------|-------|-----------|
| 1 | `TEAM_ID` unset → `DEVELOPMENT_TEAM` empty, ad-hoc `CODE_SIGN_IDENTITY: "-"` | project.yml base | set real `TEAM_ID` (human) |
| 2 | iOS `CODE_SIGNING_ALLOWED: "NO"` / `REQUIRED: "NO"` — signing OFF | project.yml iOS target | flip to YES for release (agent) |
| 3 | `CODE_SIGN_STYLE: Manual`, **no provisioning profile** anywhere | project.yml | switch release config to Automatic **or** add App Store profiles (agent + human assets) |
| 4 | App Group is placeholder `group.com.example.joescreen`; **no app-group entitlement** on any target | `Sources/JoeScreenBridge/AppGroupConstants.swift` + entitlements | change to `group.com.joescreen.app`, add entitlement (agent) |
| 5 | **No iOS entitlements file** — `NSSupportsGroupActivities` declared but no backing `group-session` entitlement | Apps/iOS/Resources | create `JoeScreen-iOS.entitlements`, wire `CODE_SIGN_ENTITLEMENTS` (agent) |
| 6 | `ITSAppUsesNonExemptEncryption` absent → manual export-compliance prompt every upload | both info blocks | add `false` (uses only exempt HTTPS/WebRTC TLS) (agent) |
| 7 | `LSApplicationCategoryType` absent | both info blocks | add (e.g. `public.app-category.productivity`) (agent) |
| 8 | macOS TestFlight needs a **restricted entitlement to embed the profile** | macOS entitlements | already satisfied by `group-session` in `-team` file; wire it for the release config (agent) |
| 9 | No version/build-number automation; hardcoded `0.1.0 (1)` in two places/target | project.yml | add a bump step in the ship script (agent) |
| 10 | No archive/export/upload tooling, no CI, no `ExportOptions.plist` | scripts/ , .github/ | build it (agent) |

Note: the **broadcast extension target doesn't exist** (empty `Apps/BroadcastExtension/`). iOS ships
**viewer+voice only without it** — the extension is only for iOS *screen-sharing out*, a later phase.
Do NOT block the first TestFlight on it.

---

## Plan of record

### Phase 0 — Kick off Apple approvals (day 1, human)
Request the **group-session** managed capability and (optionally) **persistent-content-capture**.
Register App IDs + App Group + App Store Connect records. This clock runs while we do everything else.

### Phase 1 — Ship **iOS** to TestFlight first (fastest path)
iOS is sandboxed, self-contained (transitively links only an empty-on-iOS capture module; never links
`JoeScreenInputMac`), and builds today. Agent-doable config, then a human upload (or CI):

1. **project.yml (iOS release):** flip `CODE_SIGNING_ALLOWED/REQUIRED` to YES; set `CODE_SIGN_STYLE:
   Automatic` (or wire an App Store profile); add `CODE_SIGN_ENTITLEMENTS: iOS/Resources/JoeScreen-iOS.entitlements`.
2. **New `JoeScreen-iOS.entitlements`:** `com.apple.developer.group-session`,
   `com.apple.security.application-groups = [group.com.joescreen.app]`,
   plus `com.apple.application-identifier` / `com.apple.developer.team-identifier` (auto via profile).
3. **Info additions (iOS):** `ITSAppUsesNonExemptEncryption=false`, `LSApplicationCategoryType`.
4. **App Group:** replace the placeholder in `AppGroupConstants.swift` with `group.com.joescreen.app`.
5. **Archive + export + upload:**
   ```
   xcodebuild -project Apps/JoeScreen.xcodeproj -scheme JoeScreen-iOS \
     -sdk iphoneos -configuration Release -archivePath build/JoeScreen-iOS.xcarchive archive
   xcodebuild -exportArchive -archivePath build/JoeScreen-iOS.xcarchive \
     -exportOptionsPlist ExportOptions-appstore.plist -exportPath build/export-ios
   xcrun altool --upload-app -f build/export-ios/JoeScreen.ipa -t ios \
     --apiKey $ASC_KEY_ID --apiIssuer $ASC_ISSUER_ID
   ```
   (or `xcrun notarytool`/Transporter). Needs the ASC API key + real signing assets.
6. **App Store Connect:** fill TestFlight test info, add internal testers, submit external build for
   Beta App Review if using external testers.

**Gate:** SharePlay won't work on iOS until group-session is approved — but the viewer/voice/join flow
does. You can ship an internal TestFlight build for join+view+voice validation *before* approval, then
re-ship once SharePlay lights up.

### Phase 2 — Ship **macOS** to TestFlight
Once the group-session capability is approved and an App Store distribution profile for
`com.joescreen.app` exists (with group-session + app-group), the non-sandboxed app is TestFlight-eligible:

1. **project.yml (macOS release config):** set `DEVELOPMENT_TEAM`, real App Store signing
   (`CODE_SIGN_STYLE: Automatic` or explicit profile), `CODE_SIGNING_REQUIRED: YES`, wire the
   `-team` entitlements file (which carries the restricted `group-session` that embeds the profile).
   Keep `ENABLE_APP_SANDBOX: NO` and `ENABLE_HARDENED_RUNTIME: YES` (both fine for TestFlight).
2. **Add app-group entitlement** to the macOS entitlements file; add `ITSAppUsesNonExemptEncryption`,
   `LSApplicationCategoryType`.
3. **Archive + export (macOS App Store):**
   ```
   xcodebuild -project Apps/JoeScreen.xcodeproj -scheme JoeScreen-macOS \
     -configuration Release -archivePath build/JoeScreen-macOS.xcarchive archive
   xcodebuild -exportArchive -archivePath build/JoeScreen-macOS.xcarchive \
     -exportOptionsPlist ExportOptions-macos-appstore.plist -exportPath build/export-mac
   xcrun altool --upload-app -f build/export-mac/JoeScreen.pkg -t macos \
     --apiKey $ASC_KEY_ID --apiIssuer $ASC_ISSUER_ID
   ```
   `ExportOptions` uses `method: app-store-connect`, `signingStyle`, the Team ID, and the profile map.
4. TestFlight review + internal/external testers, same as iOS.

**AMFI note:** the repo's empty-entitlements default exists to avoid a `Killed: 9` on ad-hoc builds
carrying a restricted entitlement without a profile. That failure mode **disappears once a real App
Store profile is embedded** — the profile authorizes the restricted entitlement. So the `-team` file
is correct for the signed release path.

### Phase 3 — Automate (turn the runbook into `bun run ship:*`)
Add to the monorepo:
- `scripts/ship-ios.sh` / `scripts/ship-macos.sh` — archive → export → upload, reading `TEAM_ID` and
  `ASC_*` from env; auto-bump `CURRENT_PROJECT_VERSION` (build number) before archive.
- `ExportOptions-appstore.plist` (iOS) + `ExportOptions-macos-appstore.plist`.
- Root `package.json` scripts: `"ship:ios"`, `"ship:mac"`; optional `.github/workflows/testflight.yml`
  gated on a tag, using the ASC API key secret.
- A single build-number source of truth (bump script) so `0.1.0 (N)` increments per upload.

---

## What I (agent) can do now vs. what needs you

**Agent-doable immediately** (no account access), on a branch, verified by building:
- All `project.yml` release-config edits (signing flags, entitlements wiring, info keys).
- Create `JoeScreen-iOS.entitlements`; add app-group + encryption + category keys.
- Replace the placeholder App Group id.
- Write `ExportOptions*.plist`, `scripts/ship-*.sh`, build-number bump, `package.json` ship scripts,
  optional CI workflow.
- Keep a **debug/dev config** (current ad-hoc `TEAM_ID`-unset path) working alongside a new **release
  config** so `bun run dev` is unaffected.

**Needs you (human / Apple):**
- Enroll / provide **Team ID**; request the **group-session** capability approval (long pole).
- Register App IDs, App Group, App Store Connect records; create signing cert + profiles (or authorize
  Xcode-managed signing); generate the **ASC API key**.
- Run the first upload (or add the secrets so CI can), accept export-compliance, invite testers.

---

## Risks & realities to set expectations

- **Timeline is Apple-gated.** group-session approval is the critical path for full functionality;
  budget days–weeks. iOS join/view/voice can go to *internal* TestFlight before it.
- **SharePlay needs 2 devices on different iCloud accounts** to actually test (R1) — TestFlight helps
  here (real testers), which is a reason to ship.
- **The LiveKit SFU must be reachable by testers** (R3). Dev mode (`ws://localhost`) won't work for
  remote testers — TestFlight builds need a real deployed SFU URL (the `apps/livekit/` docker-compose
  stack with domain + TLS, R2/R3) baked into the build or fetched from a token endpoint. **This is a
  parallel prerequisite for a *useful* TestFlight build**, separate from the signing work.
- **macOS Screen Recording + (future) Accessibility TCC** are per-tester grants (R4); document them in
  the TestFlight test notes.
- **Broadcast extension deferred** — iOS ships viewer+voice only; no iOS screen-share-out in v1.

---

## Recommended first move

Two things in parallel, today:
1. **You:** request the SharePlay **group-session** capability approval + register App IDs/App Group/ASC
   records (the clock that gates everything).
2. **Me:** on a `testflight-prep` branch, make all the agent-doable config changes (iOS entitlements,
   signing release-config, app-group id, info keys, export options, ship scripts) and verify the
   Release archive builds locally — so the moment your signing assets + approval land, the first
   upload is one `bun run ship:ios` away.

Tell me to proceed and I'll start on (2).
