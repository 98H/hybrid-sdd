# Parity with GitHub Spec Kit

Hybrid SDD is a **superset** of Spec Kit: it installs Spec Kit unchanged (`specify init`) and uses its
commands, templates and scripts for everything before implementation. It replaces only
`/speckit-implement` (single agent, self-checked) with an isolated, multi-model, machine-judged pipeline.

Audited against Spec Kit 1.2.4 (`specify init --integration claude`), 2026-10-23.

## Commands

| Spec Kit | Status in Hybrid SDD | Where |
|---|---|---|
| `/speckit-constitution` | Used as is; constitution must also contain the *Hybrid SDD* principle | architect, Phase A |
| `/speckit-specify` | Used as is | architect step 1 |
| `/speckit-clarify` | Used when markers/ambiguity exist; questions batched into the approval message | architect step 2 |
| `/speckit-plan` | Used as is (Constitution Check, research, data-model, contracts, quickstart) | architect step 3 |
| `/speckit-checklist` | Used for high-risk features; unchecked items block the spec gate | architect step 4, `verify_specs.mjs` |
| `/speckit-tasks` | Used, with two additions: FR traceability per task, `(infra)` tag | architect step 5 |
| `/speckit-analyze` | Used; CRITICAL/HIGH findings must be fixed before approval | architect step 6 |
| `/speckit-implement` | **Replaced** by `author_tests.sh` + `run_phase.sh` (test author, implementer, gates, reviewer) | Phases D-E |
| `/speckit-converge` | Used for drift detection and retrofit backlogs | architect, periodic |
| `/speckit-taskstoissues` | Optional | architect, on request |

## What `/speckit-implement` does and where each duty went

| `/speckit-implement` duty | Hybrid SDD |
|---|---|
| Check `checklists/` and stop on unchecked items | `verify_specs.mjs` fails on any unchecked checklist item (spec gate runs in every phase) |
| Read tasks, plan, data-model, contracts, research, quickstart | Implementer prompt receives spec dir + phase tasks; test author receives spec + contracts |
| Create/verify ignore files (.gitignore, .dockerignore…) | Must be an explicit `(infra)` task in Phase 1 (setup) — the implementer only changes what tasks list |
| Execute phase by phase, respect dependencies and `[P]` | `run_phase.sh` runs one phase per invocation, in order; with `"parallel": true`, consecutive `[P]` tasks with disjoint paths run as concurrent implementer sessions (sequential tasks keep their order) |
| TDD: tests before code | Stronger: tests by a different session, red-checked, hash-locked before any code |
| Mark tasks `[X]` as they complete | Ticked by the pipeline only after a PASS verdict |
| Validate completion against the spec | Gates (machine) + reviewer (checklist) + `verify_specs.mjs --final` (every FR covered) |
| Extension hooks `before_/after_implement` | Executed by `scripts/hooks.mjs` around every phase, with Spec Kit's own rules (see *Hooks*) |

## Workflow

Spec Kit's bundled workflow (`.specify/workflows/speckit/workflow.yml`) is
`specify → [gate] → plan → [gate] → tasks → implement`, with two human gates. Hybrid SDD keeps one human
gate (after `analyze`, covering spec and plan together) because the founder approves intent, not
artifacts; the second check is done by `analyze` + `verify_specs.mjs`. If the founder wants both gates,
send the summary twice — nothing in the tooling prevents it.

## Templates and presets

Spec Kit resolves templates through `.specify/templates/overrides/` → presets → extensions → core.
Hybrid SDD does not fork any template. Its additions (FR references in tasks, `(infra)`,
`review-checklist.md`) are enforced by the architect prompt and `verify_specs.mjs`, so Spec Kit upgrades
(`specify self upgrade`, preset updates) keep working.

## Hooks

The architect's Spec Kit commands run their own hooks as usual. Around implementation, `run_phase.sh`
calls `scripts/hooks.mjs` with the same rules as `/speckit-implement`: reads `.specify/extensions.yml`,
skips `enabled: false`, leaves non-empty `condition` to Spec Kit's HookExecutor, lists optional hooks,
and EXECUTES mandatory (`optional: false`) hooks through the cheap agent (`agent.hookRunner`, default
`agent.testAuthor`; command names mapped `speckit.x.y` → `/speckit-x-y`). A failing mandatory
`before_implement` hook stops the phase (exit 2); a failing `after_implement` hook escalates. An unreadable
`extensions.yml` fails closed. Plain shell hooks can be added in `.sdd/config.json` → `hooks`.

## Agent context files

Older Spec Kit versions updated an agent context file (e.g. `CLAUDE.md`) from `plan.md`. 1.2.4 keeps it
only as a deprecated fallback; Hybrid SDD's implementer and test author receive their context
explicitly through prompts, so no context file is required.

## What Hybrid SDD adds beyond Spec Kit

1. Expensive/cheap model split with the expensive model outside the implementation loop.
2. Acceptance tests from an independent session, red-checked and hash-locked.
3. Zero-token gates: lock, scope fence, build, tests judged by output content, UI probe, spec gate, regression.
4. App-under-test served from the phase worktree (never the production instance).
5. Isolated git worktree per phase; founder's checkout and production untouched.
6. FR → task → test traceability enforced by a script.
7. Bounded retries with structured feedback; escalation rules; high-risk path review.
8. Project-agnostic: nothing in the tooling is specific to one product; every project-specific value lives in `.sdd/config.json`.

## Known limits (honest)

- Parallel `[P]` sessions are used on the first attempt only; retries run the whole phase in one session
  with the gate feedback (merging parallel fixes is riskier than the time it saves).
- Hook `condition` expressions are not evaluated — identical to `/speckit-implement`.
- The UI probe checks geometry and text, not visual taste.
