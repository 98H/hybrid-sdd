#!/usr/bin/env node
// hooks.mjs — run Spec Kit extension hooks around implementation, the way /speckit-implement does.
// Usage: node hooks.mjs before_implement|after_implement <specDir> [--dry]
// Reads .specify/extensions.yml (Spec Kit format: hooks.<event>: [{extension, command, description,
// prompt, optional, enabled, condition}]), applying Spec Kit's own rules:
//   - enabled: false            → skipped
//   - non-empty condition       → skipped (left to Spec Kit's HookExecutor, exactly like /speckit-implement)
//   - optional: true            → listed only (recorded in the log, never executed unattended)
//   - optional: false (mandatory) → EXECUTED by the cheap agent (config agent.hookRunner, default
//                                   agent.testAuthor) as a separate one-shot process; failure = exit 1.
// Command names map like Spec Kit: "speckit.git.commit" → skill/command "speckit-git-commit".
// Additionally, plain shell hooks may be declared in .sdd/config.json: hooks.<event>: ["cmd", ...];
// they run in the working tree and must exit 0.
// An unreadable extensions.yml with possible mandatory hooks is a FAILURE (fail closed), not a silent skip.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const [event, specDir] = process.argv.slice(2);
const DRY = process.argv.includes('--dry');
if (!/^(before|after)_implement$/.test(event || '') || !specDir) { console.error('usage: hooks.mjs before_implement|after_implement <specDir> [--dry]'); process.exit(2); }
const ROOT = process.cwd();
const cfg = JSON.parse(fs.readFileSync(path.join(ROOT, '.sdd', 'config.json'), 'utf8'));
const outDir = path.join(ROOT, specDir, '.sdd'); fs.mkdirSync(outDir, { recursive: true });
const log = (s) => { console.log(s); fs.appendFileSync(path.join(outDir, 'hooks.log'), `${new Date().toISOString()} ${event} ${s}\n`); };
let failed = 0;

// 1) Spec Kit extension hooks
const yml = path.join(ROOT, '.specify', 'extensions.yml');
if (fs.existsSync(yml)) {
  // Parse with PyYAML (no npm dependency). Fail closed if it cannot be read.
  const r = spawnSync('python3', ['-c', 'import sys,json,yaml;print(json.dumps(yaml.safe_load(open(sys.argv[1])) or {}))', yml], { encoding: 'utf8' });
  let doc = null;
  try { if (r.status === 0) doc = JSON.parse(r.stdout); } catch { /* handled below */ }
  if (!doc) { log(`FAIL .specify/extensions.yml could not be read: ${(r.stderr || r.error || '').toString().trim().split('\n').pop()} — no hooks checked, mandatory hooks may be missed`); failed++; }
  else {
    const hooks = ((doc.hooks || {})[event] || []);
    for (const h of hooks) {
      const name = String(h.command || '').replace(/\./g, '-');
      if (h.enabled === false) { log(`skip (disabled) ${name}`); continue; }
      if (h.condition) { log(`skip (condition left to HookExecutor) ${name}: ${h.condition}`); continue; }
      if (h.optional !== false) { log(`optional hook listed, not run unattended: /${name} — ${h.description || ''}`); continue; }
      log(`mandatory hook: /${name} (${h.extension || '?'})`);
      if (DRY) continue;
      const prompt = path.join(outDir, `hook.${event}.${name}.md`);
      fs.writeFileSync(prompt, [
        `You are running a mandatory Spec Kit extension hook (${event}) for feature ${specDir}.`,
        `Execute the Spec Kit command "/${name}" in this repository exactly as its definition says.`,
        `Its definition is in the agent integration's commands/skills (e.g. .claude/skills/${name}/SKILL.md or the`,
        `extension's command file under .specify/extensions/). ${h.prompt ? 'Extension prompt: ' + h.prompt : ''}`,
        'Do not change product code, specs or acceptance tests unless the command itself requires it.',
        'Last line of output: "HOOK OK" on success or "HOOK FAIL: <reason>".',
      ].join('\n'));
      const tpl = (cfg.agent && (cfg.agent.hookRunner || cfg.agent.testAuthor)) || '';
      if (!tpl) { log(`FAIL no agent.hookRunner/testAuthor configured to run /${name}`); failed++; continue; }
      const run = spawnSync('bash', ['-lc', tpl.replaceAll('{PROMPT_FILE}', prompt)], { cwd: ROOT, env: { ...process.env, TERMINAL_CWD: ROOT }, encoding: 'utf8', timeout: ((cfg.agent && cfg.agent.timeoutSec) || 3600) * 1000, maxBuffer: 32 * 1024 * 1024 });
      const out = `${run.stdout || ''}${run.stderr || ''}`;
      fs.writeFileSync(path.join(outDir, `hook.${event}.${name}.log`), out);
      const ok = run.status === 0 && /HOOK OK\s*$/m.test(out) && !/HOOK FAIL/.test(out);
      log(`${ok ? 'ok' : 'FAIL'} /${name}`); if (!ok) failed++;
    }
  }
}

// 2) Plain shell hooks from .sdd/config.json
for (const cmd of ((cfg.hooks || {})[event] || [])) {
  if (DRY) { log(`shell hook: ${cmd}`); continue; }
  const r = spawnSync('bash', ['-lc', cmd], { cwd: ROOT, encoding: 'utf8', timeout: 1800 * 1000, maxBuffer: 32 * 1024 * 1024 });
  const ok = r.status === 0; log(`${ok ? 'ok' : 'FAIL'} shell hook: ${cmd}${ok ? '' : ' — ' + `${r.stdout || ''}${r.stderr || ''}`.trim().split('\n').slice(-3).join(' | ')}`);
  if (!ok) failed++;
}
console.log(`HOOKS ${event} ${failed ? 'FAIL' : 'OK'}`);
process.exit(failed ? 1 : 0);
