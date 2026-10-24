'use strict';
// Runs the injected library exporter against a fake transport socket, app store,
// collection store and token route, so the checks exercise the payload the
// gate writes — the packet format, the auth handshake, the route name, the
// token framing, the debounce, and the refusal backoff.
const { execFileSync, spawn } = require('child_process');
const { runner } = require('./harness');

const emit = process.argv[2];
if (!emit || !process.argv[3]) { console.error('usage: library-export.js <emit> <libexport-check>'); process.exit(2); }
const emitWith = (...a) => execFileSync(emit, a, { encoding: 'utf8' }).trim();

const TOKEN = 'a1b2c3d4e5f60718293a4b5c6d7e8f9a';
const TOKEN_NEXT = 'b2c3d4e5f60718293a4b5c6d7e8f9a01';
const SID = '76561198123456789';

// Minimal wire helpers mirroring the client's frame format: u32 eMsg, u32 header
// length, protobuf header, protobuf body.
const vn = n => { const b = []; do { let x = n % 128; n = (n - x) / 128; if (n) x |= 128; b.push(x); } while (n); return b; };
const f2 = (n, v) => { const b = typeof v === 'string' ? new TextEncoder().encode(v) : v; return [...vn(n * 8 + 2), ...vn(b.length), ...b]; };
const f1 = (n, v) => [...vn(n * 8 + 1), v & 255, v >>> 8 & 255, v >>> 16 & 255, v >>> 24 & 255, 0, 0, 0, 0];
const f0 = (n, v) => [...vn(n * 8), ...vn(v)];

function frame(fields, body) {
  const h = fields.flat(), b = body || [];
  const m = new Uint8Array(8 + h.length + b.length), d = new DataView(m.buffer);
  d.setUint32(0, 0x80000092, true);
  d.setUint32(4, h.length, true);
  m.set(h, 8); m.set(b, 8 + h.length);
  return m;
}

function decode(u8) {
  const d = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
  const L = d.getUint32(4, true), h = new Uint8Array(u8.buffer, u8.byteOffset + 8, L);
  const out = { emsg: d.getUint32(0, true), hdr: {}, body: u8.slice(8 + L) };
  let p = 0;
  const varint = () => { let v = 0, s = 0, b; do { b = h[p++]; v += (b & 127) * 2 ** s; s += 7; } while (b & 128); return v; };
  while (p < h.length) {
    const t = varint(), f = t >> 3, w = t & 7;
    if (w === 0) out.hdr[f] = varint();
    else if (w === 1) { let v = 0; for (let i = 0; i < 8; i++) v += h[p + i] * 2 ** (8 * i); p += 8; out.hdr[f] = v; }
    else if (w === 2) { const l = varint(); out.hdr[f] = h.slice(p, p + l); p += l; }
    else if (w === 5) p += 4;
    else return null;
  }
  if (out.hdr[12]) out.route = new TextDecoder().decode(out.hdr[12]);
  if (out.hdr[40]) out.auth = new TextDecoder().decode(out.hdr[40]);
  return out;
}

const bytes_field = body => {
  // one length-delimited field 1
  const b = decode_body(body);
  return b[1];
};
function decode_body(u8) {
  const out = {};
  let p = 0;
  const varint = () => { let v = 0, s = 0, b; do { b = u8[p++]; v += (b & 127) * 2 ** s; s += 7; } while (b & 128); return v; };
  while (p < u8.length) {
    const t = varint(), f = t >> 3, w = t & 7;
    if (w === 0) out[f] = varint();
    else if (w === 2) { const l = varint(); out[f] = u8.slice(p, p + l); p += l; }
    else if (w === 1) p += 8;
    else if (w === 5) p += 4;
    else break;
  }
  return out;
}

const app = (id, o) => Object.assign({
  appid: id, canonicalAppType: 1, display_name: 'Game ' + id, installed: false,
  rt_last_time_played: 0, minutes_playtime_forever: 0,
  BIsOwned: () => true, BIsBorrowed: () => false, BIsShortcut: () => false,
}, o || {});

