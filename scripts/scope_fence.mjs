#!/usr/bin/env node
// scope_fence.mjs — reject changes outside a phase's declared scope. Zero model tokens.
// Usage: node scope_fence.mjs specs/NNN-name <phase-number> [--base <ref>]
// Allowed = every path (file or directory prefix) cited by tasks in "## Phase <n>" of tasks.md
//           + cfg.alwaysAllowed + specs/NNN-name/tasks.md (ticking) + specs/NNN-name/.sdd/
// Forbidden = cfg.protected globs (checked first; tasks.md/.sdd of this spec are exempt).
import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';

const a = process.argv.slice(2);
const [specDir, phaseArg] = a;
const base = a.includes('--base') ? a[a.indexOf('--base') + 1] : null;
if (!specDir || !phaseArg) { console.error('usage: scope_fence.mjs specs/NNN-name <phase> [--base ref]'); process.exit(2); }
const ROOT = process.cwd();
const cfgPath = path.join(ROOT, '.sdd', 'config.json');
const cfg = fs.existsSync(cfgPath) ? JSON.parse(fs.readFileSync(cfgPath, 'utf8')) : {};
const baseRef = base || cfg.baseBranch || 'main';

const globRe = (g) => new RegExp('^' + g.split('**').map(s => s.split('*').map(x => x.replace(/[.+?^${}()|[\]\\]/g, '\\$&')).join('[^/]*')).join('.*') + '$');
const matchAny = (p, globs) => (globs || []).some(g => globRe(g).test(p));

const tasks = fs.readFileSync(path.join(specDir, 'tasks.md'), 'utf8').split('\n');
let inPhase = false; const allowed = new Set();
for (const line of tasks) {
  const h = line.match(/^## Phase (\d+)\b/);
  if (h) { inPhase = h[1] === String(phaseArg); continue; }
  if (!inPhase || !/^- \[( |x|X)\] T\d{3}/.test(line)) continue;
  for (const m of line.matchAll(/(?:^|[\s`(])((?:[\w.-]+\/)+[\w.\-]*)(?=[\s`),.;:]|$)/g)) allowed.add(m[1].replace(/:\d+$/, ''));
}
if (!allowed.size) { console.log(`SCOPE FAIL: phase ${phaseArg} has no task paths in ${specDir}/tasks.md`); process.exit(1); }
const exempt = [path.join(specDir, 'tasks.md'), path.join(specDir, '.sdd') + '/'];

const changed = execSync(`git diff --name-only ${baseRef}...HEAD && git diff --name-only && git ls-files --others --exclude-standard`, { encoding: 'utf8' })
  .split('\n').map(s => s.trim()).filter(Boolean);
const uniq = [...new Set(changed)];
const violations = [];
for (const f of uniq) {
  if (exempt.some(e => f === e || f.startsWith(e))) continue;
  if (matchAny(f, cfg.protected)) { violations.push(`protected: ${f}`); continue; }
  if (matchAny(f, cfg.alwaysAllowed)) continue;
  const ok = [...allowed].some(p => f === p || (p.endsWith('/') ? f.startsWith(p) : f.startsWith(p + '/')));
  if (!ok) violations.push(`out of scope: ${f}`);
}
const high = uniq.filter(f => matchAny(f, cfg.highRisk));
console.log(violations.length ? `SCOPE FAIL\n - ${violations.join('\n - ')}` : `SCOPE OK (${uniq.length} changed file(s), ${allowed.size} allowed path(s))`);
if (high.length) console.log(`HIGH_RISK ${high.join(' ')}`);
process.exit(violations.length ? 1 : 0);
