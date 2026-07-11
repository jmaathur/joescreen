# CoScreen Parity — kickoff prompt (Opus 4.8 + ultracode)

This starts the long-running implementation session for `docs/COSCREEN_PARITY_PLAN.md`.

## How to launch

```sh
cd /Users/jeev/sources/26/joescreen
claude --model claude-opus-4-8
# then paste the prompt below as the first message
```

Notes:
- The prompt contains the keyword **ultracode**, which turns on multi-agent workflow
  orchestration for the session. Opus 4.8 is set via `--model claude-opus-4-8`.
- The session is designed to run **unattended, start to finish** — product decisions are
  pre-made in the plan (§5), and anything only a human can do (TCC grants, spikes,
  two-Mac test rows) is deferred into a `Human TODO` ledger at the bottom of the plan
  instead of blocking. When it ends, run the ledger at your leisure.
- Useful while it runs: `/workflows` shows live agent progress; `git log --oneline`
  shows the per-step commits landing.

## The prompt (paste verbatim)

```text
ultracode

You are implementing the CoScreen parity plan for the JoeScreen macOS app. The plan is
docs/COSCREEN_PARITY_PLAN.md — read it fully first; it is the source of truth for scope,
sequencing, constraints, and definitions of done. It was produced by a multi-agent
mapping + design + verification process against this exact repo, so trust its file-level
claims but re-verify any line numbers before editing.

MISSION
You operate fully autonomously — no human is watching and none will answer questions, so
never stop to ask; the plan's §5 policy tells you how to proceed at every gate. Execute
milestones M9, M10, M11 from the plan, in order, then continue straight into the
post-core backlog (section 4) in its ranked order. Each milestone lands as its ordered
steps, each step compiling and keeping the machine gate green.

OPERATING RULES
1. Work milestone by milestone; within a milestone follow the plan's ordered steps. Before
   each milestone, run a short understanding workflow (parallel readers) over the files
   that milestone touches to re-verify the plan's claims against current code — the repo
   may have moved since the plan was written. If reality contradicts the plan, say so and
   adapt; do not force a stale instruction.
2. Machine gate after every step: `swift build && swift test` from apps/joescreen/
   (and for steps touching Apps/: xcodegen generate --spec Apps/project.yml && xcodebuild
   -project Apps/JoeScreen.xcodeproj -scheme JoeScreen-macOS -derivedDataPath build build).
   A step is not done while the gate is red. Run the LiveKit integration suite with
   LIVEKIT_URL=ws://localhost:7880 when a step touches the transport (start the SFU with
   `bun run livekit` from the REPO ROOT — the script lives in the root package.json).
   Known environment trap: if swift build spews identical "property does not override any
   property from its superclass" errors from inside .build/checkouts/client-sdk-swift, the
   SPM incremental state is poisoned — delete .build/build.db, the LiveKit.build dir,
   LiveKit.swiftmodule and the ModuleCache, then rebuild. Do NOT conclude the pinned SDK
   is broken and do NOT bump it (D7).
3. Commit per ordered step with a message naming the plan section (e.g. "M9.3: …").
   Do not squash milestones into one commit. Push at each milestone boundary.
4. Use workflows for leverage, not for parallel editing: implementation steps are serial
   (Swift files conflict); fan out agents for understanding passes, for writing Tier-1
   test suites against a seam you just wrote, and for adversarial review of each
   milestone's diff (spawn 3+ reviewers with distinct lenses: concurrency/Swift 6,
   protocol back-compat, R24/R32 subscription correctness) before the milestone commit.
5. Honor the hard-constraints section of the plan verbatim (R22 target boundaries, track
   naming contract, R24/R32, D5, D12, 420v/frame-before-publish, additive-only wire
   changes, no receiver-local revision bumps). Violating one is a defect even if tests
   pass.
6. TESTING.md discipline: every milestone updates TESTING.md — machine-gate row with the
   command + actual result, and Tier-2 hardware rows written as PENDING with expected
   outcomes. NEVER claim anything is hardware-verified; nothing you can observe in this
   session counts as a Tier-2 pass.
7. Human-gated work — defer, never block, never fake (plan §5 is the authority):
   - Anything only a human can do (TCC grants, the Phase-0(c) injection spike, the R4
     prompt-cadence spike, rows needing a second Mac or different iCloud accounts):
     implement everything up to that boundary, write the TESTING.md row as PENDING with
     the exact expected outcome, add an entry to the `## Human TODO` ledger at the bottom
     of docs/COSCREEN_PARITY_PLAN.md (what to do, rough time, what it unblocks), and move
     on to the next item. Build spike-gated paths behind runtime switches (per §5) so the
     spike result later slots in as a config change, not a rewrite.
   - Product decisions: the five open questions are already decided in plan §5 — apply
     them. For any new decision the plan doesn't cover, decide yourself: pick the
     reversible option, record it in DECISIONS.md with a one-paragraph rationale, and
     keep going. Never leave a question dangling in chat.
8. After M9–M11, work the backlog (plan section 4) in its ranked order. For each item,
   deliver its full machine-verifiable scope (pure seams, pumps, UI, Tier-1 tests, green
   gates, per-step commits); defer only its human-gated slice via the ledger. Stop only
   when every remaining unit of work is human-gated or the backlog is exhausted. Then
   write a status section at the bottom of docs/COSCREEN_PARITY_PLAN.md — what landed,
   what's PENDING on hardware, the complete Human TODO ledger, and the recommended order
   for running it — commit, push, and end with a summary.

CONTEXT MANAGEMENT
The plan document is self-contained — prefer re-reading it (and the code) over relying on
conversation memory. If the session compacts, re-read docs/COSCREEN_PARITY_PLAN.md and
`git log --oneline -20` to re-establish where you are; the per-step commits are your
checkpoint trail.

START
Begin now: read docs/COSCREEN_PARITY_PLAN.md, run the M9 pre-flight understanding
workflow, then implement M9 step by step. Do not wait for confirmation at any point.
```

## What to expect

- **M9** (receive-side correctness + metadata) is the biggest and most valuable slice —
  frozen-window bugs disappear, remote windows become aspect-true with real titles, cursors
  align, close/reopen works.
- **M10** (tile strip) makes the main window show everyone's webcam with names, mute badges
  and speaking rings.
- **M11** (display share) adds whole-screen sharing with the codec/admission plumbing done
  right.
- After the core it continues into the backlog (remote control seams, clipboard, blocklist,
  menu-bar, rooms/links, browser viewer, draw, …) until only human-gated work remains.
- It should end unprompted with all machine gates green, per-step commits pushed, and a
  `Human TODO` ledger at the bottom of the plan — TCC grants, the injection spike, and the
  two-Mac Tier-2 run-book. Budget an evening to run the ledger; nothing in it blocks the
  code that's already landed.
