#!/usr/bin/env bash
# run_phase.sh — unattended implement → gate → retry → review loop for ONE tasks.md phase.
# Usage: run_phase.sh specs/NNN-name <phase> [--final]      (run from the repository root)
# Isolation: works in a dedicated git worktree (.sdd/worktrees/NNN-phaseN) on branch sdd/NNN-phaseN,
# so the founder's checkout and the running production service are never touched.
# Runs in a separate process from the architect: no implementer output enters the architect's context.
# Result: <worktree>/specs/NNN-name/.sdd/phase<N>.verdict.json (+ feedback.md, review.md), copied back to
# specs/NNN-name/.sdd/ in the main checkout. Exit 0 = PASS, 3 = ESCALATE, 2 = setup error.
set -uo pipefail
SPEC=${1:?usage: run_phase.sh specs/NNN-name <phase> [--final]}; PHASE=${2:?phase number}; FINAL=${3:-}
MAIN=$(pwd); HERE=$(cd "$(dirname "$0")" && pwd); PROMPTS="$HERE/prompts"; [[ -d $PROMPTS ]] || PROMPTS="$HERE/../prompts"
CFG="$MAIN/.sdd/config.json"
jqr() { node -e "const c=require('$CFG');const v=$1;process.stdout.write(v==null?'':String(v))"; }
BASE=$(jqr "c.baseBranch||'main'"); MAX=$(jqr "c.maxAttempts||3"); TMO=$(jqr "(c.agent&&c.agent.timeoutSec)||3600")
IMPL=$(jqr "c.agent.implementer"); PAR=$(jqr "c.parallel===true"); REV=$(jqr "c.agent.reviewer"); SETUP=$(jqr "c.worktreeSetup||''")
FEAT=$(basename "$SPEC"); NUM=${FEAT%%-*}; BR="sdd/$NUM-phase$PHASE"
WT="$MAIN/.sdd/worktrees/$NUM-phase$PHASE"

# ── isolated worktree ─────────────────────────────────────────────────────────
if [[ ! -d $WT ]]; then
  if git rev-parse --verify -q "$BR" >/dev/null; then git worktree add -q "$WT" "$BR" || { echo "cannot add worktree $WT"; exit 2; }
  else git worktree add -q -b "$BR" "$WT" "$BASE" || { echo "cannot create worktree $WT from $BASE"; exit 2; }; fi
  if [[ -n $SETUP ]]; then (cd "$WT" && bash -lc "$SETUP") >"$WT/.sdd-setup.log" 2>&1 || { echo "worktreeSetup failed — see $WT/.sdd-setup.log"; exit 2; }; rm -f "$WT/.sdd-setup.log"; fi
fi
cd "$WT" || exit 2
OUT="$WT/$SPEC/.sdd"; mkdir -p "$OUT"
log() { echo "$(date -u +%FT%TZ) [$FEAT p$PHASE] $*" | tee -a "$OUT/run.log"; }
publish() { mkdir -p "$MAIN/$SPEC/.sdd"; cp "$OUT"/phase$PHASE.* "$OUT/run.log" "$OUT"/hooks.log "$MAIN/$SPEC/.sdd/" 2>/dev/null; }
node "$HERE/lock_tests.mjs" check "$SPEC" >/dev/null || { log "acceptance tests not locked on $BASE — run author_tests.sh and commit first"; exit 2; }

