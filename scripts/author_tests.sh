#!/usr/bin/env bash
# author_tests.sh — acceptance tests written by a fresh cheap-model session, red-checked, then locked.
# Usage: author_tests.sh specs/NNN-name [--retrofit]
#   default    : tests MUST FAIL before implementation (proves they measure the new behaviour)
#   --retrofit : tests MUST PASS (they describe behaviour that already exists)
set -uo pipefail
SPEC=${1:?usage: author_tests.sh specs/NNN-name [--retrofit]}; MODE=${2:-}
ROOT=$(pwd); HERE=$(cd "$(dirname "$0")" && pwd); CFG="$ROOT/.sdd/config.json"; OUT="$ROOT/$SPEC/.sdd"; mkdir -p "$OUT"
jqr() { node -e "const c=require('$CFG');const v=$1;process.stdout.write(v==null?'':String(v))"; }
CMD=$(jqr "c.agent.testAuthor"); TMO=$(jqr "(c.agent&&c.agent.timeoutSec)||3600"); ACC=$(jqr "c.acceptanceDir||'tests/acceptance'")
NUM=$(basename "$SPEC" | cut -c1-3)
P="$OUT/prompt.test-author.md"
sed -e "s#{SPEC_DIR}#$SPEC#g" -e "s#{SPEC_NUM}#$NUM#g" -e "s#{ACCEPTANCE_DIR}#$ACC#g" -e "s#{MODE}#${MODE:-new-feature}#g" "$( [[ -d $HERE/prompts ]] && echo $HERE/prompts || echo $HERE/../prompts )/test-author.md" >"$P"
timeout "$TMO" bash -lc "${CMD//\{PROMPT_FILE\}/$P}" >"$OUT/test-author.log" 2>&1
node "$HERE/verify_specs.mjs" --spec "$SPEC" | tail -4
# Red/green check: run each tagged file
FILES=$(grep -rlE "@spec[[:space:]]+$NUM\b" "$ACC" 2>/dev/null || true)
[[ -z "$FILES" ]] && { echo "AUTHOR FAIL: no files tagged @spec $NUM in $ACC"; exit 1; }
RUN=$(jqr "c.acceptanceRun||'node {FILE}'"); bad=0
for f in $FILES; do
  timeout 900 bash -lc "${RUN//\{FILE\}/$f}" >"$OUT/redcheck.$(basename "$f").log" 2>&1; rc=$?
  if [[ "$MODE" == "--retrofit" ]]; then [[ $rc -ne 0 ]] && { echo "RETROFIT FAIL (must pass on existing code): $f"; bad=1; }
  else [[ $rc -eq 0 ]] && { echo "RED FAIL (passes before implementation — measures nothing): $f"; bad=1; }; fi
done
[[ $bad -ne 0 ]] && { echo "Tests not locked. Architect: inspect $OUT/redcheck.*.log"; exit 1; }
node "$HERE/lock_tests.mjs" freeze "$SPEC" && git add -A "$ACC" "$SPEC/.sdd" && git commit -qm "sdd($(basename "$SPEC")): acceptance tests locked" && echo "AUTHOR OK"
