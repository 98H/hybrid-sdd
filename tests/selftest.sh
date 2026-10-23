#!/usr/bin/env bash
# selftest.sh — proves the zero-token gates behave as documented, on a throwaway repo. No model calls.
# Usage: bash tests/selftest.sh     Exit 0 = every expectation met.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd); S="$HERE/scripts"
T=$(mktemp -d); L=$(mktemp); trap 'rm -rf "$T" "$L"' EXIT; cd "$T"
pass=0; fail=0
expect() { # $1 description, $2 expected exit (0|nonzero), rest = command
  local d=$1 want=$2; shift 2; "$@" >"$L" 2>&1; local rc=$?
  if { [[ $want == 0 && $rc == 0 ]] || [[ $want == nonzero && $rc != 0 ]]; }; then echo "ok   - $d"; pass=$((pass+1));
  else echo "FAIL - $d (rc=$rc)"; sed 's/^/       /' "$L" | head -15; fail=$((fail+1)); fi
}
git init -q -b main . && git config user.email t@t && git config user.name t
mkdir -p .sdd src tests/acceptance/001 specs/001-greet/contracts specs/001-greet/checklists
cp "$HERE/templates/sdd.config.json" .sdd/config.json
node -e 'const f=".sdd/config.json",c=require("./"+f);c.build="true";c.test="true";c.acceptanceRun="node {FILE}";c.uiProbe.enabled=false;c.highRisk=["src/auth/**"];require("fs").writeFileSync(f,JSON.stringify(c,null,2))'
S1=specs/001-greet
cat >$S1/spec.md <<'EOF'
# Feature Specification: Greeting
## Requirements
- **FR-001**: greet(name) MUST return "Hello, <name>!".
- **FR-002**: greet("") MUST throw an error with message "name required".
EOF
for f in plan research data-model quickstart review-checklist; do echo "# $f for greeting" >$S1/$f.md; done
echo "# module-api: export function greet(name)" >$S1/contracts/module-api.md
echo "- [x] spec quality ok" >$S1/checklists/requirements.md
cat >$S1/tasks.md <<'EOF'
# Tasks: Greeting
## Phase 1: Core
- [ ] T001 [US1] Implement greet in src/greet.js (FR-001, FR-002)
EOF
echo "export function greet(){ return ''; }" >src/greet.js
git add -A && git commit -qm init

expect "spec gate passes before tests exist (--pre-tests)"          0       node $S/verify_specs.mjs --spec $S1 --pre-tests
expect "spec gate fails when FRs have no acceptance test"           nonzero node $S/verify_specs.mjs --spec $S1
cat >tests/acceptance/001/greet.test.mjs <<'EOF'
// @spec 001
// @covers FR-001, FR-002
import { greet } from '../../../src/greet.js';
let bad = 0;
if (greet('Ada') !== 'Hello, Ada!') { console.log('❌ FR-001 greet Ada'); bad++; }
try { greet(''); console.log('❌ FR-002 no throw'); bad++; } catch (e) { if (e.message !== 'name required') { console.log('❌ FR-002 message'); bad++; } }
process.exit(bad ? 1 : 0);
EOF
expect "acceptance test is RED before implementation"               nonzero node tests/acceptance/001/greet.test.mjs
expect "freeze lock"                                                0       node $S/lock_tests.mjs freeze $S1
git add -A && git commit -qm "tests locked" && git checkout -q -b work
expect "spec gate passes once every FR is covered"                  0       node $S/verify_specs.mjs --spec $S1
expect "gates FAIL on the stub implementation"                      nonzero node $S/gates.mjs $S1 1 1
cat >src/greet.js <<'EOF'
export function greet(name) { if (!name) throw new Error('name required'); return `Hello, ${name}!`; }
EOF
expect "gates PASS with a correct implementation in scope"          0       node $S/gates.mjs $S1 1 1
echo "// tampered" >>tests/acceptance/001/greet.test.mjs
expect "lock gate catches an edited acceptance test"                nonzero node $S/lock_tests.mjs check $S1
git checkout -q -- tests/acceptance/001/greet.test.mjs
echo "x" >src/other.js
expect "scope fence rejects a file outside the phase's task paths"  nonzero node $S/scope_fence.mjs $S1 1
rm src/other.js; echo "tamper" >>$S1/spec.md
expect "scope fence rejects edits to protected specs/"              nonzero node $S/scope_fence.mjs $S1 1
git checkout -q -- $S1/spec.md
expect "scope fence passes again after cleanup"                     0       node $S/scope_fence.mjs $S1 1
sed -i 's/^- \[ \] T001/- [x] T001/; s#src/greet.js#src/missing.js#' $S1/tasks.md
expect "spec gate catches a [x] task citing a missing file"         nonzero node $S/verify_specs.mjs --spec $S1
git checkout -q -- $S1/tasks.md
echo "- [ ] T002 [US1] Add docs in src/greet.js" >>$S1/tasks.md
expect "spec gate catches a task without FR traceability"           nonzero node $S/verify_specs.mjs --spec $S1
git checkout -q -- $S1/tasks.md
test -f $S1/.sdd/phase1.verdict.json; expect "gates wrote verdict.json"            0 test -f $S1/.sdd/phase1.verdict.json
expect "gates wrote feedback.md"                                    0       test -f $S1/.sdd/phase1.feedback.md
echo; echo "selftest: $pass passed, $fail failed"; exit $fail