render() { # $1 template, $2 attempt, [$3 file with a task subset, $4 suffix] -> prompt file
  local f="$OUT/prompt.$(basename "$1" .md).p$PHASE.a$2${4:-}.md"
  node -e '
    const fs=require("fs"),[tpl,spec,phase,att,out,fb,sub]=process.argv.slice(1);
    let t=fs.readFileSync(tpl,"utf8");
    const tasks=fs.readFileSync(spec+"/tasks.md","utf8");
    const m=tasks.split(/^## /m).find(s=>new RegExp("^Phase "+phase+"\\b").test(s))||"";
    const body=sub?("## Phase "+phase+" — your share (other tasks of this phase run in parallel sessions; do not touch their files)\n"+fs.readFileSync(sub,"utf8")):"## "+m.trim();
    t=t.replaceAll("{SPEC_DIR}",spec).replaceAll("{PHASE}",phase).replaceAll("{ATTEMPT}",att)
       .replaceAll("{PHASE_TASKS}",body)
       .replaceAll("{FEEDBACK}",fb&&fs.existsSync(fb)?fs.readFileSync(fb,"utf8"):"(first attempt — no feedback)");
    fs.writeFileSync(out,t);' "$1" "$SPEC" "$PHASE" "$2" "$f" "$OUT/phase$PHASE.feedback.md" "${3:-}"
  echo "$f"
}
agent() { # $1 command template, $2 prompt file, $3 log
  local cmd=${1//\{PROMPT_FILE\}/$2}; timeout "$TMO" bash -lc "$cmd" >"$3" 2>&1; echo $? >>"$3"
}
# Spec Kit [P] parallelism (config "parallel": true): on the FIRST attempt, consecutive open [P] tasks whose
# paths are disjoint run as concurrent implementer sessions; other tasks run in order. Retries run the whole
# phase in one session with the gate feedback (merging parallel fixes is not worth the risk).
blocks() { # writes $OUT/blocks/NN.txt (one task per line), prints "NN P|S" per block
  node -e '
    const fs=require("fs"),[spec,phase,dir]=process.argv.slice(1);fs.mkdirSync(dir,{recursive:true});
    const sec=fs.readFileSync(spec+"/tasks.md","utf8").split(/^## /m).find(s=>new RegExp("^Phase "+phase+"\\b").test(s))||"";
    const tasks=sec.split("\n").filter(l=>/^- \[ \] T\d{3}/.test(l));
    const paths=l=>[...l.matchAll(/(?:^|[\s`(])((?:[\w.-]+\/)+[\w.\-]*)(?=[\s`),.;:]|$)/g)].map(m=>m[1]);
    const out=[];let cur=null;
    for(const t of tasks){const p=/\[P\]/.test(t);
      if(p&&cur&&cur.p&&!cur.t.some(x=>paths(x).some(a=>paths(t).includes(a)))){cur.t.push(t);continue;}
      if(!p&&cur&&!cur.p){cur.t.push(t);continue;}
      cur={p,t:[t]};out.push(cur);}
    out.forEach((b,i)=>{const n=String(i+1).padStart(2,"0");
      if(b.p&&b.t.length>1)b.t.forEach((t,j)=>fs.writeFileSync(`${dir}/${n}.${j+1}.txt`,t+"\n"));
      else fs.writeFileSync(`${dir}/${n}.txt`,b.t.join("\n")+"\n");
      console.log(n+" "+(b.p&&b.t.length>1?"P":"S"));});' "$SPEC" "$PHASE" "$OUT/blocks"
}
implement() { # $1 attempt
  local a=$1
  if [[ $a == 1 && $PAR == true ]]; then
    rm -rf "$OUT/blocks"; local plan; plan=$(blocks)
    if grep -q ' P$' <<<"$plan"; then
      while read -r n kind; do
        [[ -z $n ]] && continue
        if [[ $kind == P ]]; then
          local pids=() k=0
          for sub in "$OUT/blocks/$n".*.txt; do k=$((k+1))
            agent "$IMPL" "$(render "$PROMPTS/implementer.md" "$a" "$sub" ".b$n.$k")" "$OUT/impl.p$PHASE.a$a.b$n.$k.log" & pids+=($!)
          done
          log "attempt $a: block $n — ${#pids[@]} [P] tasks in parallel"; wait "${pids[@]}"
        else
          agent "$IMPL" "$(render "$PROMPTS/implementer.md" "$a" "$OUT/blocks/$n.txt" ".b$n")" "$OUT/impl.p$PHASE.a$a.b$n.log"
        fi
      done <<<"$plan"
      cat "$OUT"/impl.p$PHASE.a$a.b*.log >"$OUT/impl.p$PHASE.a$a.log" 2>/dev/null; return
    fi
  fi
  agent "$IMPL" "$(render "$PROMPTS/implementer.md" "$a")" "$OUT/impl.p$PHASE.a$a.log"
}
escalate() {
  node -e 'const fs=require("fs"),f=process.argv[1];const v=fs.existsSync(f)?JSON.parse(fs.readFileSync(f)):{};v.escalate=true;v.reason=process.argv[2];fs.writeFileSync(f,JSON.stringify(v,null,2)+"\n")' "$OUT/phase$PHASE.verdict.json" "$1"
  log "ESCALATE: $1"; git add -A "$OUT" && git commit -qm "sdd($FEAT): phase $PHASE ESCALATE" --allow-empty; publish; exit 3
}

rm -f "$OUT/phase$PHASE.feedback.md"
# Spec Kit extension hooks: before_implement once per phase (mandatory ones executed, fail = setup error).
node "$HERE/hooks.mjs" before_implement "$SPEC" >>"$OUT/run.log" 2>&1 || { log "mandatory before_implement hook failed — see $SPEC/.sdd/hooks.log"; publish; exit 2; }
for ((a=1; a<=MAX; a++)); do
  log "attempt $a/$MAX: implementer"
  implement "$a"
  git add -A && git commit -qm "sdd($FEAT): phase $PHASE attempt $a" --allow-empty
  log "attempt $a: gates"
  if node "$HERE/gates.mjs" "$SPEC" "$PHASE" "$a" $FINAL >"$OUT/gates.p$PHASE.a$a.log" 2>&1; then
    log "attempt $a: gates PASS → reviewer"
    git diff "$BASE"...HEAD -- . ":(exclude)$SPEC/.sdd" >"$OUT/phase$PHASE.diff"
    agent "$REV" "$(render "$PROMPTS/reviewer.md" "$a")" "$OUT/phase$PHASE.review.md"
    if grep -q '^VERDICT: PASS' "$OUT/phase$PHASE.review.md"; then
      node -e '
        const fs=require("fs"),[spec,phase]=process.argv.slice(1);const p=spec+"/tasks.md";let inP=false;
        const out=fs.readFileSync(p,"utf8").split("\n").map(l=>{const h=l.match(/^## Phase (\d+)\b/);if(h)inP=h[1]===phase;return inP?l.replace(/^- \[ \] (T\d{3})/,"- [x] $1"):l;}).join("\n");
        fs.writeFileSync(p,out);' "$SPEC" "$PHASE"
      git add -A && git commit -qm "sdd($FEAT): phase $PHASE PASS (attempt $a)"
      HR=$(node -e 'const v=require(process.argv[1]);process.stdout.write((v.highRisk||[]).join(" "))' "$OUT/phase$PHASE.verdict.json")
      node "$HERE/hooks.mjs" after_implement "$SPEC" >>"$OUT/run.log" 2>&1 || escalate "mandatory after_implement hook failed — see $SPEC/.sdd/hooks.log"
      git add -A && git commit -qm "sdd($FEAT): phase $PHASE hooks" --allow-empty
      [[ -n "$HR" ]] && escalate "PASS but touches high-risk paths: $HR — architect review of phase$PHASE.diff required before merge"
      log "PASS — branch $BR ready to merge"; git add -A "$OUT" && git commit -qm "sdd($FEAT): phase $PHASE log" --allow-empty; publish; exit 0
    fi
    { echo; echo "## FAIL reviewer — checklist violations"; sed -n '/^VERDICT/,$p' "$OUT/phase$PHASE.review.md"; } >>"$OUT/phase$PHASE.feedback.md"
    log "attempt $a: reviewer FAIL"
  else
    log "attempt $a: gates FAIL ($(grep -c '^FAIL' "$OUT/gates.p$PHASE.a$a.log") gate(s))"
  fi
  grep -q '^SPEC_PROBLEM:' "$OUT/impl.p$PHASE.a$a.log" && escalate "implementer reports a spec problem: $(grep -m1 '^SPEC_PROBLEM:' "$OUT/impl.p$PHASE.a$a.log")"
done
escalate "failed $MAX attempts"
