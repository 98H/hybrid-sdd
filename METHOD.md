# METHOD — Hybrid SDD in full

This document is normative. "MUST" rules are enforced by the gate scripts where possible; the rest
are enforced by the role prompts.

## 1. Principles

1. **Intent in, evidence out.** The founder gives intent and approves. Everything between is the
   agents' job. The founder receives evidence (gate verdicts, test output), never claims.
2. **The spec is the only interface between models.** The architect never hands the implementer a
   chat transcript; it hands over `specs/NNN-name/`. Anything not in the spec does not exist.
3. **Every requirement is machine-checkable.** A functional requirement (`FR-xxx`) without at least one
   test that cites it is a spec defect, caught by `verify_specs.mjs`.
4. **No model grades its own work.** Tests are written before code by a different session that never
   sees the implementation. Tests are locked by hash. The reviewer is a third session. The final
   judge is a script.
5. **The expensive model is spent once.** The architect writes documents per feature and is called
   again only on escalation, and then reads a verdict file, not a diff.
6. **Fail closed.** Any gate that cannot run (missing tool, crash, timeout) is a FAIL, not a skip.

## 2. Artifacts per feature

```
specs/NNN-name/
├── spec.md                  # user stories (P1..Pn), Given/When/Then, FR-xxx, SC-xxx, edge cases
├── plan.md                  # technical context, Constitution Check table, real file structure
├── research.md              # decisions with rationale and rejected alternatives
├── data-model.md            # entities, fields, validation, state transitions, persistence
├── contracts/               # http-api.md / module-api.md / events — exact shapes and error codes
├── quickstart.md            # how to verify end to end
├── tasks.md                 # phased tasks with exact paths; each task cites the FRs it serves
├── review-checklist.md      # what the reviewer must check beyond the tests (architect-written)
├── checklists/requirements.md
└── .sdd/                    # machine state (committed): tests.lock.json, phase verdicts
```

### Task line format (enforced)

```
- [ ] T012 [P] [US1] Implement magnetic snap in client/src/engine/snap.js (FR-003, FR-004)
```

`[P]` = parallel-safe, `[USn]` = user story, paths are exact, `(FR-...)` = traceability. A task is
ticked `[x]` only by the pipeline after its phase verdict is PASS.

### Acceptance-test format (enforced)

Every acceptance test file lives under the path configured as `acceptanceDir` and carries
`@covers FR-001, FR-002` in a comment. `verify_specs.mjs` fails if any FR in `spec.md` is not
covered by at least one locked test.

## 3. The phases

### Phase A — Constitution (once per project)
Architect writes `.specify/memory/constitution.md` from `templates/constitution.md`. It MUST contain
the *Hybrid SDD* principle (role split, locks, gates, escalation). Founder approves once.

### Phase B — Specify (architect, once per feature)
From the founder's intent the architect runs the full Spec Kit chain:
`specify → clarify (if ambiguous) → plan → checklist (high-risk features) → tasks → analyze`, then writes
`review-checklist.md`. At most 3 clarification questions, batched into the approval message. Every task
cites `(FR-xxx)` or is tagged `(infra)`. Output: a ≤10-line summary to the founder.
Command-by-command mapping: [SPEC-KIT-PARITY.md](SPEC-KIT-PARITY.md).

Completion criterion: `node scripts/verify_specs.mjs --spec specs/NNN-name --pre-tests` exits 0.

### Phase C — Approve (founder)
One reply: "approve" or one correction. A correction goes back to Phase B (architect patches the spec).

### Phase D — Acceptance tests (test author, cheap model, fresh context)
`scripts/author_tests.sh specs/NNN-name` launches a session that sees only `spec.md`, `contracts/`,
`quickstart.md` and the constitution — never the implementation plan's internals beyond contracts.
It writes tests with `@covers` tags. Then:

1. **Red check:** the tests are run against the current code and MUST fail (a test that passes before
   the feature exists measures nothing). For retrofits of existing behaviour this rule is inverted:
   tests MUST pass, proving they describe what exists.
