#!/usr/bin/env bash
# recon.sh — retrofit inventory by the CHEAP model, so the architect never has to read the codebase.
# Usage: recon.sh <areas.tsv> [concurrency]
#   areas.tsv: one area per line: NNN-name<TAB>hints (files/dirs/keywords to start from)
# Output: .sdd/retrofit/NNN-name.inventory.md per area (+ .log). Runs each area as a separate one-shot
# process with agent.recon (default agent.testAuthor). Exit 0 only if every inventory exists and the
# agent printed "RECON OK".
set -uo pipefail
LIST=${1:?usage: recon.sh areas.tsv [concurrency]}; PAR=${2:-3}
ROOT=$(pwd); HERE=$(cd "$(dirname "$0")" && pwd); PROMPTS="$HERE/prompts"; [[ -d $PROMPTS ]] || PROMPTS="$HERE/../prompts"
CFG="$ROOT/.sdd/config.json"
jqr() { node -e "const c=require('$CFG');const v=$1;process.stdout.write(v==null?'':String(v))"; }
CMD=$(jqr "(c.agent.recon||c.agent.testAuthor)"); TMO=$(jqr "(c.agent&&c.agent.timeoutSec)||3600"); MAXL=$(jqr "c.reconMaxLines||220")
OUT="$ROOT/.sdd/retrofit"; mkdir -p "$OUT"
one() {
  local area=$1 hints=$2 f="$OUT/$1.inventory.md" p="$OUT/$1.prompt.md"
  node -e 'const fs=require("fs"),[t,o,a,h,f,m]=process.argv.slice(1);fs.writeFileSync(o,fs.readFileSync(t,"utf8").replaceAll("{AREA}",a).replaceAll("{HINTS}",h).replaceAll("{OUT_FILE}",f).replaceAll("{MAX_LINES}",m))' \
    "$PROMPTS/recon.md" "$p" "$area" "$hints" "$f" "$MAXL"
  for try in 1 2; do
    timeout "$TMO" bash -lc "${CMD//\{PROMPT_FILE\}/$p}" >"$OUT/$area.log" 2>&1
    [[ -s $f ]] && grep -q "RECON OK" "$OUT/$area.log" && { echo "ok   $area ($(wc -l <"$f") lines)"; return 0; }
    sleep 20
  done
  echo "FAIL $area — see $OUT/$area.log"; return 1
}
export -f one; export OUT PROMPTS CMD TMO MAXL
fail=0; running=0
while IFS=$'\t' read -r area hints; do
  [[ -z $area || $area == \#* ]] && continue
  one "$area" "$hints" & running=$((running+1))
  if (( running >= PAR )); then wait -n || fail=1; running=$((running-1)); fi
done <"$LIST"
while (( running > 0 )); do wait -n || fail=1; running=$((running-1)); done
[[ $fail == 0 ]] && echo "RECON ALL OK" || echo "RECON INCOMPLETE"
exit $fail
