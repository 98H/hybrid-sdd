#!/usr/bin/env bash
# selftest_pipeline.sh — run_phase.sh end to end with scripted stand-in agents (no model calls).
# Attempt 1: implementer writes a wrong answer → gates FAIL → feedback. Attempt 2: correct → gates PASS
# → reviewer PASS → tasks ticked → committed. Second scenario: reviewer always FAILs → ESCALATE (exit 3).
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd); S="$HERE/scripts"; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; cd "$T"
git init -q -b main . && git config user.email t@t && git config user.name t
mkdir -p .sdd src tests/acceptance/001 specs/001-greet/contracts specs/001-greet/checklists bin
cp "$HERE/templates/sdd.config.json" .sdd/config.json; echo ".sdd/worktrees/" > .gitignore
cat >bin/impl <<'EOS'
#!/usr/bin/env bash
# stand-in implementer: wrong on attempt 1, right on attempt 2 (attempt read from the prompt file)
if grep -q 'Attempt: 1' "$1"; then echo "export function greet(n){ return 'Hi '+n; }" >src/greet.js
else echo "export function greet(n){ if(!n) throw new Error('name required'); return \`Hello, \${n}!\`; }" >src/greet.js; fi
grep -q 'FAIL acceptance' "$1" && echo "saw feedback"; echo done
EOS
printf '#!/usr/bin/env bash\necho "VERDICT: PASS"\n' >bin/rev_ok
printf '#!/usr/bin/env bash\necho "VERDICT: FAIL"\necho "- [rule 1] src/greet.js:1 — test-specific branch — remove"\n' >bin/rev_no
chmod +x bin/*
node -e 'const f=".sdd/config.json",c=require("./"+f);Object.assign(c,{build:"true",test:"true",acceptanceRun:"node {FILE}"});c.uiProbe.enabled=false;c.alwaysAllowed=["bin/**"];c.worktreeSetup="";c.agent={implementer:"bin/impl {PROMPT_FILE}",testAuthor:"true",reviewer:"bin/rev_ok {PROMPT_FILE}",timeoutSec:60};require("fs").writeFileSync(f,JSON.stringify(c,null,2))'
S1=specs/001-greet
printf '# Spec\n- **FR-001**: greet("Ada") MUST return "Hello, Ada!".\n- **FR-002**: greet("") MUST throw "name required".\n- **SC-001**: all scenarios pass.\n' >$S1/spec.md
for f in plan research data-model quickstart review-checklist; do echo "# $f" >$S1/$f.md; done
echo "# api" >$S1/contracts/module-api.md; echo "- [x] ok" >$S1/checklists/requirements.md
printf '# Tasks\n## Phase 1: Core\n- [ ] T001 [US1] Implement greet in src/greet.js (FR-001, FR-002)\n' >$S1/tasks.md
echo "export function greet(){ return ''; }" >src/greet.js
cat >tests/acceptance/001/greet.test.mjs <<'EOS'
// @spec 001
// @covers FR-001, FR-002
import { greet } from '../../../src/greet.js';
let bad=0; if (greet('Ada')!=='Hello, Ada!'){console.log('❌ FR-001');bad++;}
try{greet('');console.log('❌ FR-002');bad++;}catch(e){if(e.message!=='name required'){console.log('❌ FR-002 msg');bad++;}}
process.exit(bad?1:0);
EOS
node $S/lock_tests.mjs freeze $S1 >/dev/null && git add -A && git commit -qm init
ok=0; bad=0; chk(){ if eval "$2"; then echo "ok   - $1"; ok=$((ok+1)); else echo "FAIL - $1"; bad=$((bad+1)); fi; }
bash $S/run_phase.sh $S1 1 >/dev/null 2>&1; rc=$?
chk "pipeline PASS (exit 0) after one failed attempt"       '[[ $rc == 0 ]]'
chk "attempt 1 gates failed and fed back"                    'grep -q "attempt 1: gates FAIL" .sdd/worktrees/001-phase1/$S1/.sdd/run.log'
chk "attempt 2 implementer received the feedback"            'grep -q "saw feedback" .sdd/worktrees/001-phase1/$S1/.sdd/impl.p1.a2.log'
chk "task T001 ticked by the pipeline (on the phase branch)"  'git show sdd/001-phase1:$S1/tasks.md | grep -q "^- \[x\] T001"'
WT=.sdd/worktrees/001-phase1
chk "work happened in an isolated worktree, main checkout untouched" '[[ $(git branch --show-current) == main ]] && grep -q "return .." src/greet.js && grep -q "Hello" $WT/src/greet.js'
chk "phase committed on branch sdd/001-phase1"               'git log --oneline sdd/001-phase1 | grep -q "phase 1 PASS"'
chk "verdict published back to the main checkout"            'test -f $S1/.sdd/phase1.verdict.json'
chk "verdict.json says pass"                                 'grep -q "\"pass\": true" $S1/.sdd/phase1.verdict.json'

git worktree remove --force .sdd/worktrees/001-phase1 && git branch -D sdd/001-phase1 -q && rm -rf $S1/.sdd/phase1.* $S1/.sdd/run.log
node -e 'const f=".sdd/config.json",c=require("./"+f);c.agent.reviewer="bin/rev_no {PROMPT_FILE}";require("fs").writeFileSync(f,JSON.stringify(c,null,2))'
git add -A && git commit -qm "reviewer strict"
bash $S/run_phase.sh $S1 1 >/dev/null 2>&1; rc=$?
chk "reviewer FAIL x3 → ESCALATE (exit 3)"                   '[[ $rc == 3 ]]'
chk "verdict marked escalate with reason"                    'grep -q "\"escalate\": true" $S1/.sdd/phase1.verdict.json && grep -q "failed 3 attempts" $S1/.sdd/phase1.verdict.json'
chk "task NOT ticked on escalation"                          'git show sdd/001-phase1:$S1/tasks.md | grep -q "^- \[ \] T001"'
echo; echo "pipeline selftest: $ok passed, $bad failed"; exit $bad
