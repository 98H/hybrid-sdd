---
name: hybrid-sdd
description: Use for any software development. Hybrid SDD workflow.
version: 1.0.0
author: Hossein Mohammadi (98H), Hermes Agent
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [sdd, spec-kit, architecture, delegation, gemini, opus, qa]
    related_skills: [speckit-specify, speckit-plan, speckit-tasks, speckit-analyze, speckit-constitution]
---

# Hybrid SDD

The founder's standing method for ALL software development, in every project and session
(founder rule, 2026-10-23). Opus (architect, medium reasoning) writes only documents; Gemini 3.8
Flash High (ultra reasoning) writes tests, code and reviews in separate one-shot processes; zero-token
scripts decide pass/fail. Canonical repo: https://github.com/98H/hybrid-sdd (METHOD.md is normative).

## When to Use
- Any request to build, change, fix or retrofit software in any repo (new feature, bug with a
  contract change, refactor, new product).
- Don't use for: one-off scripts, ops/sysadmin tasks, research answers, config tweaks with no product code.

## Prerequisites
- Repo has Spec Kit (`.specify/`) — else install: `uvx --from git+https://github.com/github/spec-kit.git specify init --here --force --non-interactive --ignore-agent-tools --integration claude --script sh`.
- Hybrid SDD files in the repo: `scripts/sdd/` (from the canonical repo `scripts/` + `prompts/` → `scripts/sdd/prompts/`) and `.sdd/config.json` (from `templates/sdd.config.json`, adapted). Clone: `gh repo clone 98H/hybrid-sdd /tmp/hybrid-sdd`.
- Hermes config (already applied on this host): `delegation.model=ag/gemini-3.8-flash-high`, `delegation.reasoning_effort=ultra`, `agent.reasoning_overrides.cc/claude-opus-5-5=medium`.

## Procedure
1. **Constitution (once per repo).** Ensure `.specify/memory/constitution.md` contains the *Hybrid SDD* principle from `templates/constitution.md`. Done when the principle text is present and the founder approved.
2. **Specify (architect = me, Opus).** From the founder's 1-2 line intent run `speckit-specify → speckit-plan → speckit-tasks → speckit-analyze`, and write `specs/NNN-x/review-checklist.md`. Every requirement is `FR-xxx` and machine-checkable; every task cites exact paths and `(FR-xxx)`; phases ≤ 8 tasks. Done when `node scripts/sdd/verify_specs.mjs --spec specs/NNN-x --pre-tests` exits 0.
3. **Approval.** Send the founder ≤10 lines (stories, risks, task/phase count, files, ≤3 questions). Wait for "approve".
4. **Acceptance tests (Gemini, separate process).** `terminal(command="bash scripts/sdd/author_tests.sh specs/NNN-x", background=true, notify=true)` (`--retrofit` for existing behaviour). Done when the log ends with `AUTHOR OK`.
5. **Implement each phase (Gemini, separate process).** `terminal(command="bash scripts/sdd/run_phase.sh specs/NNN-x <phase>", background=true, notify=true)`; last phase adds `--final`. Exit 0 = PASS, 3 = ESCALATE. Read ONLY the exit code and `specs/NNN-x/.sdd/phaseN.verdict.json`.
6. **Escalation (Opus, only then).** Read `phaseN.verdict.json`, `phaseN.feedback.md`, `phaseN.review.md` (not the diff, unless `highRisk`). Fix spec/contracts, split the task, or ask the founder. Re-run step 5.
7. **Ship.** Merge, deploy with the project's command, report to the founder with verdict files as evidence (text + full ParsiGu voice note).

## Pitfalls
- **Never orchestrate implementation with `delegate_task` from the Opus session.** Measured 2026-10-15: child results and tool calls flow through Opus context → ~0 saving. Use `run_phase.sh` background processes.
- **Never write product code as Opus**, even "just a small fix" — write/patch the spec and run a phase.
- Never read implementer logs or full diffs unless escalated on a high-risk path; that burns the budget the split exists to save.
- Reverse-specifying a large existing codebase is reading-heavy: do 1-2 feature areas per Opus session sequentially, writing each artifact to disk immediately (parallel Opus sub-agents hit the 429 rate limit and lost all work on 2026-10-23).
- UI/UX: the zero-token DOM probe (`uiProbe` in `.sdd/config.json`) is on by default for UI projects; screenshot review only on the cheap reviewer, and only when the founder asks.
- Exit codes lie in some suites; gates also scan `failureMarkers`. Keep that list accurate per project.

## Verification
- `bash /tmp/hybrid-sdd/tests/selftest.sh` → `15 passed, 0 failed`; `tests/selftest_pipeline.sh` → `9 passed, 0 failed`.
- Per feature: `verify_specs.mjs --spec specs/NNN-x` (full mode) exits 0 and every phase verdict has `"pass": true`.
