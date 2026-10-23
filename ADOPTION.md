# ADOPTION — add Hybrid SDD to any repository

Time: about 30 minutes for setup, then the loop runs per feature.

## 0. Prerequisites
- Node.js ≥ 20, git, bash.
- An agent CLI that can run a one-shot session from a prompt file and use tools (shell, file edit).
  Hermes Agent: `hermes chat --oneshot --yolo -Q -m <model> --reasoning <level> --query-file <file>`.
  Other harnesses work too: put their command in `.sdd/config.json → agent.*` with `{PROMPT_FILE}`.
- Two models: an expensive one for the architect (interactive), a cheap one for the
  test author / implementer / reviewer (one-shot).
- Optional for the UI probe: `npm i -D puppeteer-core` and a Chromium binary.

## 1. Install Spec Kit
```bash
uvx --from git+https://github.com/github/spec-kit.git specify init --here --force \
    --non-interactive --ignore-agent-tools --integration claude --script sh
```
This creates `.specify/` (templates, scripts) and `.claude/skills/speckit-*`.

## 2. Add Hybrid SDD
```bash
git clone https://github.com/98H/hybrid-sdd /tmp/hybrid-sdd
mkdir -p .sdd scripts/sdd
cp /tmp/hybrid-sdd/scripts/* scripts/sdd/
cp -r /tmp/hybrid-sdd/prompts scripts/sdd/prompts
cp /tmp/hybrid-sdd/templates/sdd.config.json .sdd/config.json
cp /tmp/hybrid-sdd/templates/review-checklist.md .specify/templates/
bash /tmp/hybrid-sdd/tests/selftest.sh && bash /tmp/hybrid-sdd/tests/selftest_pipeline.sh
```
Edit `.sdd/config.json`:
- `build`, `test`, `regression`: your real commands.
- `failureMarkers`: strings your test runners print on failure (exit codes are not trusted alone).
- `acceptanceDir`, `acceptanceRun`: where acceptance tests live and how to run one file.
- `protected`: paths the implementer must never touch (specs, locked tests, secrets, data).
- `highRisk`: paths whose diffs the architect always reviews (auth, payments, permissions).
- `uiProbe`: base URL, pages, viewports, locales (with a JS `setup` snippet that switches language),
  and `untranslatedPattern` (e.g. `"[A-Za-z]{4,}"` for an RTL locale).

## 3. Constitution (architect, once)
Start from `templates/constitution.md`. Keep principle **Hybrid SDD** verbatim; add the project's own
principles (data honesty, i18n, performance, security…). Founder approves once.

## 4. Per feature
| Step | Who | Command / action | Done when |
|---|---|---|---|
| Intent | founder | 1-2 lines | — |
| Specify | architect | `speckit-specify → plan → tasks → analyze`, write `review-checklist.md` | `node scripts/sdd/verify_specs.mjs --spec specs/NNN-x --pre-tests` exits 0 |
| Approve | founder | "approve" or one correction | — |
| Tests | test author | `bash scripts/sdd/author_tests.sh specs/NNN-x` | prints `AUTHOR OK` (red-checked and locked) |
| Build | implementer | `bash scripts/sdd/run_phase.sh specs/NNN-x <phase>` per phase | exit 0 (PASS) or 3 (ESCALATE) |
| Escalation | architect | read `specs/NNN-x/.sdd/phaseN.{verdict.json,feedback.md,review.md}` | spec fixed / task split / founder asked |
| Ship | pipeline | last phase with `--final`, merge, deploy | `verify_specs.mjs` (full) exits 0 |

Run phases in the background (e.g. `nohup … &` or a Hermes background terminal job) so the architect's
session never holds the implementer's output.

## 5. Retrofit an existing product
See METHOD.md §8. Use `author_tests.sh specs/NNN-x --retrofit` (tests must PASS on current code).
Reverse-specify one or two areas per architect session to stay inside rate limits.

## 6. With Hermes Agent
- Config: `hermes/config-snippet.yaml` (delegation pinned to the cheap model; per-model reasoning).
- Skill: copy `hermes/skill/hybrid-sdd/` to `~/.hermes/skills/software-development/hybrid-sdd/`.
- The architect is the interactive Hermes session; implementer runs are separate `hermes chat --oneshot`
  processes started by `run_phase.sh`, never `delegate_task` from the architect session.
