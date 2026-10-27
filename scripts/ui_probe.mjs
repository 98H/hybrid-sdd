#!/usr/bin/env node
// ui_probe.mjs — zero-token UI/UX probe. Geometry and text checks in a real browser.
// Usage: node ui_probe.mjs [--out DIR]   (reads .sdd/config.json -> uiProbe)
// For each page x viewport x locale it reports:
//   overflow   : document wider than viewport (horizontal scroll)
//   covered    : visible interactive element whose centre is covered by another element
//   tinyTarget : interactive element smaller than minTouchTarget (mobile viewports only)
//   untranslated: visible text matching untranslatedPattern (e.g. Latin words in a Persian locale)
//   clipped    : text element whose content is cut off (scrollWidth > clientWidth with overflow hidden)
//   consoleErr : console errors and page errors
// Writes <out>/ui_probe.json and exits 1 if any defect is found. Requires puppeteer-core + Chromium.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const ROOT = process.cwd();
const cfg = JSON.parse(fs.readFileSync(path.join(ROOT, '.sdd', 'config.json'), 'utf8')).uiProbe || {};
const out = process.argv.includes('--out') ? process.argv[process.argv.indexOf('--out') + 1] : path.join(ROOT, '.sdd', 'out');
// gates.mjs exports SDD_BASE_URL when it serves the worktree build; prefer it over the static config.
if (process.env.SDD_BASE_URL) cfg.baseUrl = process.env.SDD_BASE_URL;
if (!cfg.enabled) { console.log('UI PROBE SKIPPED (uiProbe.enabled=false)'); process.exit(0); }
let puppeteer;
try { puppeteer = (await import('puppeteer-core')).default; } catch { console.log('UI PROBE FAIL: puppeteer-core not installed'); process.exit(1); }

