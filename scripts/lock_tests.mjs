#!/usr/bin/env node
// lock_tests.mjs — freeze or check acceptance-test hashes. Zero model tokens.
// Usage:
//   node lock_tests.mjs freeze specs/NNN-name   # records sha256 of every file tagged "@spec NNN" under acceptanceDir
//   node lock_tests.mjs check  specs/NNN-name   # exit 1 if any locked file changed/removed or a new tagged file appeared
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const [mode, specDir] = process.argv.slice(2);
if (!['freeze', 'check'].includes(mode) || !specDir) { console.error('usage: lock_tests.mjs freeze|check specs/NNN-name'); process.exit(2); }
const ROOT = process.cwd();
const cfgPath = path.join(ROOT, '.sdd', 'config.json');
const cfg = fs.existsSync(cfgPath) ? JSON.parse(fs.readFileSync(cfgPath, 'utf8')) : {};
const ACC = path.join(ROOT, cfg.acceptanceDir || 'tests/acceptance');
const num = path.basename(specDir).slice(0, 3);
const lockFile = path.join(ROOT, specDir, '.sdd', 'tests.lock.json');

const walk = (d) => !fs.existsSync(d) ? [] : fs.readdirSync(d, { withFileTypes: true })
  .flatMap(e => e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]);
const tagged = () => walk(ACC).filter(f => new RegExp(`@spec\\s+${num}\\b`).test(fs.readFileSync(f, 'utf8')));
const sha = (f) => crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');

if (mode === 'freeze') {
  const files = tagged();
  if (!files.length) { console.error(`no acceptance files tagged "@spec ${num}" under ${path.relative(ROOT, ACC)}`); process.exit(1); }
  const lock = { spec: num, frozenAt: new Date().toISOString(), files: Object.fromEntries(files.map(f => [path.relative(ROOT, f), sha(f)])) };
  fs.mkdirSync(path.dirname(lockFile), { recursive: true });
  fs.writeFileSync(lockFile, JSON.stringify(lock, null, 2) + '\n');
  console.log(`LOCKED ${files.length} file(s) -> ${path.relative(ROOT, lockFile)}`);
  process.exit(0);
}
if (!fs.existsSync(lockFile)) { console.log(`LOCK FAIL: no lock file ${path.relative(ROOT, lockFile)}`); process.exit(1); }
const lock = JSON.parse(fs.readFileSync(lockFile, 'utf8'));
const errs = [];
for (const [rel, h] of Object.entries(lock.files)) {
  const f = path.join(ROOT, rel);
  if (!fs.existsSync(f)) errs.push(`removed: ${rel}`);
  else if (sha(f) !== h) errs.push(`modified: ${rel}`);
}
for (const f of tagged()) { const rel = path.relative(ROOT, f); if (!(rel in lock.files)) errs.push(`unlocked new file: ${rel}`); }
console.log(errs.length ? `LOCK FAIL\n - ${errs.join('\n - ')}` : `LOCK OK (${Object.keys(lock.files).length} files)`);
process.exit(errs.length ? 1 : 0);
