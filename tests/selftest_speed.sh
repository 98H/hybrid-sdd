#!/usr/bin/env bash
# selftest_speed.sh — proves the time optimisations keep every gate's strength. No model calls.
#  1. acceptance lanes run concurrently; files inside one lane stay sequential; a failing file in any lane fails the gate
#  2. fail fast: a lock/scope failure skips build/unit/serve/acceptance/regression (reported as "not run")
#  3. regression is skipped when an earlier gate failed, and runs when all earlier gates pass
#  4. the reviewer starts BEFORE regression ends (overlap) and its verdict still decides the phase
#  5. a regression failure after a reviewer PASS still fails the attempt (no gate weakened)
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd); S="$HERE/scripts"; T=${KEEP:-$(mktemp -d)}; [[ -z ${KEEP:-} ]] && trap 'rm -rf "$T" "$T.logs"' EXIT; mkdir -p $T; L=$T.logs; mkdir -p $L; cd "$T"
ok=0; bad=0; chk(){ if eval "$2"; then echo "ok   - $1"; ok=$((ok+1)); else echo "FAIL - $1"; bad=$((bad+1)); fi; }
git init -q -b main . && git config user.email t@t && git config user.name t
mkdir -p .sdd src tests/acceptance/001 specs/001-greet/contracts specs/001-greet/checklists bin
cp "$HERE/templates/sdd.config.json" .sdd/config.json; printf '.sdd/worktrees/\ntrace\n' > .gitignore
S1=specs/001-greet
printf '# Spec\n- **FR-001**: greet("Ada") MUST return "Hello, Ada!".\n- **FR-002**: a.\n- **FR-003**: b.\n- **SC-001**: all pass.\n' >$S1/spec.md
for f in plan research data-model quickstart review-checklist; do echo "# $f" >$S1/$f.md; done
echo "# api" >$S1/contracts/module-api.md; echo "- [x] ok" >$S1/checklists/requirements.md
printf '# Tasks\n## Phase 1: Core\n- [ ] T001 [US1] Implement greet in src/greet.js (FR-001, FR-002, FR-003)\n' >$S1/tasks.md
echo "export function greet(n){ return \`Hello, \${n}!\`; }" >src/greet.js
# three acceptance files, each sleeps 3 s and logs start/end; a and b share lane "slow", c is alone
for x in a b c; do cat >tests/acceptance/001/$x.test.mjs <<EOS
// @spec 001
// @covers FR-001, FR-002, FR-003
import fs from 'node:fs'; const T=process.env.TRACE;
fs.appendFileSync(T, 'start $x '+Date.now()+'\n'); await new Promise(r=>setTimeout(r,3000));
fs.appendFileSync(T, 'end $x '+Date.now()+'\n');
if (process.env.FAIL_FILE==='$x') console.log('❌ forced failure in $x');
EOS
done
node -e 'const f=".sdd/config.json",c=require("./"+f);Object.assign(c,{build:"true",test:"true",worktreeSetup:"",acceptanceRun:"node {FILE}",acceptanceParallel:3,acceptanceLanes:[{name:"slow",match:"/(a|b)\\.test"}],regression:"echo reg-start $(date +%s%3N) >>$TRACE; sleep 6; echo reg-end $(date +%s%3N) >>$TRACE; test -z \"$REG_FAIL\""});c.uiProbe.enabled=false;c.alwaysAllowed=["bin/**"];require("fs").writeFileSync(f,JSON.stringify(c,null,2))'
node $S/lock_tests.mjs freeze $S1 >/dev/null && git add -A && git commit -qm init && git checkout -q -b work
export TRACE=$L/trace
# gate-only scenarios run on a work branch with the phase's file changed and the task ticked (as after an implementer run)
echo "// impl" >>src/greet.js; git add -A; git commit -qm impl

# 1. lanes
: >$TRACE; node $S/gates.mjs $S1 1 1 >$L/g1.log 2>&1; rc=$?
chk "gates PASS with lanes" '[[ $rc == 0 ]]'
chk "lane 'slow' is sequential (b starts after a ends)" 'node -e "const l=require(\"fs\").readFileSync(\"$TRACE\",\"utf8\").trim().split(\"\\n\").map(x=>x.split(\" \"));const g=(k,n)=>+l.find(x=>x[0]==k&&x[1]==n)[2];process.exit(g(\"start\",\"b\")>=g(\"end\",\"a\")?0:1)"'
chk "lanes run concurrently (c starts before a ends)" 'node -e "const l=require(\"fs\").readFileSync(\"$TRACE\",\"utf8\").trim().split(\"\\n\").map(x=>x.split(\" \"));const g=(k,n)=>+l.find(x=>x[0]==k&&x[1]==n)[2];process.exit(g(\"start\",\"c\")<g(\"end\",\"a\")?0:1)"'
chk "verdict records per-gate seconds" 'grep -q "\"sec\":" $S1/.sdd/phase1.verdict.json && grep -q "\"totalSec\":" $S1/.sdd/phase1.verdict.json'
: >$TRACE; FAIL_FILE=b node $S/gates.mjs $S1 1 1 >$L/g2.log 2>&1; rc=$?
chk "a failure marker in one lane fails the acceptance gate" '[[ $rc != 0 ]] && grep -q "FAIL acceptance" $L/g2.log && grep -q "b.test.mjs" $L/g2.log'

