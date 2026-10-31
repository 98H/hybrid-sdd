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
// Time optimisation (no extra model tokens, no weaker gate): cheap gates first and fail fast when later gates
// would be meaningless; acceptance files run in parallel LANES (files inside one lane stay sequential);
// regression is skipped only when an earlier gate already failed (the attempt fails anyway and regression
// runs on the next attempt); when every pre-regression gate passes, SDD_PRE_PASS_HOOK (set by run_phase.sh
// to start the reviewer) is launched so the reviewer works while regression runs. Every gate records `sec`.

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
const port = Number(process.env.SDD_PORT_OVERRIDE) || cfg.servePort || 0; // override lets pipelines run in parallel
const env = { ...process.env, ...(cfg.serve ? { SDD_PORT: String(port), SDD_BASE_URL: `http://127.0.0.1:${port}` } : {}) };

function run(name, cmd, { markersApply = false, timeout = 1800 } = {}) {
  if (!cmd) return { name, pass: true, summary: 'not configured (skipped)', out: '' };
  const t0 = Date.now();
  const r = spawnSync('bash', ['-lc', cmd], { cwd: ROOT, env, encoding: 'utf8', timeout: timeout * 1000, maxBuffer: 64 * 1024 * 1024 });
  const out = `${r.stdout || ''}${r.stderr || ''}`;
  const hits = markersApply ? markers.filter(m => hit(out, m)) : [];
  const timedOut = r.error && r.error.code === 'ETIMEDOUT';
  const pass = r.status === 0 && !timedOut && hits.length === 0;
  const summary = timedOut ? `timed out after ${timeout}s` : r.status !== 0 ? `exit ${r.status}` : hits.length ? `failure markers: ${hits.join(', ')}` : 'ok';
  return { name, pass, summary, out, sec: Math.round((Date.now() - t0) / 1000) };
}
// Async variant used by acceptance lanes: same pass rule (exit 0, no timeout, no failure marker).
function runAsync(cmd, timeout) {
  return new Promise((resolve) => {
    const t0 = Date.now(); let out = ''; let timedOut = false;
    const p = spawn('bash', ['-lc', cmd], { cwd: ROOT, env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    p.stdout.on('data', d => { out += d; }); p.stderr.on('data', d => { out += d; });
    const k = setTimeout(() => { timedOut = true; try { process.kill(-p.pid, 'SIGKILL'); } catch { /* gone */ } }, timeout * 1000);
    p.on('close', (code) => { clearTimeout(k); const hits = markers.filter(m => hit(out, m));
      resolve({ code, timedOut, hits, out, sec: Math.round((Date.now() - t0) / 1000) }); });
  });
}
const node = (s, a) => `node ${JSON.stringify(path.join(HERE, s))} ${a}`;

let server = null;
async function startServer() {
  if (!cfg.serve) return { name: 'serve', pass: true, summary: 'not configured (skipped)', out: '' };
  const t0 = Date.now();
  const log = path.join(outDir, `serve.p${phase}.a${attempt}.log`);
  const fd = fs.openSync(log, 'w');
  server = spawn('bash', ['-lc', cfg.serve], { cwd: ROOT, env, detached: true, stdio: ['ignore', fd, fd] });
  const url = `http://127.0.0.1:${port}${cfg.serveReadyPath || '/'}`;
  for (let i = 0; i < (cfg.serveTimeoutSec || 60); i++) {
    await new Promise(r => setTimeout(r, 1000));
    try { const r = await fetch(url); if (r.status < 500) return { name: 'serve', pass: true, summary: `up on :${port}`, out: '', sec: Math.round((Date.now() - t0) / 1000) }; } catch { /* not yet */ }
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

const skippedConverge = [], deferred = [];
const accFiles = (() => {
  const walk = (d) => !fs.existsSync(d) ? [] : fs.readdirSync(d, { withFileTypes: true }).flatMap(e => e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]);
  // Files tagged @converge document known spec/code gaps (they fail until fixed). They are required to pass
  // only in a phase whose tasks cite one of their FRs; otherwise they are reported as skipped known gaps.
  const sections = fs.readFileSync(path.join(ROOT, specDir, 'tasks.md'), 'utf8').split(/^## /m);
  const phaseTasks = (sections.find(s => new RegExp(`^Phase ${phase}\\b`).test(s)) || '');
  const phaseFRs = new Set(phaseTasks.match(/\bFR-\d{3}\b/g) || []);
  // Phase-scoped acceptance: a test file is required once every FR it covers is delivered by a phase <= this
  // one (FR -> latest phase whose tasks cite it). The last phase and --final run every file.
  const frPhase = {}; let maxPhase = 0;
  for (const s of sections) { const m = s.match(/^Phase (\d+)\b/); if (!m) continue; const n = +m[1]; maxPhase = Math.max(maxPhase, n);
    for (const fr of s.match(/\bFR-\d{3}\b/g) || []) frPhase[fr] = Math.max(frPhase[fr] || 0, n); }
  const all = FINAL || Number(phase) >= maxPhase;
  return walk(path.join(ROOT, cfg.acceptanceDir || 'tests/acceptance')).filter(f => {
    const t = fs.readFileSync(f, 'utf8');
    if (!new RegExp(`@spec\\s+${num}\\b`).test(t)) return false;
    const fileFRs = (t.match(/@covers[^\n]*/) || [''])[0].match(/\bFR-\d{3}\b/g) || [];
    if (!all && fileFRs.some(fr => (frPhase[fr] ?? Infinity) > Number(phase))) { deferred.push(path.relative(ROOT, f)); return false; }
    if (!/@converge\b/.test(t)) return true;
    const covers = (t.match(/@covers[^\n]*/) || [''])[0].match(/\bFR-\d{3}\b/g) || [];
    if (covers.some(fr => phaseFRs.has(fr))) return true;
    skippedConverge.push(path.relative(ROOT, f));
    return false;
  });
})();
const accCmdOf = (f, lane) => (cfg.acceptanceRun || 'node {FILE}').replaceAll('{LANE}', lane).replace('{FILE}', JSON.stringify(path.relative(ROOT, f)));
// Lanes: cfg.acceptanceLanes = [{ name, match }] (match = regex on the repo-relative path). A file joins the
// first matching lane, otherwise lane "default". Lanes run concurrently (cap cfg.acceptanceParallel, default
// 1 = the old fully sequential behaviour); files of one lane run in order. Put files that share an external
// rate limit, a fixed port range or the served app's mutable state in the same lane.
async function acceptanceGate() {
  if (!accFiles.length) {
    const cmd = deferred.length ? `echo "all ${deferred.length} acceptance file(s) cover FRs of later phases — deferred"` : 'echo "no acceptance tests tagged @spec ' + num + '" && false';
    return run('acceptance', cmd, { markersApply: true });
  }
  const t0 = Date.now(); const lanesCfg = cfg.acceptanceLanes || []; const lanes = new Map();
  for (const f of accFiles) { const rel = path.relative(ROOT, f); const l = lanesCfg.find(x => new RegExp(x.match).test(rel)); const n = l ? l.name : 'default';
    if (!lanes.has(n)) lanes.set(n, []); lanes.get(n).push(f); }
  const results = []; const queue = [...lanes.entries()]; const cap = Math.max(1, Number(cfg.acceptanceParallel) || 1);
  const timeout = Number(cfg.acceptanceTimeoutSec) || 1800;
  async function worker() { for (let e = queue.shift(); e; e = queue.shift()) { const [lane, files] = e;
    for (const f of files) { const r = await runAsync(accCmdOf(f, lane), timeout); results.push({ f: path.relative(ROOT, f), lane, ...r }); } } }
  await Promise.all(Array.from({ length: Math.min(cap, lanes.size) }, worker));
  const bad = results.filter(r => r.code !== 0 || r.timedOut || r.hits.length);
  const out = results.map(r => `### ${r.f} [lane ${r.lane}, ${r.sec}s] ${r.code !== 0 || r.timedOut || r.hits.length ? 'FAIL' : 'ok'}\n${r.out}`).join('\n');
  const summary = bad.length ? `${bad.length}/${results.length} file(s) failed: ${bad.map(r => path.basename(r.f) + (r.timedOut ? ' (timeout)' : '')).join(', ')}` : `ok (${results.length} files, ${lanes.size} lane(s))`;
  return { name: 'acceptance', pass: !bad.length, summary, out, sec: Math.round((Date.now() - t0) / 1000) };
}
const skip = (n, why) => ({ name: n, pass: false, summary: `not run: ${why}`, out: '', sec: 0 });

const gates = [
  run('lock', node('lock_tests.mjs', `check ${specDir}`)),
  run('scope', node('scope_fence.mjs', `${specDir} ${phase}`)),
];
// Fail fast: with tampered tests, out-of-scope edits or a broken build every later gate is meaningless.
const early = gates.every(g => g.pass) ? null : 'lock/scope failed — fix that first';
gates.push(early ? skip('build', early) : run('build', cfg.build));
const pre = gates.every(g => g.pass) ? null : 'an earlier gate failed (lock, scope or build)';
gates.push(pre ? skip('unit', pre) : run('unit', cfg.test, { markersApply: true }));
const srv = pre ? skip('serve', pre) : await startServer(); gates.push(srv);
const notRun = (n) => skip(n, pre || 'app under test did not start');
gates.push(srv.pass ? await acceptanceGate() : notRun('acceptance'));
gates.push(!cfg.uiProbe?.enabled ? run('ui', '') : srv.pass ? run('ui', node('ui_probe.mjs', `--out ${JSON.stringify(outDir)}`)) : notRun('ui'));
gates.push(run('spec', node('verify_specs.mjs', `--spec ${specDir}${FINAL ? '' : ' --pre-tests'}`)));
const prePass = gates.every(g => g.pass);
if (prePass && process.env.SDD_PRE_PASS_HOOK) {
  // Start the reviewer now; it reads the diff, not the regression result. run_phase.sh waits for it.
  const h = spawn('bash', ['-lc', process.env.SDD_PRE_PASS_HOOK], { cwd: ROOT, env, detached: true, stdio: 'ignore' }); h.unref();
  fs.writeFileSync(path.join(outDir, `phase${phase}.prehook.started`), String(h.pid));
}
if (FINAL && cfg.regression) gates.push(!srv.pass ? notRun('regression') : !prePass ? skip('regression', 'an earlier gate failed — regression runs on the next attempt') : run('regression', cfg.regression, { markersApply: true, timeout: 7200 }));
stopServer();

const scopeOut = gates.find(g => g.name === 'scope').out;
const highRisk = (scopeOut.match(/^HIGH_RISK (.*)$/m) || [])[1]?.split(' ') || [];
const pass = gates.every(g => g.pass);
const verdict = { feature: path.basename(specDir), phase: Number(phase), attempt: Number(attempt), pass, at: new Date().toISOString(),
  gates: Object.fromEntries(gates.map(g => [g.name, { pass: g.pass, summary: g.summary, sec: g.sec ?? null }])), totalSec: gates.reduce((a, g) => a + (g.sec || 0), 0), highRisk, knownGapsSkipped: skippedConverge, deferredToLaterPhase: deferred, escalate: false };
fs.writeFileSync(path.join(outDir, `phase${phase}.verdict.json`), JSON.stringify(verdict, null, 2) + '\n');

const trim = (s, n = 4000) => { const lines = s.split('\n'); const keep = lines.filter(l => markers.some(m => hit(l, m)) || /error|fail|expected|assert/i.test(l));
  const body = (keep.length ? keep : lines.slice(-80)).join('\n'); return body.length > n ? body.slice(-n) : body; };
const fb = [`# Gate feedback — ${verdict.feature} phase ${phase}, attempt ${attempt}`, '', `Result: ${pass ? 'PASS' : 'FAIL'}`, ''];
for (const g of gates) { fb.push(`## ${g.pass ? 'PASS' : 'FAIL'} ${g.name} — ${g.summary}`); if (!g.pass && g.out) fb.push('```', trim(g.out), '```'); fb.push(''); }
fs.writeFileSync(path.join(outDir, `phase${phase}.feedback.md`), fb.join('\n'));
for (const g of gates) console.log(`${g.pass ? 'PASS' : 'FAIL'} ${g.name.padEnd(10)} ${g.summary}${g.sec != null ? ` (${g.sec}s)` : ''}`);
console.log(`VERDICT ${pass ? 'PASS' : 'FAIL'} -> ${path.relative(ROOT, outDir)}/phase${phase}.verdict.json`);
process.exit(pass ? 0 : 1);
