// Embrace's web smoke: bin/web/embrace (web/build.sh) driven in headless Chromium, with crymble-ui's browser helpers
// (lib/crymble-ui/tools/wasm: `npm ci` there first). Positions are canvas coordinates at a 1280x800 viewport (a demo
// smoke, kept short); what a step changed is read from the saved file where it can be - the domain, not the pixels.
// Any stderr line, page error or failed check fails the run.
// usage: node web/smoke.mjs [bin/web/embrace]
import { readFileSync } from 'node:fs';
import { serve, launch, open } from '../lib/crymble-ui/tools/wasm/browser.mjs';

const dir = process.argv[2] || 'bin/web/embrace';
const browser = await launch();
const failures = [];
let checks = 0;
function check(name, ok, detail = '') {
  checks++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail ? ` - ${detail}` : ''}`);
  if (!ok) failures.push(name);
}

const server = await serve(dir);
const { context, page, log } = await open(browser, server.url, { viewport: { width: 1280, height: 800 } });
await context.grantPermissions(['clipboard-read', 'clipboard-write']);
const box = await page.locator('#app').boundingBox();
const at = (x, y) => [box.x + x, box.y + y];
// Settled: the app went idle, or rendered twice since (Embrace's CPU monitor keeps rendering - idle may never come
// while the page rasterizes in software).
const settle = () => page.evaluate(() => {
  const f0 = window.__crymble.frames;
  return Promise.race([window.__crymble.idle(),
    new Promise((done) => { const poll = () => (window.__crymble.frames >= f0 + 2 ? done() : setTimeout(poll, 20)); poll(); })]);
});
const click = async (x, y) => { await page.mouse.click(...at(x, y)); await settle(); };
const press = async (keys) => { await page.keyboard.press(keys); await settle(); };
const type = async (text) => { await page.keyboard.type(text); await settle(); };
const ink = (x, y, w, h) => page.evaluate(([x, y, w, h]) => {
  const d = document.getElementById('app').getContext('2d').getImageData(x, y, w, h).data;
  let n = 0;
  for (let i = 0; i < d.length; i += 4) if (Math.abs(d[i] - d[0]) + Math.abs(d[i + 1] - d[1]) + Math.abs(d[i + 2] - d[2]) > 120) n++;
  return n;
}, [x, y, w, h]);
const leaveGuarded = () => page.evaluate(() => { const e = new Event('beforeunload', { cancelable: true }); window.dispatchEvent(e); return e.defaultPrevented; });
// A key as the browser delivers it to the canvas; true if Embrace claimed it (the browser's default prevented).
const claimed = (init) => page.evaluate((init) => {
  let prevented = null;
  const seen = (e) => { prevented = e.defaultPrevented; };
  window.addEventListener('keydown', seen);
  document.getElementById('app').dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, cancelable: true, ...init }));
  document.getElementById('app').dispatchEvent(new KeyboardEvent('keyup', { bubbles: true, cancelable: true, ...init }));
  window.removeEventListener('keydown', seen);
  return prevented;
}, init);
// A file Embrace saved into the tab's file system, inflated (an .embrace file is zlib-compressed JSON).
const saved = (name) => page.evaluate(async (name) => {
  const user = window.__crymble.fs.dir.contents.get('home').contents.get('user');
  const file = user.contents.get(name);
  if (!file) return null;
  const stream = new Blob([file.data]).stream().pipeThrough(new DecompressionStream('deflate'));
  return new Response(stream).text();
}, name);
// Save file as..., typing `typed` into the dialog (Embrace appends .embrace; the dialog opens where the last pick was)
async function saveAs(typed) {
  await click(25, 12); // File
  await click(80, 110); // Save file as...
  await type(typed);
  await press('Enter');
}

// --- boots, says what it is --------------------------------------------------------------------------------------
const bar = await page.textContent('header');
// web/build.sh --local marks its page and its NOTICES alike; a build to publish carries neither mark
const local = readFileSync(`${dir}/NOTICES`, 'utf8').includes('not for publication');
check(`boots; the bar names the version${local ? ' and the local build' : ', no local-build mark'}`,
  /Embrace® \d+\.\d+\.\d+/.test(bar) && bar.includes('local build') === local);
check('leaving is not guarded before any input', (await leaveGuarded()) === false);
check('a release build: no CPU monitor in the top-right corner', (await ink(1150, 28, 120, 22)) === 0);

// --- the demo document -------------------------------------------------------------------------------------------
await click(25, 12); // File
await click(80, 62); // New file (demo)
check('File > New file (demo) shows the Allocations table', (await ink(90, 390, 520, 300)) > 3000);
check('leaving is guarded after input', (await leaveGuarded()) === true);
const note = await page.textContent('#keylist');
// (Ctrl+Tab comes from crymble-ui's built-ins, named for every app; Ctrl+W is Embrace's own Close Shape)
check('the page names Ctrl+Tab and Embrace\'s Ctrl+W as kept by the browser', note.includes('Ctrl+Tab') && note.includes('Ctrl+W'), note);

// --- an edit sticks: saved and read back, against the untouched demo saved first -------------------------------
await saveAs('/home/user/demo'); // from the folder Embrace started in, /
const demo = await saved('demo.embrace');
await page.mouse.dblclick(...at(553, 400)); // Allocations, record 1, field c5 (100 before)
await settle();
await press('Control+a');
await type('250');
await press('Enter');
await saveAs('edited'); // the dialog opens where the last pick was: /home/user
const edited = await saved('edited.embrace');
const count = (text, s) => (text ?? '').split(s).length - 1;
check('a cell edit is in the file saved to the tab', demo !== null && edited !== null && count(edited, '250') === count(demo, '250') + 1,
  demo === null || edited === null ? 'a save did not arrive' : `"250" ${count(demo, '250')} times -> ${count(edited, '250')}`);

// --- Ctrl+R adds a record and the page stays --------------------------------------------------------------------
await click(150, 400);
check('Ctrl+R is claimed (no page reload)', (await claimed({ key: 'r', code: 'KeyR', ctrlKey: true })) === true);
await settle();
await saveAs('added');
const added = await saved('added.embrace');
check('Ctrl+R added a record (the saved file grew)', added !== null && edited !== null && added.length > edited.length,
  `${edited?.length} -> ${added?.length} chars`);

// --- Alt+Left steps the Shape's history, not the browser's -----------------------------------------------------
const titleBar = [8, 30, 600, 20];
const before = await page.evaluate(([x, y, w, h]) => Array.from(document.getElementById('app').getContext('2d').getImageData(x, y, w, h).data).join(), titleBar);
check('Alt+Left is claimed (no history navigation)', (await claimed({ key: 'ArrowLeft', code: 'ArrowLeft', altKey: true })) === true);
await settle();
const after = await page.evaluate(([x, y, w, h]) => Array.from(document.getElementById('app').getContext('2d').getImageData(x, y, w, h).data).join(), titleBar);
check('Alt+Left stepped the Shape history (its title changed)', after !== before);

// --- About: the logo arrives after its decode ---------------------------------------------------------------------
await click(128, 12); // Help
await click(150, 38); // About...
await page.waitForTimeout(300);
await settle();
check('About shows the logo (an image decoded after it was asked for)', (await ink(200, 60, 400, 300)) > 5000,
  `ink ${await ink(200, 60, 400, 300)}`);

// --- no stderr, no page error -------------------------------------------------------------------------------------
const stderr = await page.evaluate(() => window.__crymble.stderr);
const errors = log.filter((l) => l.type === 'pageerror' || l.type === 'error').map((l) => l.text);
check('no stderr, no page error', stderr.length === 0 && errors.length === 0, [...stderr, ...errors].join(' | ').slice(0, 300));
await context.close();

// --- browsers it cannot run in: a message, and the module is never downloaded ------------------------------------
for (const [name, init, expect] of [
  ['an engine without wasm exception handling', () => { WebAssembly.validate = () => false; }, 'exception handling'],
  ['a touch-only device', () => { const m = window.matchMedia.bind(window); window.matchMedia = (q) => (q === '(any-pointer: fine)' ? { matches: false } : m(q)); }, 'mouse and a keyboard'],
]) {
  const ctx = await browser.newContext();
  const p = await ctx.newPage();
  let fetched = false;
  p.on('request', (r) => { if (r.url().endsWith('.wasm')) fetched = true; });
  await p.addInitScript(init);
  await p.goto(server.url);
  await p.waitForFunction(() => !/Loading/.test(document.getElementById('msg').textContent));
  const msg = await p.textContent('#msg');
  check(`unsupported: ${name} gets a message, no download`, msg.includes(expect) && !fetched, msg);
  await ctx.close();
}

server.close();
await browser.close();
console.log(failures.length ? `smoke: ${failures.length} of ${checks} checks failed` : `smoke: PASS (${checks} checks)`);
process.exit(failures.length ? 1 : 0);