function page(opts) {
  opts = opts || {};
  const sockets = [];
  const fetched = [];
  const warnings = [];
  const timeouts = [];
  let token = opts.token === undefined ? TOKEN : opts.token;
  const store = opts.store || { m_mapApps: new Map() };
  class FakeWS {
    constructor(url) {
      this.url = url; this.readyState = 0; this.frames = [];
      sockets.push(this);
      queueMicrotask(() => { this.readyState = 1; this.onopen && this.onopen(); });
    }
    async send(m) {
      const msg = decode(m);
      this.frames.push(msg);
      const er = msg.route === 'Cartouche.ExportOwnedGames#1'
        ? (opts.exportResult === undefined ? 1 : opts.exportResult) : 1;
      let result = er, body = [];
      if (msg.route === 'Cartouche.GetExportToken#1') {
        fetched.push({ url: msg.route });
        result = token ? 1 : 2;
        body = token ? f2(1, token) : [];
      }
      if (msg.route === 'Cartouche.GetInstallCommand#1') body = f2(1, '{}');
      if (opts.route && ['Cartouche.GetExportToken#1', 'Cartouche.ExportOwnedGames#1'].includes(msg.route)) {
        const real = await opts.route(msg);
        result = real.result; body = real.body;
      }
      const reply = frame([f1(11, msg.hdr[10]), f0(13, result)], body);
      queueMicrotask(() => this.onmessage && this.onmessage({ data: reply.buffer }));
    }
    close() { this.readyState = 3; this.onclose && this.onclose(); }
  }
  const self = { m_cm: { steamid: { ConvertTo64BitString: () => SID } } };
  const SteamClient = {
    WebUITransport: { GetTransportInfo: async () => opts.info === undefined
        ? { portClientdll: 4242, authKeyClientdll: 'AUTHK', nMaximumMsgSizeBytes: 4194304 }
        : opts.info },
  };
  const window = {
    appStore: opts.noStore ? undefined : store,
    collectionStore: opts.collections,
  };
  const fetch = () => { throw new Error('export must not fetch a helper token'); };
  // Requeue and the call's own timeouts all land here; the last push of a poll
  // is always the next tick.
  const setTimeout = (f, ms) => { timeouts.push({ f, ms }); return timeouts.length; };
  const console = { log() {}, info() {}, warn(m) { warnings.push(String(m)) }, error() {} };
  const src = emitWith('export');
  new Function('window', 'SteamClient', 'WebSocket', 'fetch', 'setTimeout', 'setInterval', 'console',
               'return ' + src + ';')
    .call(self, window, SteamClient, FakeWS, fetch, setTimeout, () => 0, console);
  return {
    sockets, fetched, warnings, window,
    set token(v) { token = v; },
    get ms() { const t = timeouts[timeouts.length - 1]; return t && t.ms; },
    poll: async () => {
      const t = timeouts.pop();
      timeouts.length = 0;
      if (t) await t.f();
      await new Promise(r => setImmediate(r));
    },
    flush: () => new Promise(r => setImmediate(r)),
  };
}

const export_msgs = ws => ws.frames.filter(f => f.route === 'Cartouche.ExportOwnedGames#1');
const payload_json = f => {
  const raw = new TextDecoder().decode(bytes_field(f.body));
  const nl = raw.indexOf('\n');
  return { token: raw.slice(0, nl), doc: JSON.parse(raw.slice(nl + 1)) };
};

