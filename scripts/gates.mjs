#!/usr/bin/env node
// gates.mjs — run every gate for one phase, write verdict.json + feedback.md. Zero model tokens.
// Usage: node gates.mjs specs/NNN-name <phase> <attempt> [--final]
// Run from the feature worktree root. Fail closed: a gate that crashes or times out is a FAIL.
// If cfg.serve is set, the app under test is started from THIS working tree on cfg.servePort and
// SDD_BASE_URL / SDD_PORT are exported to acceptance tests and the UI probe, so the gates never
// test a production instance that is still running old code.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync, spawn } from 'node:child_process';

const [specDir, phase, attempt = '1'] = process.argv.slice(2);
const FINAL = process.argv.includes('--final');
if (!specDir || !phase) { console.error('usage: gates.mjs specs/NNN-name <phase> <attempt> [--final]'); process.exit(2); }
const ROOT = process.cwd();
const HERE = path.dirname(new URL(import.meta.url).pathname);
const cfg = JSON.parse(fs.readFileSync(path.join(ROOT, '.sdd', 'config.json'), 'utf8'));
const outDir = path.join(ROOT, specDir, '.sdd');
fs.mkdirSync(outDir, { recursive: true });
const num = path.basename(specDir).slice(0, 3);
const markers = cfg.failureMarkers || [];
// A marker prefixed with "re:" is a regular expression; otherwise a literal substring.
const hit = (txt, m) => m.startsWith('re:') ? new RegExp(m.slice(3), 'm').test(txt) : txt.includes(m);
const port = cfg.servePort || 0;
const env = { ...process.env, ...(cfg.serve ? { SDD_PORT: String(port), SDD_BASE_URL: `http://127.0.0.1:${port}` } : {}) };

function run(name, cmd, { markersApply = false, timeout = 1800 } = {}) {
  if (!cmd) return { name, pass: true, summary: 'not configured (skipped)', out: '' };
  const r = spawnSync('bash', ['-lc', cmd], { cwd: ROOT, env, encoding: 'utf8', timeout: timeout * 1000, maxBuffer: 64 * 1024 * 1024 });
  const out = `${r.stdout || ''}${r.stderr || ''}`;
  const hits = markersApply ? markers.filter(m => hit(out, m)) : [];
  const timedOut = r.error && r.error.code === 'ETIMEDOUT';
  const pass = r.status === 0 && !timedOut && hits.length === 0;
  const summary = timedOut ? `timed out after ${timeout}s` : r.status !== 0 ? `exit ${r.status}` : hits.length ? `failure markers: ${hits.join(', ')}` : 'ok';
  return { name, pass, summary, out };
}
const node = (s, a) => `node ${JSON.stringify(path.join(HERE, s))} ${a}`;

let server = null;
async function startServer() {
  if (!cfg.serve) return { name: 'serve', pass: true, summary: 'not configured (skipped)', out: '' };
  const log = path.join(outDir, `serve.p${phase}.a${attempt}.log`);
  const fd = fs.openSync(log, 'w');
  server = spawn('bash', ['-lc', cfg.serve], { cwd: ROOT, env, detached: true, stdio: ['ignore', fd, fd] });
  const url = `http://127.0.0.1:${port}${cfg.serveReadyPath || '/'}`;
  for (let i = 0; i < (cfg.serveTimeoutSec || 60); i++) {
    await new Promise(r => setTimeout(r, 1000));
    try { const r = await fetch(url); if (r.status < 500) return { name: 'serve', pass: true, summary: `up on :${port}`, out: '' }; } catch { /* not yet */ }
    if (server.exitCode !== null) break;
  }
  return { name: 'serve', pass: false, summary: `app did not answer ${url}`, out: fs.readFileSync(log, 'utf8').slice(-3000) };
}
function stopServer() {
  if (server && server.exitCode === null) { try { process.kill(-server.pid, 'SIGTERM'); } catch { /* gone */ } }
  // fail-safe: nothing may keep listening on the test port after the gates
  if (cfg.serve && port) spawnSync('bash', ['-c', `ss -ltnpH "sport = :${port}" | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u | xargs -r kill`]);
  server = null;
}
process.on('exit', stopServer);