2. **Lock:** `scripts/lock_tests.mjs freeze` records SHA-256 of every acceptance file in
   `specs/NNN-name/.sdd/tests.lock.json`.

### Phase E — Implement (implementer, cheap model, ultra reasoning, separate process)
`scripts/run_phase.sh specs/NNN-name <phase-number>`:

0. Runs Spec Kit `before_implement` extension hooks (`hooks.mjs`); `after_implement` runs after a PASS.
1. Creates an isolated git worktree `.sdd/worktrees/NNN-phaseN` on branch `sdd/NNN-phaseN` from the base
   branch (runs `worktreeSetup` once). The founder's checkout and the production service are never touched.
2. Runs the implementer one-shot with the phase's tasks, the spec directory and the constitution.
3. Runs the gates. On FAIL, writes `feedback.md` (failing gate, failing test names, trimmed output,
   cited FRs) and re-runs the implementer with it. At most 3 attempts.
4. On gate PASS, runs the reviewer one-shot (fresh context) with `review-checklist.md`, the spec and
   `git diff`. Reviewer returns PASS or a list of checklist violations; violations count as an attempt.
5. On final PASS: ticks the phase's tasks, commits, writes `.sdd/phaseN.verdict.json`.
6. Otherwise: writes the verdict with `"escalate": true` and stops.

### Phase F — Escalate (architect, only when needed)
Triggers: 3 failed attempts; implementer reports the spec is contradictory or impossible; scope-fence
violation that the implementer claims is necessary; a phase touching a `highRisk` path; reviewer
uncertainty. The architect reads `verdict.json` + `feedback.md` (small files), decides:
*fix the spec*, *split the task*, *re-plan*, or *ask the founder*. It does not read the full diff
unless the path is high-risk.

