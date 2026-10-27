#!/usr/bin/env bash
# merge_phase.sh — merge a finished phase branch into the base branch and clean up. Zero model tokens.
# Usage: merge_phase.sh specs/NNN-name <phase>      (run from repo root, on the base branch)
# The pipeline publishes phase logs into the main checkout (untracked) so the architect can read them; the
# same files are committed on the phase branch, so they are removed here before merging.
set -uo pipefail
SPEC=${1:?usage: merge_phase.sh specs/NNN-name <phase>}; SPEC=${SPEC%/}; PHASE=${2:?phase}
FEAT=$(basename "$SPEC"); NUM=${FEAT%%-*}; BR="sdd/$NUM-phase$PHASE"; WT=".sdd/worktrees/$NUM-phase$PHASE"
git rev-parse --verify -q "$BR" >/dev/null || { echo "MERGE FAIL: no branch $BR"; exit 2; }
git clean -fq -- "$SPEC/.sdd"
git merge -q --no-edit "$BR" || { echo "MERGE FAIL: conflicts — resolve, then rerun"; exit 1; }
git worktree remove --force "$WT" 2>/dev/null; git branch -D "$BR" -q
echo "MERGED $BR"
