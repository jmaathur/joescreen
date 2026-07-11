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
- Expect a long session (hours). It will pause and ask you at the human gates
  (TCC grants, spikes, product decisions) — check on it periodically.
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
Execute milestones M9, M10, M11 from the plan, in order, then stop and summarize before
touching the post-core backlog. Each milestone lands as its ordered steps, each step
compiling and keeping the machine gate green.

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
7. Human gates — stop and ask, never fake or skip silently:
   - Any TCC grant (Screen Recording, camera/mic, PostEvent).
   - The plan's open product questions when you reach them (display-share showsCursor,
     renegotiation freeze policy, one-display cap, token residency, clipboard toggle
     persistence). Present the tradeoff, recommend one option, wait for the answer.
   - Anything needing a second Mac or different iCloud accounts.
8. If you finish M9–M11 with green gates and pushed commits, write a status section at
   the bottom of docs/COSCREEN_PARITY_PLAN.md (what landed, what's PENDING on hardware,
   recommended next backlog item) and stop. Ask before starting backlog item #1 (remote
   control) — it is spike-gated on a human.

CONTEXT MANAGEMENT
The plan document is self-contained — prefer re-reading it (and the code) over relying on
conversation memory. If the session compacts, re-read docs/COSCREEN_PARITY_PLAN.md and
`git log --oneline -20` to re-establish where you are; the per-step commits are your
checkpoint trail.

START
Begin now: read docs/COSCREEN_PARITY_PLAN.md, run the M9 pre-flight understanding
workflow, then implement M9 step by step.
```

## What to expect

- **M9** (receive-side correctness + metadata) is the biggest and most valuable slice —
  frozen-window bugs disappear, remote windows become aspect-true with real titles, cursors
  align, close/reopen works.
- **M10** (tile strip) makes the main window show everyone's webcam with names, mute badges
  and speaking rings.
- **M11** (display share) adds whole-screen sharing with the codec/admission plumbing done
  right.
- The session should end with all machine gates green and a stack of PENDING Tier-2 rows —
  those need you and a second Mac. Budget an evening for the two-Mac run-book afterwards.