# 2. fail fast on lock
echo "// tamper" >>tests/acceptance/001/c.test.mjs
: >$TRACE; node $S/gates.mjs $S1 1 1 --final >$L/g3.log 2>&1; rc=$?
chk "tampered test → lock FAIL, later gates not run" '[[ $rc != 0 ]] && grep -q "FAIL lock" $L/g3.log && grep -q "FAIL build .*not run" $L/g3.log && grep -q "FAIL acceptance .*not run" $L/g3.log'
chk "regression not started when an earlier gate failed" '! grep -q reg-start $TRACE'
git checkout -q -- tests/acceptance/001/c.test.mjs

# 3. regression runs when everything before it passes (--final needs every task ticked: tick on a temporary base)
MAIN0=$(git rev-parse main); sed -i 's/^- \[ \] T001/- [x] T001/' $S1/tasks.md; git add -A; git commit -qm tick -q; git branch -f main HEAD
: >$TRACE; node $S/gates.mjs $S1 1 1 --final >$L/g4.log 2>&1; rc=$?
git branch -f main $MAIN0; git reset -q --hard HEAD~1
chk "--final with all gates green runs regression and PASSes" '[[ $rc == 0 ]] && grep -q "PASS regression" $L/g4.log && grep -q reg-start $TRACE'

# 4. reviewer overlaps regression and still decides (pipeline scenarios start from main)
git checkout -q main
cat >bin/impl <<'EOS'
#!/usr/bin/env bash
echo "export function greet(n){ return \`Hello, \${n}!\`; } // v2" >src/greet.js; echo done
EOS
cat >bin/rev <<'EOS'
#!/usr/bin/env bash
echo "rev-start $(date +%s%3N)" >>"$TRACE"; sleep 1; echo "VERDICT: ${REV_VERDICT:-PASS}"
EOS
chmod +x bin/*
node -e 'const f=".sdd/config.json",c=require("./"+f);c.agent={implementer:"bin/impl {PROMPT_FILE}",testAuthor:"true",reviewer:"bin/rev {PROMPT_FILE}",timeoutSec:60};c.maxAttempts=1;require("fs").writeFileSync(f,JSON.stringify(c,null,2))'
git add -A && git commit -qm agents
: >$TRACE; bash $S/run_phase.sh $S1 1 --final >/dev/null 2>&1; rc=$?
chk "pipeline PASS with overlapped reviewer" '[[ $rc == 0 ]] && grep -q "started before regression" .sdd/worktrees/001-phase1/$S1/.sdd/run.log'
chk "reviewer started before regression ended" 'node -e "const t=require(\"fs\").readFileSync(\"$TRACE\",\"utf8\");const r=+t.match(/rev-start (\d+)/)[1],e=+t.match(/reg-end (\d+)/)[1];process.exit(r<e?0:1)"'
git worktree remove --force .sdd/worktrees/001-phase1; git branch -D sdd/001-phase1 -q; rm -rf $S1/.sdd/phase1.* $S1/.sdd/run.log
: >$TRACE; REV_VERDICT=FAIL bash $S/run_phase.sh $S1 1 --final >/dev/null 2>&1; rc=$?
chk "overlapped reviewer FAIL still blocks the phase (ESCALATE after max attempts)" '[[ $rc == 3 ]] && git show sdd/001-phase1:$S1/tasks.md | grep -q "^- \[ \] T001"'
git worktree remove --force .sdd/worktrees/001-phase1; git branch -D sdd/001-phase1 -q; rm -rf $S1/.sdd/phase1.* $S1/.sdd/run.log

# 5. regression failure after reviewer PASS still fails
: >$TRACE; REG_FAIL=1 bash $S/run_phase.sh $S1 1 --final >/dev/null 2>&1; rc=$?
chk "regression FAIL after reviewer PASS → attempt fails (not merged)" '[[ $rc == 3 ]] && grep -q "gates FAIL" .sdd/worktrees/001-phase1/$S1/.sdd/run.log && git show sdd/001-phase1:$S1/tasks.md | grep -q "^- \[ \] T001"'

echo; echo "speed selftest: $ok passed, $bad failed"; exit $bad