const accFiles = (() => {
  const walk = (d) => !fs.existsSync(d) ? [] : fs.readdirSync(d, { withFileTypes: true }).flatMap(e => e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]);
  return walk(path.join(ROOT, cfg.acceptanceDir || 'tests/acceptance')).filter(f => new RegExp(`@spec\\s+${num}\\b`).test(fs.readFileSync(f, 'utf8')));
})();
const accCmd = accFiles.length ? accFiles.map(f => (cfg.acceptanceRun || 'node {FILE}').replace('{FILE}', JSON.stringify(path.relative(ROOT, f)))).join(' && ') : 'echo "no acceptance tests tagged @spec ' + num + '" && false';

const gates = [
  run('lock', node('lock_tests.mjs', `check ${specDir}`)),
  run('scope', node('scope_fence.mjs', `${specDir} ${phase}`)),
  run('build', cfg.build),
  run('unit', cfg.test, { markersApply: true }),
];
const srv = await startServer(); gates.push(srv);
const notRun = (n) => ({ name: n, pass: false, summary: 'not run: app under test did not start', out: '' });
gates.push(srv.pass ? run('acceptance', accCmd, { markersApply: true }) : notRun('acceptance'));
gates.push(!cfg.uiProbe?.enabled ? run('ui', '') : srv.pass ? run('ui', node('ui_probe.mjs', `--out ${JSON.stringify(outDir)}`)) : notRun('ui'));
gates.push(run('spec', node('verify_specs.mjs', `--spec ${specDir}${FINAL ? '' : ' --pre-tests'}`)));
if (FINAL && cfg.regression) gates.push(srv.pass ? run('regression', cfg.regression, { markersApply: true, timeout: 7200 }) : notRun('regression'));
stopServer();

const scopeOut = gates.find(g => g.name === 'scope').out;
const highRisk = (scopeOut.match(/^HIGH_RISK (.*)$/m) || [])[1]?.split(' ') || [];
const pass = gates.every(g => g.pass);
const verdict = { feature: path.basename(specDir), phase: Number(phase), attempt: Number(attempt), pass, at: new Date().toISOString(),
  gates: Object.fromEntries(gates.map(g => [g.name, { pass: g.pass, summary: g.summary }])), highRisk, escalate: false };
fs.writeFileSync(path.join(outDir, `phase${phase}.verdict.json`), JSON.stringify(verdict, null, 2) + '\n');

const trim = (s, n = 4000) => { const lines = s.split('\n'); const keep = lines.filter(l => markers.some(m => hit(l, m)) || /error|fail|expected|assert/i.test(l));
  const body = (keep.length ? keep : lines.slice(-80)).join('\n'); return body.length > n ? body.slice(-n) : body; };
const fb = [`# Gate feedback — ${verdict.feature} phase ${phase}, attempt ${attempt}`, '', `Result: ${pass ? 'PASS' : 'FAIL'}`, ''];
for (const g of gates) { fb.push(`## ${g.pass ? 'PASS' : 'FAIL'} ${g.name} — ${g.summary}`); if (!g.pass && g.out) fb.push('```', trim(g.out), '```'); fb.push(''); }
fs.writeFileSync(path.join(outDir, `phase${phase}.feedback.md`), fb.join('\n'));
for (const g of gates) console.log(`${g.pass ? 'PASS' : 'FAIL'} ${g.name.padEnd(10)} ${g.summary}`);
console.log(`VERDICT ${pass ? 'PASS' : 'FAIL'} -> ${path.relative(ROOT, outDir)}/phase${phase}.verdict.json`);
process.exit(pass ? 0 : 1);
