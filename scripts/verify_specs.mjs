#!/usr/bin/env node
// verify_specs.mjs — Spec gate. Zero model tokens.
// Usage: node verify_specs.mjs [--root DIR] [--spec specs/NNN-name] [--pre-tests]
// Checks per specs/NNN-name/:
//  1. required artifacts exist
//  2. no template placeholders remain
//  3. at most 3 [NEEDS CLARIFICATION] markers
//  4. task lines: "- [ ] T001 [P] [US1] text", unique IDs
//  5. every path cited in a DONE ([x]) task exists
//  6. every task cites at least one FR-xxx that exists in spec.md, or is tagged "(infra)" for
//     setup/foundational/polish work that serves no single requirement (traceability)
//  7. spec.md has at least one SC-xxx success criterion (Spec Kit mandatory section)
//  8. every checklist under checklists/ is fully checked (same gate as /speckit-implement step 2)
//  9. (unless --pre-tests) every FR in spec.md is covered by an acceptance test with "@covers FR-xxx"
// Exit 0 only if every checked spec passes.
import fs from 'node:fs';
import path from 'node:path';

const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const ROOT = path.resolve(opt('--root', process.cwd()));
const ONLY = opt('--spec', null);
const PRE_TESTS = args.includes('--pre-tests');
const cfgPath = path.join(ROOT, '.sdd', 'config.json');
const cfg = fs.existsSync(cfgPath) ? JSON.parse(fs.readFileSync(cfgPath, 'utf8')) : {};
const ACC_DIR = path.join(ROOT, cfg.acceptanceDir || 'tests/acceptance');