(async () => {
  const t = runner('library-export');

  // No app store, or an empty one, stays inert without touching the token.
  {
    const p = page({ noStore: true });
    await p.flush();
    t.ok(p.sockets.length === 0 && p.fetched.length === 0, 'no app store stays inert');
  }
  {
    const p = page({ token: '' });
    await p.flush();
    t.ok(p.sockets.length === 0 && p.fetched.length === 0 && p.ms === 15000,
         'an empty library polls quietly without asking for the token');
  }

  // Steam's app store can become available after the patched initializer runs.
  {
    const p = page({ noStore: true });
    await p.flush();
    p.window.appStore = { allApps: [app(21, { installed: true, local_per_client_data: { installed: false } })] };
    await p.poll();
    const doc = payload_json(export_msgs(p.sockets[0])[0]).doc;
    t.ok(doc.apps.length === 1 && doc.apps[0].appid === 21, 'late app store exports through the public allApps collection');
    t.ok(doc.apps[0].installed === false, 'a remote installation is not reported as installed on this Mac');
  }

  // A populated store exports once.
  const apps = new Map([
    [7, app(7, { installed: true, rt_last_time_played: 1789999999, minutes_playtime_forever: 42 })],
    [8, app(8)],
    [9, app(9, { canonicalAppType: 3 })],                    // tool
    [10, app(10, { BIsOwned: () => false })],                // not owned
    [11, app(11, { BIsBorrowed: () => true })],              // borrowed
    [12, app(12, { BIsShortcut: () => true })],              // shortcut
    [13, app(13, { display_name: 'Hidden One' })],
  ]);
  const collections = {
    collectionsFromStorage: new Map([['hidden', { apps: new Set([13]) }]]),
    userCollections: [
      { id: 'favorite', apps: new Set([7]) },
      { id: 'hidden', apps: new Set([13]) },
      { id: 'x1', displayName: 'MyRPGs', apps: new Set([7, 13]) },
    ],
  };
  const p = page({ store: { m_mapApps: apps }, collections });
  await p.flush();
  t.ok(p.fetched.length === 1 && p.fetched[0].url === 'Cartouche.GetExportToken#1',
       'the launch token comes from the authenticated export process');
  t.ok(p.ms === 15000, 'polls every 15 seconds, no tight loop');
  t.ok(p.sockets.length === 1, 'one transport socket');
  const ws = p.sockets[0];
  t.ok(ws.url === 'ws://localhost:4242/transportsocket/', 'connects the clientdll transport socket');
  t.ok(ws.frames[0] && ws.frames[0].route === 'TransportAuth.Authenticate#1' && ws.frames[0].auth === 'AUTHK',
       'authenticates with the client auth key first');
  t.ok(ws.frames[0].emsg === 0x80000092, 'frames carry the transport message id');

  const ex = export_msgs(ws);
  t.ok(ex.length === 1, 'one export for the first snapshot');
  const { token, doc } = payload_json(ex[0]);
  t.ok(token === TOKEN, 'payload is prefixed with the fetched token');
  t.ok(doc.version === 1 && doc.steamid === SID, 'export names the logged-in account');
  const ids = doc.apps.map(a => a.appid);
  t.ok(ids.join() === '7,8,13', 'only owned games, sorted');
  t.ok(doc.apps[0].installed === true && doc.apps[1].installed === false, 'installed flag kept');
  t.ok(doc.apps[0].playtime === 42 && doc.apps[0].last_played === 1789999999, 'play fields kept');
  t.ok(doc.apps[2].hidden === true, 'hidden collection marks the app hidden');
  t.ok(doc.collections.length === 1 && doc.collections[0].id === 'x1' &&
       doc.collections[0].apps.join() === '7,13', 'user collections only');

  // Debounce: an unchanged snapshot sends nothing and does not fetch again.
  await p.poll();
  t.ok(export_msgs(ws).length === 1, 'unchanged library is not re-exported');
  t.ok(p.fetched.length === 1, 'an unchanged library skips the token fetch');

  // A new owned game re-exports; the token is fetched again at run time, so a
  // cached page always presents this launch's token rather than a stale one.
  p.token = TOKEN_NEXT;
  apps.set(14, app(14, { display_name: 'New One' }));
  await p.poll();
  t.ok(export_msgs(ws).length === 2, 'an owned set change re-exports');
  t.ok(payload_json(export_msgs(ws)[1]).token === TOKEN_NEXT,
       'a cached page always presents this launch\'s token');
  t.ok(payload_json(export_msgs(ws)[1]).doc.apps.length === 4, 'new app in the new export');

  // A failed export retries on the next poll, backing off and logging once.
  apps.set(15, app(15));
  const p2opts = { store: { m_mapApps: apps }, collections, exportResult: 2 };
  const p2 = page(p2opts);
  await p2.flush();
  t.ok(export_msgs(p2.sockets[0]).length === 1 && p2.warnings.length === 1,
       'a refused export is logged once');
  t.ok(p2.ms === 30000, 'a refused export backs off');
  await p2.poll();
  t.ok(export_msgs(p2.sockets[0]).length === 2, 'a refused export retries on the next poll');
  t.ok(p2.warnings.length === 1 && p2.ms === 60000, 'refusals stay quiet and keep backing off');

  // A launch that does not serve the token (an older dylib, or a refusal) is
  // refused the same way: one warning, exponential backoff, no export.
  const p3 = page({ store: { m_mapApps: apps }, token: '' });
  await p3.flush();
  t.ok(p3.fetched[0].url === 'Cartouche.GetExportToken#1' && export_msgs(p3.sockets[0]).length === 0,
       'an unanswered token route never exports');
  t.ok(p3.warnings.length === 1 && p3.ms === 30000, 'a refused token backs off quietly');
  await p3.poll();
  t.ok(p3.warnings.length === 1 && p3.ms === 60000 && export_msgs(p3.sockets[0]).length === 0,
       'a launch without the token keeps backing off without logging again');
  p3.token = TOKEN;
  await p3.poll();
  t.ok(p3.sockets.length === 1 && export_msgs(p3.sockets[0]).length === 1 && p3.ms === 15000,
       'a token that appears later resumes the export');

  // The route still answers without transport info only when info is missing.
  const p4 = page({ store: { m_mapApps: apps }, info: {} });
  await p4.flush();
  t.ok(p4.sockets.length === 0, 'no transport info means no socket');

  // Run these exact injected bytes through the C token and export handlers in
  // one process, rather than replacing both ends with matching fake tokens.
  if (process.argv[3]) {
    const child = spawn(process.argv[3], ['--bridge']);
    const lines = require('readline').createInterface({ input: child.stdout });
    const waiting = [];
    lines.on('line', line => {
      const [result, hex] = line.split(' ');
      waiting.shift()({ result: Number(result), body: Buffer.from(hex || '', 'hex') });
    });
    const route = msg => new Promise(resolve => {
      waiting.push(resolve);
      child.stdin.write(msg.route === 'Cartouche.GetExportToken#1'
        ? 'token\n' : Buffer.from(bytes_field(msg.body)).toString('hex') + '\n');
    });
    const live = page({ store: { m_mapApps: apps }, collections, route });
    const done = new Promise((resolve, reject) => {
      const timer = global.setTimeout(() => reject(new Error('C route test timed out')), 5000);
      const check = () => {
        if (live.ms === 15000 || live.warnings.length) {
          clearTimeout(timer); resolve();
        } else setImmediate(check);
      };
      check();
    });
    try {
      await done;
      t.ok(live.warnings.length === 0 && live.ms === 15000,
           'exact injected JS obtains a token and real C export route accepts it');
      const accepted = export_msgs(live.sockets[0])[0];
      const raw = Buffer.from(bytes_field(accepted.body));
      raw.fill(48, 0, 32);
      const refused = await route({ route: 'Cartouche.ExportOwnedGames#1', body: f2(1, raw) });
      t.ok(refused.result === 2, 'real export route rejects a different process token');
    } finally { child.stdin.end(); }
  }

  if (t.failed) { console.error(`library-export: ${t.failed} failed`); process.exit(1); }
  console.log('==> library export: live token, authed socket, owned games only, backed-off refusals');
})();
