# Hybrid SDD — Inverted Spec-Driven Development with an Architect/Implementer model split

A complete, reproducible method for building software with AI agents where:

- **the founder** spends about one minute per feature (intent + one approval),
- **an expensive architect model** (e.g. Claude Opus) writes only documents, once per feature,
- **a cheap implementer model** (e.g. Gemini Flash) writes all code and tests, unattended,
- **machines, not models, decide whether the work is correct** (zero-token gates).

The method is built on [GitHub Spec Kit](https://github.com/github/spec-kit) and was designed and
operated with [Hermes Agent](https://hermes-agent.nousresearch.com). Any agent harness that can run
a one-shot model session from a shell can use it.

> Persian summary: [README.fa.md](README.fa.md)

## Why

Two failure modes kill AI-built products:

1. **The founder becomes the bottleneck** by writing specs by hand. → Specs are *inverted*: the
   architect drafts them from a 1-2 line intent; the founder only approves.
2. **The expensive model's budget is burned on routine work** (writing code, reading diffs, babysitting
   sub-agents). → The architect works once per feature. Verification is done by scripts that cost zero
   model tokens; the implementer runs in a separate process whose output never enters the architect's
   context.

## The loop in one picture

```
Founder ──intent (1-2 lines / voice)──► ARCHITECT (expensive, medium reasoning) ── once per feature
                                         spec · plan · contracts · tasks · review checklist
                                         (with FR ids so every requirement is traceable)
Founder ◄──≤10-line summary──────────── ARCHITECT
Founder ──"approve"────────────────────►
                                         TEST AUTHOR (cheap model, fresh context, sees spec only)
                                         writes acceptance tests → must FAIL (red) → hashes LOCKED
                                         IMPLEMENTER (cheap model, ultra reasoning, separate process)
                                         one tasks.md phase per run, in an isolated branch
                                              │
                                              ▼
                                         GATES (scripts, zero tokens)
                                         lock · scope fence · build · tests · UI probe · traceability
                                              │ fail → evidence fed back, max 3 attempts
                                              ▼ pass
                                         REVIEWER (cheap model, fresh context, architect's checklist)
                                              │
                         ┌────────────────────┴────────────────────┐
                    verdict PASS                            ESCALATE (3 fails, scope request,
                    task ticked, merged                     high-risk path, reviewer doubt)
                                                            → architect reads verdict.json only
```

## Roles

| Role | Model | Writes | Never does |
|---|---|---|---|
| Founder | human | intent, approval, product decisions | specs, code |
| Architect | expensive, medium reasoning | constitution, spec, plan, contracts, tasks, review checklist, gate config | product code, reading full diffs, orchestrating long loops |
| Test author | cheap, fresh context | acceptance tests from spec + contracts | implementation code |
| Implementer | cheap, ultra reasoning | product code + unit tests for one phase | editing specs, locked tests, protected paths |
| Reviewer | cheap, fresh context | verdict against the architect's checklist | code changes |
| Gates | scripts | verdict.json, feedback.md | — |

The separation is the point: **no model grades its own work**. The test author and the implementer are
different sessions; the reviewer is a third; the final judge is a script.

## Repository layout

| Path | Purpose |
|---|---|
| [METHOD.md](METHOD.md) | Full method: phases, rules, escalation, token economics, honest limits |
| [SPEC-KIT-PARITY.md](SPEC-KIT-PARITY.md) | Command-by-command comparison with GitHub Spec Kit; what is kept, replaced, added, and known gaps |
| [ADOPTION.md](ADOPTION.md) | Step-by-step: add Hybrid SDD to any repository (with or without Hermes) |
| [templates/constitution.md](templates/constitution.md) | Constitution scaffold incl. the mandatory Hybrid-SDD principle |
| [templates/sdd.config.json](templates/sdd.config.json) | Per-project gate configuration |
| [templates/review-checklist.md](templates/review-checklist.md) | Architect-written checklist the reviewer applies |
| [prompts/](prompts/) | Role prompts: architect, test-author, implementer, reviewer |
| [scripts/verify_specs.mjs](scripts/verify_specs.mjs) | Spec gate: artifacts, placeholders, task format, FR traceability |
| [scripts/lock_tests.mjs](scripts/lock_tests.mjs) | Freeze / check acceptance-test hashes |
| [scripts/scope_fence.mjs](scripts/scope_fence.mjs) | Reject changes outside the phase's task paths or inside protected paths |
| [scripts/ui_probe.mjs](scripts/ui_probe.mjs) | Zero-token UI/UX probe (overflow, overlap, touch targets, untranslated text) |
| [scripts/gates.mjs](scripts/gates.mjs) | Runs all gates, writes `verdict.json` + `feedback.md` |
| [scripts/hooks.mjs](scripts/hooks.mjs) | Runs Spec Kit extension hooks (`.specify/extensions.yml`) around each phase, Spec Kit rules, fail closed |
| [scripts/run_phase.sh](scripts/run_phase.sh) | Implement → gate → retry (≤3) → review → verdict, fully unattended |
| [scripts/author_tests.sh](scripts/author_tests.sh) | Test author session + red check + lock |
| [hermes/](hermes/) | Hermes Agent config snippet and the `hybrid-sdd` skill |
| [tests/](tests/) | `selftest.sh` (20 gate checks) and `selftest_pipeline.sh` (19 loop checks: retries, escalation, worktree isolation, Spec Kit hooks, parallel `[P]` tasks) — no model calls |

Requirements: Node.js ≥ 20, git, bash, a shell-callable agent CLI (Hermes: `hermes chat --oneshot`).
`ui_probe.mjs` additionally needs `puppeteer-core` and a Chromium binary.

## License

MIT
