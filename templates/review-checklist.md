# Review checklist — specs/NNN-name

Written by the architect. Applied by the reviewer to the phase diff after all machine gates pass.
Each item must be checkable by reading the diff. Delete items that do not apply; add feature-specific ones.

## Behaviour beyond the tests
- [ ] (feature-specific) e.g. "Snap uses the candle's wick extremes, not open/close"
- [ ] Error and empty states match spec.md wording in every supported language

## Architecture boundaries
- [ ] New logic lives in the modules named in plan.md; no cross-module reach-through
- [ ] No duplicated source of truth (e.g. plan limits defined only where the constitution says)

## Forbidden shortcuts
- [ ] No branches on test inputs or environment detection
- [ ] No placeholder or invented data shown to users
- [ ] No new dependency, timer loop, or security relaxation unless plan.md justifies it

## Copy and UX (only items tests cannot see)
- [ ] Copy follows the project's tone rules (constitution)
- [ ] New UI reuses existing components and spacing tokens
