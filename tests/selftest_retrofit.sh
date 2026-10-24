#!/usr/bin/env bash
# selftest_retrofit.sh — author_tests.sh (worktree + app served from the worktree + red/green + lock + ff-merge)
# and retrofit.sh (docs → gate → retrofit tests → coverage) with scripted stand-in agents (no model calls).
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd); S="$HERE/scripts"; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; cd "$T"
git init -q -b main . && git config user.email t@t && git config user.name t
mkdir -p .sdd src specs/001-greet bin; S1=specs/001-greet
cp "$HERE/templates/sdd.config.json" .sdd/config.json; echo ".sdd/worktrees/" > .gitignore
echo "export function greet(n){ if(!n) throw new Error('name required'); return \`Hello, \${n}!\`; }" >src/greet.js
# stand-in app: serves the worktree's src/greet.js result; proves the test hit the worktree instance
cat >bin/app.mjs <<'EOS'
// sdd-selftest-app
import http from 'node:http'; import { greet } from '../src/greet.js';
http.createServer((q, r) => r.end(JSON.stringify({ cwd: process.cwd(), msg: greet('Ada') }))).listen(process.env.SDD_PORT);
EOS
# stand-in test author: writes a retrofit test that calls the served app
cat >bin/author <<'EOS'
#!/usr/bin/env bash
mkdir -p tests/acceptance/001
cat >tests/acceptance/001/greet.test.mjs <<'EOT'
// @spec 001
// @covers FR-001, FR-002
import { greet } from '../../../src/greet.js';
const r = await (await fetch(process.env.SDD_BASE_URL + '/')).json();
let bad = 0;
if (r.msg !== 'Hello, Ada!') { console.log('❌ FR-001 served'); bad = 1; }
if (!r.cwd.includes('.sdd/worktrees/001-tests')) { console.log('❌ app not served from the worktree: ' + r.cwd); bad = 1; }
try { greet(''); console.log('❌ FR-002'); bad = 1; } catch (e) { if (e.message !== 'name required') { console.log('❌ FR-002 msg'); bad = 1; } }
process.exit(bad);
EOT
echo done
EOS
# stand-in docs writer: complete docs on attempt 2 only (attempt 1 omits tasks.md → gate feedback loop)
cat >bin/docs <<'EOS'
#!/usr/bin/env bash
d=specs/001-greet; mkdir -p $d/contracts $d/checklists
for f in plan research data-model quickstart review-checklist; do echo "# $f" >$d/$f.md; done
echo "# api" >$d/contracts/module-api.md; echo "- [x] ok" >$d/checklists/requirements.md
if grep -q "Gate feedback" "$1"; then printf '# Tasks\n## Phase 1: Core\n- [x] T001 [US1] Implement greet in src/greet.js (FR-001, FR-002)\n' >$d/tasks.md; fi
echo "DOCS OK"
EOS
chmod +x bin/author bin/docs
node -e 'const f=".sdd/config.json",c=require("./"+f);Object.assign(c,{build:"true",test:"true",acceptanceRun:"node {FILE}",worktreeSetup:"",serve:"node bin/app.mjs",servePort:18961,serveTimeoutSec:20});c.uiProbe.enabled=false;c.agent={implementer:"true",testAuthor:"bin/author {PROMPT_FILE}",docs:"bin/docs {PROMPT_FILE}",reviewer:"true",timeoutSec:60};require("fs").writeFileSync(f,JSON.stringify(c,null,2))'
printf '# Spec\n- **FR-001**: greet("Ada") MUST return "Hello, Ada!".\n- **FR-002**: greet("") MUST throw "name required".\n- **SC-001**: all scenarios pass.\n' >$S1/spec.md
git add -A && git commit -qm init
pass=0; fail=0
chk() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; pass=$((pass+1)); else echo "FAIL - $1"; fail=$((fail+1)); fi; }

bash $S/retrofit.sh $S1 >run.log 2>&1
R=.sdd/retrofit
chk "docs writer got gate feedback and fixed tasks.md on attempt 2" 'grep -q "docs attempt 2" $R/001-greet.pipeline.log && test -f $S1/tasks.md'
chk "retrofit tests written in an isolated worktree against the worktree app" 'grep -q "AUTHOR OK" $R/001-greet.tests.log'
chk "tests locked and fast-forwarded into the checkout"            'test -f $S1/.sdd/tests.lock.json && git log --oneline | grep -q "acceptance tests locked (--retrofit)"'
chk "worktree and temp branch cleaned up"                          '! test -d .sdd/worktrees/001-tests && ! git rev-parse -q --verify sdd/001-tests'
chk "full coverage gate passed → status DONE"                      'grep -qx DONE $R/001-greet.status'
chk "no app instance left running"                                 '! ss -ltnH "sport = :18961" | grep -q .'

# retrofit test that fails on existing code must NOT be locked
sed -i "s/Hello, Ada!/Hi, Ada!/" bin/author; git add -A && git commit -qm breaktest
rm -f $S1/.sdd/tests.lock.json; rm -rf tests/acceptance; git add -A && git commit -qm reset
bash $S/author_tests.sh $S1 --retrofit >at.log 2>&1; rc=$?
chk "retrofit test failing on existing code → not locked (exit 1)" '[[ $rc == 1 ]] && grep -q "RETROFIT FAIL" at.log && ! test -f $S1/.sdd/tests.lock.json'
chk "failure logs published to the checkout"                       'ls $S1/.sdd/redcheck.*.log'
echo; echo "retrofit selftest: $pass passed, $fail failed"; exit $fail