const REQUIRED = ['spec.md', 'plan.md', 'research.md', 'data-model.md', 'quickstart.md', 'tasks.md', 'review-checklist.md', 'contracts', 'checklists/requirements.md'];
const PLACEHOLDERS = [/\[FEATURE( NAME)?\]/, /\[DATE\]/, /\[###-feature-name\]/, /ACTION REQUIRED/, /\[REMOVE IF UNUSED\]/, /\$ARGUMENTS/];
const TASK_RE = /^- \[( |x|X)\] (T\d{3})( \[P\])?( \[US\d+\])? \S/;
const PATH_RE = /(?:^|[\s`(])((?:[\w.-]+\/)+[\w.\-\[\]*]+\.\w+|(?:[\w.-]+\/)+)(?=[\s`),.;:]|$)/g;
const FR_RE = /\bFR-\d{3}\b/g;

const walk = (dir) => !fs.existsSync(dir) ? [] : fs.readdirSync(dir, { withFileTypes: true })
  .flatMap(e => e.isDirectory() ? walk(path.join(dir, e.name)) : [path.join(dir, e.name)]);
const coverage = new Map(); // FR -> files (global ids are namespaced by spec dir via "NNN:FR-xxx")
for (const f of walk(ACC_DIR)) {
  const txt = fs.readFileSync(f, 'utf8');
  const specTag = (txt.match(/@spec\s+(\d{3})/) || [])[1] || '*';
  for (const m of txt.matchAll(/@covers\s+([^\n*]+)/g))
    for (const fr of (m[1].match(FR_RE) || [])) {
      const key = `${specTag}:${fr}`; if (!coverage.has(key)) coverage.set(key, []); coverage.get(key).push(path.relative(ROOT, f));
    }
}

const SPECS = path.join(ROOT, 'specs');
let dirs = fs.existsSync(SPECS) ? fs.readdirSync(SPECS).filter(d => /^\d{3}-/.test(d)).sort() : [];
if (ONLY) dirs = dirs.filter(d => path.join('specs', d) === path.normalize(ONLY) || d === path.basename(ONLY));

let failed = 0; const rows = [];
for (const d of dirs) {
  const base = path.join(SPECS, d); const num = d.slice(0, 3); const errs = [];
  for (const r of REQUIRED) if (!fs.existsSync(path.join(base, r))) errs.push(`missing ${r}`);
  if (fs.existsSync(path.join(base, 'contracts')) && fs.readdirSync(path.join(base, 'contracts')).length === 0) errs.push('contracts/ empty');
  for (const f of ['spec.md', 'plan.md', 'tasks.md', 'data-model.md', 'research.md', 'quickstart.md', 'review-checklist.md']) {
    const fp = path.join(base, f); if (!fs.existsSync(fp)) continue;
    const txt = fs.readFileSync(fp, 'utf8');
    for (const re of PLACEHOLDERS) if (re.test(txt)) errs.push(`${f}: placeholder ${re}`);
  }
  const specTxt = fs.existsSync(path.join(base, 'spec.md')) ? fs.readFileSync(path.join(base, 'spec.md'), 'utf8') : '';
  const nc = (specTxt.match(/\[NEEDS CLARIFICATION/g) || []).length;
  if (nc > 3) errs.push(`spec.md: ${nc} NEEDS CLARIFICATION (>3)`);
  const specFRs = new Set(specTxt.match(FR_RE) || []);
  if (specFRs.size === 0) errs.push('spec.md: no FR-xxx requirements');
  if (!/\bSC-\d{3}\b/.test(specTxt)) errs.push('spec.md: no SC-xxx success criteria');
  const clDir = path.join(base, 'checklists');
  for (const f of walk(clDir).filter(f => f.endsWith('.md'))) {
    const open = (fs.readFileSync(f, 'utf8').match(/^\s*- \[ \]/gm) || []).length;
    if (open) errs.push(`checklist ${path.relative(base, f)}: ${open} unchecked item(s)`);
  }

  let done = 0, open = 0; const missing = [], untraced = [], unknownFR = [];
  const tasksFp = path.join(base, 'tasks.md');
  if (fs.existsSync(tasksFp)) {
    const ids = new Set(); let inFence = false;
    for (const line of fs.readFileSync(tasksFp, 'utf8').split('\n')) {
      if (line.trim().startsWith('```')) { inFence = !inFence; continue; }
      if (inFence || !/^- \[( |x|X)\]/.test(line)) continue;
      const m = line.match(TASK_RE);
      if (!m) { errs.push(`tasks.md bad format: ${line.slice(0, 70)}`); continue; }
      if (ids.has(m[2])) errs.push(`tasks.md duplicate ${m[2]}`); ids.add(m[2]);
      const frs = line.match(FR_RE) || [];
      if (frs.length === 0 && !/\(infra\)/.test(line)) untraced.push(m[2]);
      for (const fr of frs) if (!specFRs.has(fr)) unknownFR.push(`${m[2]}:${fr}`);
      if (m[1] === ' ') { open++; continue; }
      done++;
      for (const mm of line.matchAll(PATH_RE)) {
        const p = mm[1].replace(/:\d+(-\d+)?$/, '');
        if (/[*\[\]]/.test(p) || /^https?:/.test(p)) continue;
        if (!fs.existsSync(path.join(ROOT, p))) missing.push(`${m[2]}:${p}`);
      }
    }
  }
  if (missing.length) errs.push(`[x] tasks cite missing paths: ${missing.slice(0, 8).join(', ')}${missing.length > 8 ? ` (+${missing.length - 8})` : ''}`);
  if (untraced.length) errs.push(`tasks without FR reference: ${untraced.slice(0, 12).join(', ')}${untraced.length > 12 ? ` (+${untraced.length - 12})` : ''}`);
  if (unknownFR.length) errs.push(`tasks cite FRs absent from spec.md: ${unknownFR.slice(0, 8).join(', ')}`);
  let uncovered = [];
  if (!PRE_TESTS) {
    uncovered = [...specFRs].filter(fr => !coverage.has(`${num}:${fr}`) && !coverage.has(`*:${fr}`));
    if (uncovered.length) errs.push(`FRs without acceptance test (@spec ${num} @covers ...): ${uncovered.join(', ')}`);
  }
  if (errs.length) failed++;
  rows.push(`${errs.length ? 'FAIL' : 'PASS'} ${d}  FRs=${specFRs.size} tasks done=${done} open=${open}${errs.length ? '\n     - ' + errs.join('\n     - ') : ''}`);
}
console.log(rows.join('\n'));
console.log(`\nSPECS=${dirs.length} PASS=${dirs.length - failed} FAIL=${failed}${PRE_TESTS ? ' (pre-tests mode: FR coverage not checked)' : ''}`);
process.exit(failed || dirs.length === 0 ? 1 : 0);
