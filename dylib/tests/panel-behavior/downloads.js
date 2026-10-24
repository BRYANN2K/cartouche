'use strict';
// Runs the page's download command poller against a fake loopback host, clock and
// SteamClient, so the checks exercise the payload the gate writes.
const { execFileSync } = require('child_process');
const { runner } = require('./harness');

const emit = process.argv[2];
if (!emit) { console.error('usage: downloads.js <emit>'); process.exit(2); }
const src = execFileSync(emit, ['downloads'], { encoding: 'utf8' }).trim();

function page(opts) {
  opts = opts || {};
  const store = opts.storage || new Map();
  const calls = [];
  const fetched = [];
  let file = opts.file;
  let tick = null;
  const now = { t: opts.now || 1790000000 };
  const SteamClient = { Downloads: {
    PauseAppUpdate: id => calls.push('pause ' + id),
    ResumeAppUpdate: id => calls.push('resume ' + id),
    RemoveFromDownloadList: id => calls.push('remove ' + id),
  } };
  const localStorage = {
    getItem: k => store.has(k) ? store.get(k) : null,
    setItem: (k, v) => store.set(k, String(v)),
  };
  const fetch = async (url, init) => {
    fetched.push({ url, cache: init && init.cache });
    if (file === undefined) return { ok: false, json: async () => null };
    return { ok: true, json: async () => typeof file === 'string' ? JSON.parse(file) : file };
  };
  const Date = { now: () => now.t * 1000 };
  const setInterval = (f, ms) => { tick = { f, ms }; return 1; };
  const console = { log() {}, warn() {}, error() {} };
  new Function('SteamClient', 'localStorage', 'fetch', 'Date', 'setInterval', 'console', src + ';')
    (SteamClient, localStorage, fetch, Date, setInterval, console);
  return {
    calls, fetched, store, now,
    get ms() { return tick && tick.ms; },
    set file(v) { file = v; },
    poll: () => tick.f(),
  };
}

const cmd = (id, appid, verb, at) => ({ id, appid, verb, at: at === undefined ? 1790000000 : at });
const doc = commands => ({ version: 1, commands });

(async () => {
  const t = runner('downloads');

  let p = page({ file: doc([cmd(1, 1593500, 'pause')]) });
  t.ok(p.ms === 1000, 'polls once a second, well inside the 3 second limit');
  await p.poll();
  t.ok(p.fetched[0].url === '/cartouche/steam-downloads.json' && p.fetched[0].cache === 'no-store',
       'reads the command file from its own loopback host, uncached');
  t.ok(p.calls.join() === 'pause 1593500', 'pause calls PauseAppUpdate with the app ID');
  await p.poll();
  t.ok(p.calls.length === 1, 'a command runs once');
  p.file = doc([cmd(1, 1593500, 'pause'), cmd(2, 1593500, 'resume')]);
  await p.poll();
  t.ok(p.calls.join() === 'pause 1593500,resume 1593500', 'resume calls ResumeAppUpdate');

  // A reloaded page remembers what it ran
  const reloaded = page({ storage: p.store, file: doc([cmd(1, 1593500, 'pause'), cmd(2, 1593500, 'resume')]) });
  await reloaded.poll();
  t.ok(reloaded.calls.length === 0, 'a reloaded page does not run old commands again');

  p = page({ file: doc([cmd(1, 7, 'pause', 1790000000 - 31)]) });
  await p.poll();
  t.ok(p.calls.length === 0, 'a command older than 30 seconds is ignored');

  p = page({ file: doc([cmd(1, '7; alert(1)', 'pause'), cmd(2, -3, 'pause'), cmd(3, 7.5, 'pause'),
                       cmd(4, 7, 'uninstall'), cmd('5', 7, 'pause'), null]) });
  await p.poll();
  t.ok(p.calls.length === 0, 'only pause and resume, only for a whole positive app ID');

  p = page({ file: { version: 2, commands: [cmd(1, 7, 'pause')] } });
  await p.poll();
  t.ok(p.calls.length === 0, 'another file version is ignored');

  p = page({});
  await p.poll();
  p.file = '{"version":1,"commands":[';
  await p.poll();
  t.ok(p.calls.length === 0, 'a missing or damaged file does nothing and throws nothing');

  // The app started a new file: its numbering restarts
  const store = new Map([['CartoucheDownloadCommand', '40']]);
  p = page({ storage: store, file: doc([cmd(1, 9, 'pause')]) });
  await p.poll();
  t.ok(p.calls.join() === 'pause 9', 'a new file whose numbers are all lower starts over');

  if (t.failed) { console.error(`downloads: ${t.failed} failed`); process.exit(1); }
  console.log('==> download commands: run once, recent only, pause and resume only');
})();