### Phase G — Ship
Each PASS leaves branch `sdd/NNN-phaseN` ready; merge it with `scripts/merge_phase.sh specs/NNN-x N` before the next phase
(the next phase's worktree starts from the base). All phases PASS → `verify_specs.mjs` passes → full regression gate → merge → deploy → report to the
founder with the verdict files as evidence.

## 4. The gates (zero model tokens)

| Gate | Script | Fails when |
|---|---|---|
| Spec | `verify_specs.mjs` | missing artifact, template placeholder left, bad task format, `[x]` task citing a missing path, FR without test |
| Lock | `lock_tests.mjs check` | any locked acceptance file changed, added to or removed |
| Scope fence | `scope_fence.mjs` | changed file not under a path cited by the phase's tasks (+ `alwaysAllowed`), or under `protected` |
| Build | config `build` | non-zero exit |
| Serve | config `serve` | the app built from the worktree does not answer on `servePort` (tests then do not run → FAIL) |
| Tests | config `test` + acceptance suites | non-zero exit OR configured failure markers found in output (exit codes lie) |
| UI probe | `ui_probe.mjs` | horizontal overflow, interactive elements overlapping, touch target < 44px on mobile, untranslated strings in a non-default locale, console errors |
| Regression | config `regression` | same as tests, run on merge only |

Gate output: `verdict.json` `{feature, phase, attempt, pass, gates:{name:{pass, summary}}, escalate}`
and `feedback.md` (human/LLM-readable, trimmed to the failures).

## 5. UI/UX checking at low cost

UI/UX checks are layered by cost; only the first layer runs by default:

1. **DOM probe (zero tokens, always):** `ui_probe.mjs` loads the configured pages in each configured
   viewport × locale and measures geometry with `getBoundingClientRect`/`elementFromPoint`. Catches the
   defects that dominate real reviews: overflow, controls covered by toasts/bars, tiny touch targets,
   text not translated, broken RTL/LTR isolation of numbers.
2. **Cheap visual review (optional, per feature):** the cheap reviewer model receives a few screenshots
   for the pages the phase touched. Cost: a handful of images on the cheap model.
3. **Expensive visual review (never by default):** only on founder request.

## 6. Token economics

| Step | Expensive model | Cheap model | Scripts |
|---|---|---|---|
| Spec/plan/tasks/checklist | ~1 pass per feature | — | — |
| Acceptance tests | — | 1 session | red check + lock |
| Implementation | — | 1-3 sessions per phase | gates |
| Review | — | 1 session per phase | — |
| Escalation | reads ~2 small files | — | — |

Measured lesson (2026-10-15): when the expensive model *orchestrated* sub-agents, every sub-agent result
and tool call flowed through its context and the saving was ~0. Therefore: **the implementer loop MUST
run in a separate process** (`run_phase.sh` calls the agent CLI directly), and the architect only reads
the final verdict files.

## 7. Escalation rules for high-risk paths

`sdd.config.json` lists `highRisk` globs (auth, payments, plans/entitlements, security headers,
migrations). A phase touching them always escalates after PASS: the architect reviews that diff
(only that diff). This is the one place the expensive model reads code, by design.

## 8. Retrofitting an existing product

The expensive model never reads the codebase; the same role split applies as for new features.

1. Install Spec Kit, write the constitution (with the Hybrid-SDD principle). *(architect)*
2. Split the product into feature areas (10-15 is typical) in `.sdd/retrofit/areas.tsv`
   (`NNN-name<TAB>hints`). *(architect)*
3. **Recon** — `scripts/recon.sh .sdd/retrofit/areas.tsv 4`: the cheap model reads the code of each area
   in a separate one-shot process and writes a factual inventory (`.sdd/retrofit/NNN.inventory.md`:
   files, behaviours, API, data, plan gates, existing tests, observed gaps). *(cheap model, parallel)*
4. **Spec** — from the inventory alone the architect writes `specs/NNN/spec.md` (user stories, FR-xxx,
   SC-xxx, edge cases; normative WHAT) and commits it. *(architect — the only expensive step)*
5. **Docs + tests** — `scripts/retrofit.sh specs/NNN-*`: per feature the cheap model writes plan,
   research, data-model, contracts, quickstart, tasks (existing work `[x]`, every FR cited),
   checklists and review-checklist; the spec gate judges (one retry with feedback); then
   `author_tests.sh --retrofit` writes acceptance tests in an isolated worktree against the app served
   from that worktree — they must PASS on current code — and locks them; finally full coverage is
   checked. Status per feature: `.sdd/retrofit/NNN.status`. *(cheap model + scripts)*
   Failed features: `scripts/fix_tests.sh specs/NNN-x <evidence logs>` — the cheap model repairs wrong
   tests; where the code really violates an FR it moves that check into a `@converge` test that must fail
   now (a documented gap) and prints `GAP:` lines. Plain tests must pass, coverage must be complete, then
   lock. Gates skip `@converge` files except in the phase whose tasks fix those FRs. *(cheap model + scripts)*
6. **Converge** — the architect reads the status files, the inventories' "Observed gaps" and the
   "Spec/code mismatches" in research.md, and appends a final *Converge* phase of `- [ ]` tasks.
   From now on every change goes through the normal loop; Converge tasks are the backlog.

Reverse-specification of the WHAT is the only reading-heavy step left for the architect, and it reads
inventories (~200 lines per area), not source. Write each spec to disk as soon as it is ready.

## 9. Drift control

Manual hotfixes and emergency changes bypass the loop. After any of them, and periodically, the
architect runs `speckit-converge`: it compares the code with the specs and appends `- [ ]` tasks to the
owning `tasks.md`, which then go through the normal phase loop. `verify_specs.mjs` on the base branch
must stay green.

## 10. Honest limits

- Tests prove only what they measure. A wrong or thin spec yields a correctly implemented wrong
  product. Spec quality is the real bottleneck — that is where the expensive model is spent.
- The DOM probe catches geometric and textual defects, not taste. Visual polish needs layer 2/3.
- Locked tests can be wrong. Unlocking requires an architect decision recorded in `research.md`.
- The cheap model may game gates within the fence (e.g. special-casing test inputs). The reviewer's
  checklist MUST include "no test-specific branches in product code"; high-risk paths get the
  architect's review.

## 11. Time optimisation (wall-clock, without more tokens or weaker gates)

Measured on a real product (2026-10-31, 3 vCPU VPS): one implementer attempt ≈ 10–40 min, gates ≈ 25–40 min
(acceptance files run one after another, then a regression suite), reviewer ≈ 5–15 min. Model tokens are
spent only by the implementer and the reviewer, so wall-clock is cut **only where no model runs**, and
never by skipping a check that decides PASS.

| # | Rule | Where | Saves | Quality / cost impact |
|---|---|---|---|---|
| T1 | **Fail fast.** Lock or scope FAIL → build, unit, serve, acceptance, regression are reported `not run`. Build FAIL → nothing after it runs. | `gates.mjs` | the whole remaining gate time on doomed attempts | none: the attempt fails either way; the feedback names the real cause first |
| T2 | **Regression only when everything before it passed.** An attempt that already failed does not run the slow regression; the next attempt runs it. | `gates.mjs` | 5–10 min per failed attempt | none: a PASS still requires a green regression |
| T3 | **Acceptance lanes.** `acceptanceLanes` groups files that share a rate limit, port range or the served app's mutable state; lanes run concurrently up to `acceptanceParallel`; files inside a lane stay sequential. Same pass rule per file (exit 0, no timeout, no failure marker). | `gates.mjs`, `.sdd/config.json` | acceptance time ÷ lanes (≈ 2–3× on 3 cores) | none if lanes are correct; one lane = old behaviour. Size by CPU/RAM (browser tests ≈ 250 MB each) |
| T4 | **Reviewer overlaps regression.** The diff is final once the attempt is committed, so the reviewer starts when every gate before regression passed (`SDD_PRE_PASS_HOOK`) and works while regression runs. PASS still needs regression green AND reviewer `VERDICT: PASS`. If regression fails, a finished FAIL review is added to the feedback; an unfinished one is killed. | `run_phase.sh` | reviewer time (5–15 min) per passing attempt | tokens: equal on PASS; on a regression failure at most one partial review is spent, but its findings reach the next attempt, often saving one attempt |
| T5 | **Timing in every verdict.** Each gate records `sec`; the verdict records `totalSec`. The architect tunes lanes from data, not guesses. | `gates.mjs` | — | none |
| T6 | **Architect works while machines work.** While an implementer or the gates run, the architect reviews the next area against real sources and prepares the next FR + locked test (after the current phase merges, as before). Never idle after a report: report and start the next step in the same turn. | process | hours per day | none (same Opus work, just earlier) |
| T7 | **Contradiction check before locking.** Before locking a test for a new FR that adds caching, de-duplication, rate limiting or timing, grep the locked tests that count upstream calls or inject consecutive faults; amend them (architect commit) in the same change. | process | a full 3-attempt escalation (observed: 4 h) | none |
| T8 | **Re-gate before re-running a phase.** When an escalation was caused by a test (not code), fix the test, merge base into the phase branch and run `gates.mjs` alone on the existing code first; spend a new implementer run only if that fails. | process | one implementer run | saves tokens |
| T9 | **Red-check sandbox.** A test that spawns other test files is red-checked with a preload that blocks the production port. A red run must never touch production. | process | cleanup time | prevents data damage |

Not done on purpose (would trade quality or cost for time): fewer attempts, a weaker implementer reasoning
level, skipping the reviewer or the regression, running gates against production, parallel implementer
sessions for tasks that share files, and splitting one implementer attempt across several cheap sessions
when the phase is not `[P]`-parallel.

Configuration (`.sdd/config.json`):

```json
"acceptanceParallel": 3,
"acceptanceTimeoutSec": 1800,
"acceptanceLanes": [
  { "name": "browser",   "match": "/0(1[3-9]|2\\d)_.*\\.test\\.cjs$" },
  { "name": "upstream",  "match": "/(0[1-8])_.*\\.test\\.cjs$" }
]
```
`{LANE}` in `acceptanceRun` is replaced by the lane name, e.g. `flock /run/lock/qa-{LANE}.lock node {FILE}`
(keep a global lock only for suites that really share one resource).

Proof: `tests/selftest_speed.sh` (lanes concurrent, lane-internal order, failure in any lane fails, fail fast,
regression skipped only after an earlier failure, reviewer overlap, reviewer FAIL and regression FAIL still block).
