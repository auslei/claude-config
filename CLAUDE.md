## Development Workflow

These rules apply to all projects. Follow them in order — do not skip steps.

**Roles:** *Human* — the user, whose instructions these are. *Orchestrator* — the main Claude Code loop that plans, delegates, and integrates. *Developer* — a sub-agent implementing one planned section. *Tester* — the `test-runner` sub-agent that runs the suite. Default models are in **Models per role**.

**If you are a Developer sub-agent (implementing a delegated section):** skip steps 0–3 and 6. Implement your section to the contract you were given, follow step 4, and report back. Do not plan, branch, commit, or ask the Human for confirmation.

**0. Clarify before building.**
Make reasonable assumptions for obvious details and state them. Only stop to ask the Human when the answer would change what gets built. Never ask about something you can default safely.

As Orchestrator, fully understand the feature requirement before planning or delegating. Don't just accept it — stress-test it: if the request has logical, technical, or design flaws (contradictions, unhandled cases, an approach that won't work, a materially simpler alternative), push back and surface them to the Human so the requirement can be refined together first. Never delegate work built on a flawed or half-understood requirement.

**1. Plan first — for non-trivial changes.**
Before planning a new feature, check `docs/backlog/` (and `docs/research/`) for an existing item that covers it or has synergy — if one exists, build on it (and its linked research) rather than starting cold, and follow the promotion flow in **Documentation layout** (fresh plan, delete the backlog file once planned/shipped). If a change touches 2+ files or introduces new behaviour, produce a written plan before writing code. Break large changes into ordered sections with clear boundaries (what each section owns, what interfaces it exposes). Once agreed, save the discussion outcome (decisions, assumptions, rejected options) and the plan to `docs/plans/<slug>-<yyyymmdd>.md` (see **Documentation layout**). This file is the handoff: sub-agent briefs point to it, and it survives `/clear` or a new session. Single-file fixes and targeted tweaks can proceed directly.

**If an approved plan already exists** (the Human points to one, or one in `docs/plans/` matches the task): don't re-plan. Read it, check what is already done, and resume from the first incomplete step. Mark sections done in the plan file as they finish.

**2. Confirm + branch before executing.**
For any change that needed a plan in step 1: confirm the plan with the Human and create a feature branch. Single-file fixes can proceed directly on the current branch.

**3. Execute sections; delegate when it saves context.**
Delegate a section to a Developer sub-agent (the `section-implementer` agent) when its file reads would bloat the Orchestrator's context; do small sections inline. Run sections in parallel when they have no data dependency on each other; parallel Developers that edit files each get their own worktree (`isolation: "worktree"`). Run sequentially only when section B needs section A's output. Before delegating, provide the Developer with: the interface contract it must satisfy (function signatures, schema, API shape), a summary of the overall feature, and only the context it needs for its section.

**4. Sections own their tests (inner loop).**
Whoever implements a section — a Developer, or the Orchestrator for inline sections — writes tests for it. Tests must cover: any two-outcome branch (assert both), any trust boundary input (validate both sides), and any path that mutates persistent state. Then loop: run the section's tests → if any fail, fix and re-run → repeat until green. Only report the section done once its own tests pass; a red state never leaves the implementer. The full suite belongs to step 5.

**5. Integrate, test, review (outer loop).**
Once all sections report done, the Orchestrator merges any worktrees, then runs this loop until exit:
1. **Run the full suite** — delegate to the Tester (`test-runner`, on Sonnet); run inline only if the suite is trivial or already green. The Tester runs and triages failures but never fixes.
2. **If the suite is red:** every failure gets resolved — a red suite is never an acceptable exit state. For each confirmed failure the Orchestrator decides, by step 3's rule — fix inline if small, delegate back to the owning Developer if section-sized — then return to step 1. A failure is either a real defect (fix the code) or a stale/wrong test (fix or delete the test); there is no third "ignore it" case. If a failure is pre-existing and genuinely outside the change's scope, still fix or remove the test, and flag it to the Human rather than expanding scope silently.
3. **Once green:** run `/code-review` on the diff. Fix confirmed findings (same inline-vs-delegate rule); if a fix touches code, return to step 1.

**Exit condition:** full suite green AND `/code-review` findings resolved. Only then, if the project has a web UI and the change affects it, visually validate in the browser (claude-in-chrome) before reporting done. Skip the visual check for backend, CLI, or library projects.

**6. Summarise, commit, ask about merge.**
Report against the plan file: what was planned vs built, any deviations and why, test/review results, and open follow-ups. Commit with a descriptive message. Ask the Human whether to merge to main and push — never do so automatically.

## Models per role

Use model aliases (**Opus / Sonnet / Fable**) — they resolve to the current version; don't pin point-releases here.
- **Orchestrator + Developer → Opus** (the default main-loop model). Keep the main loop on one model and delegate rather than switch mid-session — switching invalidates the prompt cache.
- **Tester → Sonnet.** The `test-runner` sub-agent is pinned to Sonnet (`model: sonnet`) and runs the full suite at step 5. Developers still write their section's own tests (step 4) on the implementing model (Opus).
- **Fable → manual escalation only.** Don't default to it: it draws the same shared weekly limit at ~2× the rate and has rough edges (minutes-long turns, less-prescriptive prompting, 30-day-retention requirement). Reach for it deliberately (`/model`) only for a genuinely hard, stuck planning problem — a rare, deliberate exception to "keep the main loop on one model" (accept the one-time cache rebuild), then switch back to Opus once past it.

## Production releases

Separate from the per-change workflow. Triggered on demand ("cut a release", "release to production", "tag vX.Y.Z"). Releases bundle several merged changes.

