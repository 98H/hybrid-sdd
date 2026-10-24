#!/usr/bin/env bash
# author_tests.sh — acceptance tests written by a fresh cheap-model session, red-checked, then locked.
# Usage: author_tests.sh specs/NNN-name [--retrofit]          (run from the repository root, spec committed)
#   default    : tests MUST FAIL before implementation (proves they measure the new behaviour)
#   --retrofit : tests MUST PASS (they describe behaviour that already exists)
# Isolation: works in a git worktree (.sdd/worktrees/NNN-tests) created from HEAD; if config "serve" is set,
# the app is started FROM THAT WORKTREE on servePort and SDD_BASE_URL/SDD_PORT are exported, so tests never
# touch the production instance or its data. On success the lock commit is fast-forwarded into the checkout.
set -uo pipefail
SPEC=${1:?usage: author_tests.sh specs/NNN-name [--retrofit]}; MODE=${2:-}; SPEC=${SPEC%/}
MAIN=$(pwd); HERE=$(cd "$(dirname "$0")" && pwd); PROMPTS="$HERE/prompts"; [[ -d $PROMPTS ]] || PROMPTS="$HERE/../prompts"
CFG="$MAIN/.sdd/config.json"
jqr() { node -e "const c=require('$CFG');const v=$1;process.stdout.write(v==null?'':String(v))"; }
CMD=$(jqr "c.agent.testAuthor"); TMO=$(jqr "(c.agent&&c.agent.timeoutSec)||3600"); ACC=$(jqr "c.acceptanceDir||'tests/acceptance'")
SETUP=$(jqr "c.worktreeSetup||''"); SERVE=$(jqr "c.serve||''"); PORT=$(jqr "c.servePort||0"); READY=$(jqr "c.serveReadyPath||'/'"); STMO=$(jqr "c.serveTimeoutSec||60")
RUN=$(jqr "c.acceptanceRun||'node {FILE}'")
FEAT=$(basename "$SPEC"); NUM=${FEAT%%-*}; BR="sdd/$NUM-tests"; WT="$MAIN/.sdd/worktrees/$NUM-tests"

[[ -n $(git status --porcelain -- "$SPEC") ]] && { echo "AUTHOR FAIL: commit $SPEC first (the worktree is created from HEAD)"; exit 2; }
git worktree remove --force "$WT" 2>/dev/null; git branch -D "$BR" -q 2>/dev/null
git worktree add -q -b "$BR" "$WT" HEAD || { echo "AUTHOR FAIL: cannot create worktree"; exit 2; }
cd "$WT" || exit 2
# Agent CLIs (e.g. Hermes) may pin their tool cwd via env; force every agent process into this worktree.
export TERMINAL_CWD="$WT"
if [[ -n $SETUP ]]; then bash -lc "$SETUP" >/dev/null 2>&1 || { echo "AUTHOR FAIL: worktreeSetup failed"; exit 2; }; fi
OUT="$WT/$SPEC/.sdd"; mkdir -p "$OUT"
publish() { mkdir -p "$MAIN/$SPEC/.sdd"; cp "$OUT"/redcheck.*.log "$OUT/test-author.log" "$OUT/serve.tests.log" "$MAIN/$SPEC/.sdd/" 2>/dev/null; }

P="$OUT/prompt.test-author.md"
node -e 'const fs=require("fs"),[t,o,s,n,a,m]=process.argv.slice(1);fs.writeFileSync(o,fs.readFileSync(t,"utf8").replaceAll("{SPEC_DIR}",s).replaceAll("{SPEC_NUM}",n).replaceAll("{ACCEPTANCE_DIR}",a).replaceAll("{MODE}",m))' \
  "$PROMPTS/test-author.md" "$P" "$SPEC" "$NUM" "$ACC" "${MODE:-new-feature}"

SRV=""
start_app() {
  [[ -z $SERVE ]] && return 0
  export SDD_PORT=$PORT SDD_BASE_URL="http://127.0.0.1:$PORT"
  setsid bash -lc "$SERVE" >"$OUT/serve.tests.log" 2>&1 & SRV=$!
  for ((i=0; i<STMO; i++)); do sleep 1; curl -s -o /dev/null -m 3 "$SDD_BASE_URL$READY" && return 0; kill -0 $SRV 2>/dev/null || break; done
  echo "AUTHOR FAIL: app did not start from the worktree (see $SPEC/.sdd/serve.tests.log)"; publish; return 1
}
stop_app() { # kill the process group, then anything still listening on the test port (fail-safe)
  [[ -n $SRV ]] && { kill -- -$SRV 2>/dev/null; kill $SRV 2>/dev/null; }
  if [[ -n $SERVE && $PORT != 0 ]]; then
    for p in $(ss -ltnpH "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u); do kill "$p" 2>/dev/null; done
  fi
  SRV=""; }
trap stop_app EXIT
start_app || exit 1

timeout "$TMO" bash -lc "${CMD//\{PROMPT_FILE\}/$P}" >"$OUT/test-author.log" 2>&1
FILES=$(grep -rlE "@spec[[:space:]]+$NUM\b" "$ACC" 2>/dev/null || true)
[[ -z "$FILES" ]] && { echo "AUTHOR FAIL: no files tagged @spec $NUM in $ACC"; publish; exit 1; }
bad=0
for f in $FILES; do
  timeout 1500 bash -lc "${RUN//\{FILE\}/$f}" >"$OUT/redcheck.$(basename "$f").log" 2>&1; rc=$?
  if [[ "$MODE" == "--retrofit" ]]; then [[ $rc -ne 0 ]] && { echo "RETROFIT FAIL (must pass on existing code): $f"; bad=1; }
  else [[ $rc -eq 0 ]] && { echo "RED FAIL (passes before implementation — measures nothing): $f"; bad=1; }; fi
done
stop_app
node "$HERE/verify_specs.mjs" --spec "$SPEC" | tail -4
[[ $bad -ne 0 ]] && { publish; echo "Tests not locked. Logs: $SPEC/.sdd/redcheck.*.log"; exit 1; }
rm -f "$OUT"/prompt.test-author.md "$OUT"/serve.tests.log
node "$HERE/lock_tests.mjs" freeze "$SPEC" && git add -A "$ACC" "$SPEC/.sdd" && git commit -qm "sdd($FEAT): acceptance tests locked${MODE:+ ($MODE)}" || { echo "AUTHOR FAIL: lock/commit"; exit 1; }
cd "$MAIN" && git merge -q --ff-only "$BR" || { echo "AUTHOR FAIL: cannot fast-forward to $BR (checkout changed meanwhile); branch kept"; exit 1; }
git worktree remove --force "$WT"; git branch -D "$BR" -q
echo "AUTHOR OK"