// Private throwaway profile: never collide with another running browser.
// Snap-packaged Chromium can only use profiles under ~/snap/chromium/common (otherwise it fails with a
// misleading "browser is already running" error).
const snapBase = path.join(os.homedir(), 'snap', 'chromium', 'common');
const profBase = fs.existsSync(snapBase) ? path.join(snapBase, 'sdd-ui-probe') : os.tmpdir();
fs.mkdirSync(profBase, { recursive: true });
const profile = fs.mkdtempSync(path.join(profBase, 'profile-'));
let browser;
try { browser = await puppeteer.launch({ executablePath: cfg.chromePath, headless: 'new', userDataDir: profile, args: ['--no-sandbox', '--disable-dev-shm-usage'] }); }
catch (e) { console.log(`UI PROBE FAIL: browser launch failed: ${String(e).slice(0, 200)}`); fs.rmSync(profile, { recursive: true, force: true }); process.exit(1); }
const results = []; let defects = 0;
let knownTotal = 0;
const baseline = cfg.baseline && fs.existsSync(path.join(ROOT, cfg.baseline)) ? JSON.parse(fs.readFileSync(path.join(ROOT, cfg.baseline), 'utf8')) : null;
try {
  for (const vp of cfg.viewports) for (const loc of cfg.locales) for (const pg of cfg.pages) {
    const page = await browser.newPage();
    const consoleErr = [];
    page.on('console', m => { if (m.type() === 'error') consoleErr.push(m.text().slice(0, 200)); });
    page.on('pageerror', e => consoleErr.push(String(e).slice(0, 200)));
    await page.setViewport({ width: vp.width, height: vp.height, isMobile: !!vp.mobile, hasTouch: !!vp.mobile, deviceScaleFactor: 1 });
    // Live apps keep sockets/polling open, so never wait for network idle: DOM ready + settle time.
    await page.goto(cfg.baseUrl + pg, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await new Promise(r => setTimeout(r, cfg.settleMs ?? 4000));
    if (loc.setup) {
      const nav = page.waitForNavigation({ waitUntil: 'domcontentloaded', timeout: 30000 }).catch(() => null);
      await page.evaluate(loc.setup); await nav; await new Promise(r => setTimeout(r, cfg.settleMs ?? 4000));
    }
    const r = await page.evaluate((sel, minT, mobile, untr) => {
      const vis = (el) => { const s = getComputedStyle(el); const b = el.getBoundingClientRect();
        return s.visibility !== 'hidden' && s.display !== 'none' && +s.opacity > 0.05 && b.width > 0 && b.height > 0 && b.bottom > 0 && b.right > 0 && b.top < innerHeight && b.left < innerWidth; };
      const label = (el) => (el.id ? '#' + el.id : el.tagName.toLowerCase() + (el.className && typeof el.className === 'string' ? '.' + el.className.trim().split(/\s+/).slice(0, 2).join('.') : '')) + ' "' + (el.innerText || el.value || el.getAttribute('aria-label') || '').trim().slice(0, 30) + '"';
      const res = { overflow: document.documentElement.scrollWidth > innerWidth + 1 ? [`scrollWidth ${document.documentElement.scrollWidth} > ${innerWidth}`] : [], covered: [], tinyTarget: [], untranslated: [], clipped: [] };
      for (const el of document.querySelectorAll(sel)) {
        if (!vis(el)) continue; const b = el.getBoundingClientRect();
        const cx = Math.min(innerWidth - 1, Math.max(0, b.left + b.width / 2)), cy = Math.min(innerHeight - 1, Math.max(0, b.top + b.height / 2));
        const top = document.elementFromPoint(cx, cy);
        if (top && top !== el && !el.contains(top) && !top.contains(el)) res.covered.push(`${label(el)} under ${label(top)}`);
        if (mobile && (b.width < minT || b.height < minT)) res.tinyTarget.push(`${label(el)} ${Math.round(b.width)}x${Math.round(b.height)}`);
      }
      if (untr) { const re = new RegExp(untr); const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        while (w.nextNode()) { const t = w.currentNode.textContent.trim(); const p = w.currentNode.parentElement;
          if (t && p && vis(p) && !p.closest('code,pre,[dir=ltr],bdi,input,textarea,script,style,[data-sdd-ignore]') && re.test(t)) res.untranslated.push(`${label(p)}: ${t.slice(0, 40)}`); } }
      for (const el of document.querySelectorAll('body *')) {
        if (!vis(el) || el.children.length) continue; const s = getComputedStyle(el);
        if ((s.overflow === 'hidden' || s.textOverflow === 'ellipsis') && el.scrollWidth > el.clientWidth + 1 && !el.closest('[data-sdd-ignore]')) res.clipped.push(label(el));
      }
      for (const k of Object.keys(res)) res[k] = [...new Set(res[k])].slice(0, 25);
      return res;
    }, cfg.interactiveSelector, cfg.minTouchTarget || 44, !!vp.mobile, cfg.untranslatedPattern || '');
    r.consoleErr = consoleErr.slice(0, 10);
    // Baseline (cfg.baseline = earlier ui_probe.json of the product before this work): only NEW defects fail.
    // Digits are normalised so live numbers (prices, clocks) do not make a known defect look new.
    const norm = (x) => x.replace(/[0-9\u06F0-\u06F9][0-9\u06F0-\u06F9,.]*/g, '#');
    const base = baseline && baseline.results.find(b => b.page === pg && b.viewport === vp.name && b.locale === loc.name);
    let known = 0;
    if (base) for (const k of Object.keys(r)) { if (k === 'consoleErr' && !Array.isArray(base[k])) continue;
      const seen = new Set((base[k] || []).map(norm)); const before = r[k].length; r[k] = r[k].filter(x => !seen.has(norm(x))); known += before - r[k].length; }
    const n = Object.values(r).reduce((s, v) => s + v.length, 0); defects += n; knownTotal += known;
    results.push({ page: pg, viewport: vp.name, locale: loc.name, defects: n, knownBaselineDefects: known, ...r });
    await page.close();
  }
} catch (e) { console.log(`UI PROBE FAIL: ${String(e).slice(0, 300)}`); await browser.close(); fs.rmSync(profile, { recursive: true, force: true }); process.exit(1); }
finally { await browser.close().catch(() => {}); fs.rmSync(profile, { recursive: true, force: true }); }
fs.mkdirSync(out, { recursive: true });
fs.writeFileSync(path.join(out, 'ui_probe.json'), JSON.stringify({ defects, knownBaselineDefects: knownTotal, baseline: cfg.baseline || null, results }, null, 2));
for (const r of results) console.log(`${r.defects ? 'FAIL' : 'PASS'} ${r.page} ${r.viewport}/${r.locale} defects=${r.defects}` +
  (r.defects ? '\n' + ['overflow', 'covered', 'tinyTarget', 'untranslated', 'clipped', 'consoleErr'].filter(k => r[k].length).map(k => `   ${k}: ${r[k].slice(0, 6).join(' | ')}`).join('\n') : ''));
console.log(`UI PROBE ${defects ? 'FAIL' : 'OK'} defects=${defects}${baseline ? ` (new vs baseline ${cfg.baseline}; known baseline defects still present=${knownTotal})` : ''}`);
process.exit(defects ? 1 : 0);
