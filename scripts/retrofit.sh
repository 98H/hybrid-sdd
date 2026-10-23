#!/usr/bin/env bash
# retrofit.sh — unattended retrofit pipeline for features whose spec.md the architect has written.
# Usage: retrofit.sh <spec-dir>...        e.g. retrofit.sh specs/001-* specs/003-*
# Per feature, all by the cheap model in separate one-shot processes, judged by zero-token scripts:
#   1. docs   : plan, research, data-model, contracts, quickstart, tasks ([x]), checklists, review-checklist
#   2. gate   : verify_specs.mjs --pre-tests (one docs retry with the gate output as feedback)
#   3. tests  : author_tests.sh --retrofit (tests must PASS on the existing code, then hash-locked)
#   4. final  : verify_specs.mjs (every FR covered by a locked acceptance test)
# Writes .sdd/retrofit/<feature>.status (DOCS_FAIL|GATE_FAIL|TESTS_FAIL|DONE) and a summary table.
# The architect reads only the status files and, for failures, the short gate output.
set -uo pipefail
ROOT=$(pwd); HERE=$(cd "$(dirname "$0")" && pwd); PROMPTS="$HERE/prompts"; [[ -d $PROMPTS ]] || PROMPTS="$HERE/../prompts"
CFG="$ROOT/.sdd/config.json"
jqr() { node -e "const c=require('$CFG');const v=$1;process.stdout.write(v==null?'':String(v))"; }
CMD=$(jqr "(c.agent.docs||c.agent.testAuthor)"); TMO=$(jqr "(c.agent&&c.agent.timeoutSec)||3600")
R="$ROOT/.sdd/retrofit"; mkdir -p "$R"
for SPEC in "$@"; do
  SPEC=${SPEC%/}; F=$(basename "$SPEC"); ST="$R/$F.status"; L="$R/$F.pipeline.log"; : >"$L"
  say() { echo "$(date -u +%FT%TZ) [$F] $*" | tee -a "$L"; }
  [[ -f $SPEC/spec.md ]] || { say "no spec.md"; echo DOCS_FAIL >"$ST"; continue; }
  INV="$R/$F.inventory.md"; [[ -f $INV ]] || INV="(none — read the code directly)"
  ok=0
  for try in 1 2; do
    P="$R/$F.docs.prompt.md"
    node -e 'const fs=require("fs"),[t,o,s,f,i,d,fb]=process.argv.slice(1);let x=fs.readFileSync(t,"utf8").replaceAll("{SPEC_DIR}",s).replaceAll("{FEATURE}",f).replaceAll("{INVENTORY}",i).replaceAll("{DATE}",d);if(fb&&fs.existsSync(fb))x+="\n\n## Gate feedback from your previous attempt (fix every item)\n```\n"+fs.readFileSync(fb,"utf8")+"\n```\n";fs.writeFileSync(o,x)' \
      "$PROMPTS/retrofit-docs.md" "$P" "$SPEC" "$F" "$INV" "$(date -u +%F)" "$( [[ $try == 2 ]] && echo "$R/$F.gate.txt" )"
    say "docs attempt $try"
    timeout "$TMO" bash -lc "${CMD//\{PROMPT_FILE\}/$P}" >"$R/$F.docs.a$try.log" 2>&1
    node "$HERE/verify_specs.mjs" --spec "$SPEC" --pre-tests >"$R/$F.gate.txt" 2>&1 && { ok=1; break; }
    say "gate FAIL: $(grep -c '^     - ' "$R/$F.gate.txt") issue(s)"
  done
  [[ $ok == 1 ]] || { echo GATE_FAIL >"$ST"; say "GATE_FAIL"; continue; }
  git add -A "$SPEC" && git commit -qm "sdd($F): retrofit docs (plan, research, data-model, contracts, quickstart, tasks, checklists)" --allow-empty
  say "tests (retrofit mode)"
  if bash "$HERE/author_tests.sh" "$SPEC" --retrofit >"$R/$F.tests.log" 2>&1 && grep -q "AUTHOR OK" "$R/$F.tests.log"; then
    if node "$HERE/verify_specs.mjs" --spec "$SPEC" >"$R/$F.final.txt" 2>&1; then echo DONE >"$ST"; say "DONE"
    else echo COVERAGE_FAIL >"$ST"; say "COVERAGE_FAIL"; fi
  else echo TESTS_FAIL >"$ST"; say "TESTS_FAIL"; fi
done
echo; for s in "$R"/*.status; do printf '%-34s %s\n' "$(basename "$s" .status)" "$(cat "$s")"; done
