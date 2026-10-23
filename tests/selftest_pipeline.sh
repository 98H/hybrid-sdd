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

# ── Scenario 3: Spec Kit extension hooks ──────────────────────────────────────
git worktree remove --force .sdd/worktrees/001-phase1 && git branch -D sdd/001-phase1 -q && rm -rf $S1/.sdd/phase1.* $S1/.sdd/run.log $S1/.sdd/hooks.log
mkdir -p .specify
cat >.specify/extensions.yml <<'EOS'
hooks:
  before_implement:
    - {extension: lint, command: speckit.lint.check, description: lint, optional: true}
    - {extension: off, command: speckit.off.x, optional: false, enabled: false}
    - {extension: cond, command: speckit.cond.x, optional: false, condition: "config.x"}
  after_implement:
    - {extension: git, command: speckit.git.commit, description: commit, optional: false}
EOS
printf '#!/usr/bin/env bash\ngrep -q "/speckit-git-commit" "$1" && echo ran-hook >>/tmp/sdd_hook_probe_$PPID; echo "HOOK OK"\n' >bin/hook_ok
printf '#!/usr/bin/env bash\necho "HOOK FAIL: nope"\n' >bin/hook_no; chmod +x bin/*
node -e 'const f=".sdd/config.json",c=require("./"+f);c.agent.reviewer="bin/rev_ok {PROMPT_FILE}";c.agent.hookRunner="bin/hook_ok {PROMPT_FILE}";c.hooks={before_implement:["test -f src/greet.js"],after_implement:[]};require("fs").writeFileSync(f,JSON.stringify(c,null,2))'
git add -A && git commit -qm hooks
bash $S/run_phase.sh $S1 1 >/dev/null 2>&1; rc=$?
H=$S1/.sdd/hooks.log
chk "mandatory after_implement hook executed → PASS"         '[[ $rc == 0 ]] && grep -q "ok /speckit-git-commit" $H'
chk "optional hook listed, disabled + conditional skipped"   'grep -q "optional hook listed" $H && grep -q "skip (disabled)" $H && grep -q "skip (condition" $H'
chk "shell hook from .sdd/config.json ran"                   'grep -q "ok shell hook: test -f src/greet.js" $H'
git worktree remove --force .sdd/worktrees/001-phase1 && git branch -D sdd/001-phase1 -q && rm -rf $S1/.sdd/phase1.* $S1/.sdd/run.log $S1/.sdd/hooks.log
node -e 'const f=".sdd/config.json",c=require("./"+f);c.agent.hookRunner="bin/hook_no {PROMPT_FILE}";require("fs").writeFileSync(f,JSON.stringify(c,null,2))'
git add -A && git commit -qm hookfail
bash $S/run_phase.sh $S1 1 >/dev/null 2>&1; rc=$?
chk "failing mandatory hook → ESCALATE, not PASS"            '[[ $rc == 3 ]] && grep -q "after_implement hook failed" $S1/.sdd/phase1.verdict.json'
git worktree remove --force .sdd/worktrees/001-phase1 && git branch -D sdd/001-phase1 -q && rm -rf $S1/.sdd/phase1.* $S1/.sdd/run.log $S1/.sdd/hooks.log
echo "hooks: [broken" >.specify/extensions.yml; git add -A && git commit -qm badyaml
bash $S/run_phase.sh $S1 1 >/dev/null 2>&1; rc=$?
chk "unreadable extensions.yml fails closed (exit 2)"        '[[ $rc == 2 ]] && grep -q "could not be read" $S1/.sdd/hooks.log'
git worktree remove --force .sdd/worktrees/001-phase1 2>/dev/null; git branch -D sdd/001-phase1 -q 2>/dev/null; rm -rf .specify $S1/.sdd/phase1.* $S1/.sdd/run.log $S1/.sdd/hooks.log

# ── Scenario 4: Spec Kit [P] tasks run as parallel implementer sessions ───────
cat >bin/impl_par <<'EOS'
#!/usr/bin/env bash
# writes the file named in its task share; records start/end times to prove overlap
f=$(grep -o 'src/[a-z]*\.js' "$1" | head -1); name=$(basename "$f" .js)
echo "start $name $(date +%s.%N)" >>"$PWD/../../par.trace"; sleep 2
if [[ $name == greet ]]; then echo "export function greet(n){ if(!n) throw new Error('name required'); return \`Hello, \${n}!\`; }" >"$f"
else echo "export const $name = 1;" >"$f"; fi
echo "end $name $(date +%s.%N)" >>"$PWD/../../par.trace"; echo done
EOS
chmod +x bin/impl_par
printf '# Tasks\n## Phase 1: Core\n- [ ] T001 [US1] Implement greet in src/greet.js (FR-001, FR-002)\n- [ ] T002 [P] [US1] Add src/alpha.js (infra)\n- [ ] T003 [P] [US1] Add src/beta.js (infra)\n- [ ] T004 [P] [US1] Add src/gamma.js (infra)\n' >$S1/tasks.md
node -e 'const f=".sdd/config.json",c=require("./"+f);c.parallel=true;c.agent.implementer="bin/impl_par {PROMPT_FILE}";delete c.agent.hookRunner;c.hooks={};require("fs").writeFileSync(f,JSON.stringify(c,null,2))'
echo "par.trace" >>.gitignore; git add -A && git commit -qm par
rm -f .sdd/par.trace; bash $S/run_phase.sh $S1 1 >/dev/null 2>&1; rc=$?
TR=.sdd/par.trace
chk "phase with [P] tasks PASSes, all four tasks ticked"     '[[ $rc == 0 ]] && [[ $(git show sdd/001-phase1:$S1/tasks.md | grep -c "^- \[x\]") == 4 ]]'
chk "[P] tasks ran concurrently (all started before any ended)" 'node -e "const l=require(\"fs\").readFileSync(\"$TR\",\"utf8\").trim().split(\"\\n\").map(x=>x.split(\" \"));const p=[\"alpha\",\"beta\",\"gamma\"];const s=Math.max(...l.filter(x=>x[0]==\"start\"&&p.includes(x[1])).map(x=>+x[2]));const e=Math.min(...l.filter(x=>x[0]==\"end\"&&p.includes(x[1])).map(x=>+x[2]));process.exit(s<e?0:1)"'
chk "sequential task T001 ran before the [P] block"          'node -e "const l=require(\"fs\").readFileSync(\"$TR\",\"utf8\").trim().split(\"\\n\");process.exit(l[1].startsWith(\"end greet\")?0:1)"'

echo; echo "pipeline selftest: $ok passed, $bad failed"; exit $bad
