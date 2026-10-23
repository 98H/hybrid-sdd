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
From the founder's intent the architect runs Spec Kit's `specify → plan → tasks → analyze` and also
writes `review-checklist.md`. At most 3 `[NEEDS CLARIFICATION]` items; everything else uses
documented defaults. Output: a ≤10-line summary to the founder.

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

1. Creates branch `sdd/NNN-phaseN` from the base branch.
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
All phases PASS → `verify_specs.mjs` passes → full regression gate → merge → deploy → report to the
founder with the verdict files as evidence.

## 4. The gates (zero model tokens)

| Gate | Script | Fails when |
|---|---|---|
| Spec | `verify_specs.mjs` | missing artifact, template placeholder left, bad task format, `[x]` task citing a missing path, FR without test |
| Lock | `lock_tests.mjs check` | any locked acceptance file changed, added to or removed |
| Scope fence | `scope_fence.mjs` | changed file not under a path cited by the phase's tasks (+ `alwaysAllowed`), or under `protected` |
| Build | config `build` | non-zero exit |
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

1. Install Spec Kit, write the constitution (with the Hybrid-SDD principle).
2. Split the product into feature areas (10-15 is typical).
3. For each area the architect reverse-specifies from code: spec, plan (Constitution Check marks
   PASS/GAP per principle), tasks with existing work `[x]` and gaps `[ ]` in a final *Converge* phase.
4. Test author writes acceptance tests for existing behaviour; red check inverted (they must PASS).
5. Lock. From now on, every change goes through the normal loop; Converge tasks are the backlog.

Reverse-specification is reading-heavy. To protect the expensive model's rate limit, retrofit one or
two areas per session, sequentially, and write each artifact to disk as soon as it is ready.

## 9. Honest limits

- Tests prove only what they measure. A wrong or thin spec yields a correctly implemented wrong
  product. Spec quality is the real bottleneck — that is where the expensive model is spent.
- The DOM probe catches geometric and textual defects, not taste. Visual polish needs layer 2/3.
- Locked tests can be wrong. Unlocking requires an architect decision recorded in `research.md`.
- The cheap model may game gates within the fence (e.g. special-casing test inputs). The reviewer's
  checklist MUST include "no test-specific branches in product code"; high-risk paths get the
  architect's review.
