# [PROJECT] Constitution

[One paragraph: what the product is, who builds it (founder + agents), and that it uses Hybrid SDD.]

## Core Principles

### I. Hybrid SDD (NON-NEGOTIABLE)

- **Roles.** The founder gives intent and one approval per feature. The architect (expensive model,
  medium reasoning) writes only documents: constitution, spec, plan, research, data model, contracts,
  quickstart, tasks, review checklist. A cheap model writes acceptance tests (test author), product code
  (implementer, ultra reasoning) and verdicts (reviewer), each in a separate session.
- **Traceability.** Every functional requirement has an `FR-xxx` id and is machine-checkable. Every task
  cites exact paths and the FRs it serves. Every FR is covered by an acceptance test tagged
  `@spec NNN @covers FR-xxx`.
- **No self-grading.** Acceptance tests are written before code by a session that never sees the
  implementation, red-checked (must fail before the feature exists), then locked by hash. The
  implementer may not change specs, locked tests or protected paths.
- **Machine judges.** A phase passes only when every gate passes: lock, scope fence, build, tests
  (judged by output content, not only exit codes), UI probe, spec gate; then the reviewer's checklist.
  Gates fail closed.
- **Architect budget.** The architect is called once per feature and again only on escalation
  (3 failed attempts, spec problem, high-risk path, reviewer doubt), and then reads verdict files,
  not diffs — except for high-risk paths.
- **Tasks are ticked by the pipeline only**, after a PASS verdict.

### II. [Project principle]
[Declarative, testable rules. Avoid "should"; use MUST / MUST NOT with rationale.]

### III. [Project principle]

## Technology and Operating Constraints
[Runtime, frameworks, storage, deploy command and its success signal, budgets.]

## Governance
- This constitution supersedes ad-hoc practice. Every plan.md contains a Constitution Check table;
  violations are justified in Complexity Tracking or the plan is rejected.
- Amendments use semantic versioning (MAJOR removes/redefines a principle, MINOR adds, PATCH words)
  and are approved by the founder.

**Version**: 1.0.0 | **Ratified**: YYYY-MM-DD | **Last Amended**: YYYY-MM-DD
