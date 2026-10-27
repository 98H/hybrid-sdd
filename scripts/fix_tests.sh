#!/usr/bin/env bash
# fix_tests.sh — repair retrofit acceptance tests with the cheap model, then re-check and lock. No architect tokens.
# Usage: fix_tests.sh specs/NNN-name [evidence-file...]     (run from repo root; spec committed)
# Evidence: failing redcheck logs and/or verify_specs output (uncovered FRs). Works in .sdd/worktrees/NNN-fix,
# app served from that worktree. Check: plain tests MUST PASS; files tagged @converge MUST FAIL (known gaps,
# fixed later by the Converge phase). Then lock, commit, merge back. Prints GAP lines for the architect.
set -uo pipefail
SPEC=${1:?usage: fix_tests.sh specs/NNN-name [evidence...]}; shift; SPEC=${SPEC%/}
MAIN=$(pwd); HERE=$(cd "$(dirname "$0")" && pwd); PROMPTS="$HERE/prompts"; [[ -d $PROMPTS ]] || PROMPTS="$HERE/../prompts"
CFG="$MAIN/.sdd/config.json"
jqr() { node -e "const c=require('$CFG');const v=$1;process.stdout.write(v==null?'':String(v))"; }
CMD=$(jqr "c.agent.testAuthor"); TMO=$(jqr "(c.agent&&c.agent.timeoutSec)||3600"); ACC=$(jqr "c.acceptanceDir||'tests/acceptance'")
SETUP=$(jqr "c.worktreeSetup||''"); SERVE=$(jqr "c.serve||''"); PORT=${SDD_PORT_OVERRIDE:-$(jqr "c.servePort||0")}; STMO=$(jqr "c.serveTimeoutSec||60")
RUN=$(jqr "c.acceptanceRun||'node {FILE}'")
FEAT=$(basename "$SPEC"); NUM=${FEAT%%-*}; BR="sdd/$NUM-fix"; WT="$MAIN/.sdd/worktrees/$NUM-fix"
EVID=$(for f in "$@"; do echo "### $(basename "$f")"; grep -E "❌|FAIL|Error|FRs without|uncovered" "$f" | head -40; done)

git worktree remove --force "$WT" 2>/dev/null; git branch -D "$BR" -q 2>/dev/null
git worktree add -q -b "$BR" "$WT" HEAD || { echo "FIX FAIL: worktree"; exit 2; }
cd "$WT" || exit 2
export TERMINAL_CWD="$WT"
[[ -n $SETUP ]] && { bash -lc "$SETUP" >/dev/null 2>&1 || { echo "FIX FAIL: worktreeSetup"; exit 2; }; }
OUT="$WT/$SPEC/.sdd"; mkdir -p "$OUT"
P="$OUT/prompt.test-fix.md"
node -e 'const fs=require("fs"),[t,o,s,n,a,e]=process.argv.slice(1);fs.writeFileSync(o,fs.readFileSync(t,"utf8").replaceAll("{SPEC_DIR}",s).replaceAll("{SPEC_NUM}",n).replaceAll("{ACCEPTANCE_DIR}",a).replaceAll("{EVIDENCE}",e))' \
  "$PROMPTS/test-fix.md" "$P" "$SPEC" "$NUM" "$ACC" "$EVID"

SRV=""
stop_app() { [[ -n $SRV ]] && kill -- -$SRV 2>/dev/null; if [[ -n $SERVE && $PORT != 0 ]]; then for p in $(ss -ltnpH "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u); do kill "$p" 2>/dev/null; done; fi; SRV=""; }
start_app() {
  [[ -z $SERVE ]] && return 0
  stop_app; export SDD_PORT=$PORT SDD_BASE_URL="http://127.0.0.1:$PORT"
  setsid bash -c "exec bash -lc \"\$0\"" "$SERVE" >"$OUT/serve.fix.log" 2>&1 & SRV=$!
  for ((i=0; i<STMO; i++)); do sleep 1; curl -s -o /dev/null -m 3 "$SDD_BASE_URL/" && return 0; done
  echo "FIX FAIL: app did not start"; return 1
}
trap stop_app EXIT
start_app || exit 1
timeout "$TMO" bash -lc "${CMD//\{PROMPT_FILE\}/$P}" >"$OUT/test-fix.log" 2>&1
grep -h "^GAP: " "$OUT/test-fix.log" | sort -u >"$OUT/gaps.txt"
bad=0
for f in $(grep -rlE "@spec[[:space:]]+$NUM\b" "$ACC" 2>/dev/null); do
  timeout 1500 bash -lc "${RUN//\{FILE\}/$f}" >"$OUT/fixcheck.$(basename "$f").log" 2>&1; rc=$?
  if grep -q "@converge" "$f"; then [[ $rc -eq 0 ]] && { echo "CONVERGE FILE PASSES (must fail = real gap): $f"; bad=1; }
  else [[ $rc -ne 0 ]] && { echo "STILL FAILING: $f"; bad=1; }; fi
done
stop_app
node "$HERE/verify_specs.mjs" --spec "$SPEC" >"$OUT/fix.final.txt" 2>&1 || { echo "COVERAGE STILL INCOMPLETE"; tail -4 "$OUT/fix.final.txt"; bad=1; }
publish() { mkdir -p "$MAIN/$SPEC/.sdd"; cp "$OUT"/fixcheck.*.log "$OUT/test-fix.log" "$OUT/gaps.txt" "$OUT/fix.final.txt" "$MAIN/$SPEC/.sdd/" 2>/dev/null; }
[[ $bad -ne 0 ]] && { publish; echo "FIX FAIL (branch $BR kept)"; exit 1; }
rm -f "$P" "$OUT/serve.fix.log"
node "$HERE/lock_tests.mjs" freeze "$SPEC" >/dev/null && git add -A "$ACC" "$SPEC/.sdd" && git commit -qm "sdd($FEAT): retrofit tests repaired and locked" || { echo "FIX FAIL: lock/commit"; exit 1; }
cd "$MAIN" && git clean -fq -- "$SPEC/.sdd" && { git merge -q --ff-only "$BR" 2>/dev/null || git merge -q --no-edit "$BR"; } || { echo "FIX FAIL: merge"; exit 1; }
git worktree remove --force "$WT"; git branch -D "$BR" -q
cat "$MAIN/$SPEC/.sdd/gaps.txt" 2>/dev/null
echo "FIX OK"