**Versioning:** SemVer git tags, per repo.
- `vMAJOR.MINOR.PATCH` (immutable) — the version. One per release, never moves.
- `prod` (moving) — what's live now. Repointed on each deploy.
- PATCH: fixes only. MINOR: backward-compatible features. MAJOR: breaking / migration.
- The Human gives the bump level, or the Orchestrator infers it from the diff since the last tag and confirms; compute the next tag from `git describe --tags --abbrev=0`.

**No long-lived prod branch.** The `prod` tag pins the exact live commit; branches drift.

**On release:**
1. Confirm `main` is clean and current (`git fetch`; nothing uncommitted/unpushed).
2. Version = last tag + the bump.
3. Gather changes: `git log <last-tag>..HEAD`.
4. Write `docs/releases/vX.Y.Z-<yyyymmdd>.md`:
   - **Summary** — one paragraph, what and why.
   - **Changes** — grouped (features / fixes / internal), human-readable, not raw commits.
   - **Migration / install** — DB migrations, config/env changes, new deps, infra steps, in apply order. "None." if none.
   - **Known issues & TODOs** — unresolved or deferred items, with pointers.
5. Commit the doc, then `git tag -a vX.Y.Z -m "<summary>"`.
6. With the Human's OK: push the tag, then mark it live: `git tag -f prod vX.Y.Z && git push -f origin prod`. If the repo has a GitHub remote: `gh release create vX.Y.Z -F docs/releases/vX.Y.Z-<yyyymmdd>.md`.

**Hotfix (prod broken, `main` not shippable):**
- Branch from the `prod` tag, never `main`: `git switch -c hotfix/<x> prod`.
- Fix + test, tag a PATCH bump (`vX.Y.Z+1`), deploy (repoint `prod`), write the release doc.
- Cherry-pick / merge the fix back to `main` — or the next release reintroduces the bug.
- If `main` IS shippable, skip this: fix → merge to main → cut the next release normally.

**"What's in production?"** `git describe --tags prod`. **"What's staged but not shipped?"** `git log prod..<latest-tag>`.

Never tag or push a release without confirmation.

## What belongs in a repo CLAUDE.md

A repo `CLAUDE.md` is working memory for Claude Code — only what changes how Claude acts in *this* repo and isn't already inherited from this global file. Keep it lean.

**Belongs in CLAUDE.md:** project-specific build/test/run commands, stack conventions that differ from the default (package manager, naming, logging helper, file-size limits), architecture notes that affect where code goes, non-obvious gotchas, and interface contracts for the repo's own modules.

**Belongs in README.md (not CLAUDE.md):** anything written for a human reader — project pitch, feature tours, usage examples, API walkthroughs, install narratives, screenshots. Claude reads the code; it doesn't need the prose.

**Never in CLAUDE.md:** anything already in this global file — the dev workflow, release process, simplicity ladder, docs layout, "ask when unclear / plan first / test every change." Don't restate inherited rules; they apply automatically.

**Push back:** if the Human asks to add something to a repo CLAUDE.md that's human-facing documentation with no bearing on how Claude writes code, say so and recommend putting it in README.md instead. Don't silently comply.

**Nested CLAUDE.md — information hiding.** A subtree earns its own CLAUDE.md only when it has conventions the root doesn't carry. When it does, treat parent and module like encapsulated units:
- The root knows the module's **public contract** (what it's for, how you interact with it) and points to the nested file — it never restates the module's internals.
- The nested file documents **only its own subtree**. It may reference the parent's public contract (like importing a base class), but never copies parent or global rules.
- **No upward leakage:** if the root needs an internal detail to work, that detail is part of the module's contract — promote it, don't duplicate it downward.
- A nested file that only echoes the root or global gets folded up.

## Documentation layout

All project docs live under `docs/`, one file per item, named `<slug>-<yyyymmdd>.md` (slug = short kebab-case; date = when created, except `completed/` which uses the completion date, and `ops/` which uses plain descriptive names and is updated in place):

| Folder | Holds | Date |
|--------|-------|------|
| `docs/plans/` | Active implementation plans (step 1) | created |
| `docs/releases/` | Release notes, one per version (see Production releases) | created |
| `docs/backlog/` | Scoped-but-not-started work, one item per file | created |
| `docs/research/` | Findings, scoping, source surveys — reference, kept permanently | created |
| `docs/completed/` | Plans whose work shipped; moved here from `docs/plans/` | completed |
| `docs/ops/` | Living operational reference (loader schedules, runbooks, catalogs) — updated in place, not dated | n/a |

**Lifecycle:**
- A doc's **folder is its status** — a plan in `docs/plans/` is active; moving it to `docs/completed/` (renamed with the completion date) marks it done.
- **Promoting a backlog item:** review it, write a fresh plan in `docs/plans/` (update/rename an existing partial plan rather than duplicating), then delete the backlog file once its work is fully planned or done.
- **Cross-link, don't orphan:** a plan's first line names its backlog/research origin (e.g. `From: docs/research/nsw-local-store-20261117.md`); a completed doc keeps a one-line outcome. This preserves the trail from research → backlog → plan → shipped.
- Existing design docs stay where they are; this convention applies to new docs going forward.

## Simplicity (Ponytail)

Default to the simplest solution that fully works. The ladder in order: does it need to exist → stdlib → native platform feature → already-installed dep → one line → minimum code. Stop at the first rung that holds.

**i18n is never a simplification target.** Any component with bilingual copy, locale-conditional layout, or CJK typography must be fully spec'd for both locales before the first line is written. "Minimum code" on an i18n path creates rework.
