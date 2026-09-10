// Cloudflare Worker behind limits.kirs.online.
//
//   POST /push   X-Token: <TOKEN secret>   body = the Mac's payload  -> KV
//   GET  /u.json                                                     -> that payload
//   GET  /                                                           -> page rendering it
//
// One KV key. The Mac only pushes when the numbers change (plus a 10 min
// heartbeat), so the free tier's 1000 writes/day is never in play.
const KEY = 'u';

export default {
  async fetch(req, env) {
    const { pathname } = new URL(req.url);

    if (req.method === 'POST' && pathname === '/push') {
      if (req.headers.get('x-token') !== env.TOKEN) return new Response('nope', { status: 401 });
      await env.KV.put(KEY, await req.text());
      return new Response('ok');
    }

    if (pathname === '/manifest.webmanifest') {
      return new Response(MANIFEST, { headers: { 'content-type': 'application/manifest+json' } });
    }
    if (pathname === '/sw.js') {
      return new Response(SW, { headers: { 'content-type': 'text/javascript' } });
    }
    const icon = ICONS[pathname];
    if (icon) {
      return new Response(Uint8Array.from(atob(icon), c => c.charCodeAt(0)),
        { headers: { 'content-type': 'image/png', 'cache-control': 'public,max-age=604800' } });
    }

    const data = (await env.KV.get(KEY)) || '{"ts":0,"blocks":[]}';
    if (pathname === '/u.json') {
      return new Response(data, { headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });
    }
    return new Response(PAGE, { headers: { 'content-type': 'text/html;charset=utf-8' } });
  },
};

const PAGE = `<!doctype html><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>limits</title>
<link rel=manifest href=/manifest.webmanifest>
<meta name=theme-color content="#111111">
<link rel=apple-touch-icon href=/icon-192.png>
<style>
:root{--bg:#111;--card:#171717;--fg:#e5e7eb;--dim:#8b8f96;--faint:#5f636a;--line:#242424;--violet:#a78bfa;--gold:#eab308;--track:#232323}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:13px/1.2 ui-monospace,Menlo,monospace;padding:10px}
#grid{display:grid;gap:8px;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));max-width:1100px;margin:0 auto}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:8px 10px 7px}
.hd{display:flex;align-items:baseline;gap:5px;margin-bottom:6px}
.nm{font-size:15px;font-weight:700;letter-spacing:-.01em}
.tg{color:var(--violet);font-size:11px;font-weight:700}
.pl{margin-left:auto;color:var(--faint);font-size:10px}
.r{display:grid;grid-template-columns:2.4em 1fr 2.1em 2.4em;align-items:center;gap:6px;height:15px}
.r.s{grid-template-columns:4.6em 1fr 2.1em 2.4em;height:13px;opacity:.9}
.k{color:var(--dim);font-size:11px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.r.s .k{color:var(--faint);font-size:10px}
.t{height:7px;background:var(--track);border-radius:2px;overflow:hidden}
.r.s .t{height:4px}
.t i{display:block;height:100%;border-radius:2px}
.v{text-align:right;font-size:13px;font-weight:700;font-variant-numeric:tabular-nums}
.r.s .v{font-size:11px}
.z{text-align:right;color:var(--faint);font-size:10px;font-variant-numeric:tabular-nums}
.sep{height:1px;background:var(--line);margin:5px 0}
.ft{display:flex;gap:8px;align-items:center;margin-top:6px;font-size:10px;color:var(--faint)}
.ft b{color:var(--fg);font-weight:700}
.gold{color:var(--gold)}
.err{color:#EF4444;font-size:11px}
.stale{opacity:.5}
#foot{max-width:1100px;margin:8px auto 0;color:var(--faint);font-size:10px;text-align:center}
</style>
<div id=grid></div><div id=foot></div>
<script>
var C = function (u) { return u >= 85 ? '#EF4444' : u >= 70 ? '#F97316' : u >= 50 ? '#F59E0B' : '#10B981'; };
var esc = function (s) { return String(s).replace(/[&<>"]/g, function (c) { return ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'})[c]; }); };

// Reset time, shortest form that still reads: 3d / 4h12 / 47m / now.
var clock = function (e) {
  var d = e - Date.now() / 1000;
  if (d <= 0) return 'now';
  var h = Math.floor(d / 3600), m = Math.floor((d % 3600) / 60);
  return h >= 24 ? Math.round(h / 24) + 'd' : h ? h + 'h' + (m < 10 ? '0' : '') + m : m + 'm';
};
var ago = function (t) {
  var d = Math.round(Date.now() / 1000 - t);
  return d < 90 ? d + 's' : d < 5400 ? Math.round(d / 60) + 'm' : Math.round(d / 3600) + 'h';
};
// "GPT-5.3-Codex-Spark" -> "Spark". Long names cost a column nobody reads.
var shortName = function (n) { return n.length > 8 ? n.split(/[-\s]/).pop() : n; };

// label · bar · percent · reset, one line, columns aligned across every card.
function row(k, w, sub) {
  if (!w || typeof w.percentUsed !== 'number') return '';
  var u = w.percentUsed, c = C(u);
  return '<div class="r' + (sub ? ' s' : '') + '"><span class=k>' + esc(k) + '</span>'
    + '<span class=t><i style="width:' + u + '%;background:' + c + '"></i></span>'
    + '<span class=v style="color:' + c + '">' + u + '</span>'
    + '<span class=z>' + (w.resetsAt ? clock(w.resetsAt) : '') + '</span></div>';
}

// Header right side: the plan, when there is one. "a***@gmail.com's
// Organization" is the account's own name masked — no information, no room.
var plan = function (n) {
  n = String(n || '').replace(/^Plan:\s*/, '').replace(/'s Organization$/, '');
  return n.indexOf('***') >= 0 ? '' : n;
};

function card(a) {
  var s = a.s || {}, ac = s.account || {}, body = '';
  if (s.status !== 'ok') {
    body = '<div class=err>' + esc(s.status === 'needs_login' ? 'needs login' : (s.errorMsg || s.status || 'no data')) + '</div>';
  } else {
    body = row('5h', s.fiveHour) + row('1w', s.weekly);
    var add = (s.additional || []).map(function (m) {
      var n = shortName(m.label || 'model');
      return row(n + ' 5h', m.fiveHour, 1) + row(n + ' 1w', m.weekly, 1);
    }).join('');
    if (add) body += '<div class=sep></div>' + add;

    var ft = [];
    if (s.resets) ft.push('<span class=gold>&#8635;<b class=gold>' + s.resets + '</b></span>');
    var x = s.extraUsage;
    if (x && typeof x.monthlyLimit === 'number') {
      ft.push('<span' + (x.isEnabled ? '' : ' style="opacity:.55"') + '>$<b>' + (x.usedCredits || 0).toFixed(0) + '</b>/' + x.monthlyLimit.toFixed(0) + '</span>');
    }
    (s.warnings || []).forEach(function (w) { ft.push('<span class=err>' + esc(w) + '</span>'); });
    if (s.lastFetch && Date.now() / 1000 - s.lastFetch > 900) ft.push('<span class=err>' + ago(s.lastFetch) + '</span>');
    if (ft.length) body += '<div class=ft>' + ft.join('') + '</div>';
  }
  var stale = s.lastFetch && Date.now() / 1000 - s.lastFetch > 900;
  return '<div class="card' + (stale ? ' stale' : '') + '">'
    + '<div class=hd><span class=nm>' + esc(a.label || a.provider) + '</span>'
    + (a.tag ? '<span class=tg>' + esc(a.tag) + '</span>' : '')
    + '<span class=pl>' + esc(plan(ac.orgName)) + '</span></div>'
    + body + '</div>';
}

function render(d) {
  document.getElementById('grid').innerHTML = (d.accounts || []).map(card).join('');
  document.getElementById('foot').textContent = d.ts ? ago(d.ts) : 'no data';
}

var tick = function () { return fetch('/u.json', { cache: 'no-store' }).then(function (r) { return r.json(); }).then(render).catch(function () {}); };
tick(); setInterval(tick, 30000);
document.addEventListener('visibilitychange', function () { document.hidden || tick(); });
navigator.serviceWorker && navigator.serviceWorker.register('/sw.js');
</script>`;

// Installed as a PWA: manifest + a service worker with a fetch handler is what
// Chrome on Android wants before it offers "Install app" (a WebAPK, own icon,
// no browser chrome).
const MANIFEST = JSON.stringify({
  name: 'limits',
  short_name: 'limits',
  start_url: '/',
  scope: '/',
  display: 'standalone',
  orientation: 'portrait',
  background_color: '#111111',
  theme_color: '#111111',
  icons: [
    { src: '/icon-192.png', sizes: '192x192', type: 'image/png', purpose: 'any maskable' },
    { src: '/icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any maskable' },
  ],
});

// Shell from cache so the app opens offline; u.json from the network with the
// last payload as fallback (the page's "updated N ago" then shows it is stale).
const SW = `const C = 'v1';
self.addEventListener('install', e => {
  e.waitUntil(caches.open(C).then(c => c.addAll(['/', '/manifest.webmanifest', '/icon-192.png', '/icon-512.png'])).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', e => {
  const u = new URL(e.request.url);
  if (u.origin !== location.origin) return;
  if (u.pathname === '/u.json') {
    e.respondWith(fetch(e.request).then(r => {
      const copy = r.clone();
      caches.open(C).then(c => c.put(e.request, copy));
      return r;
    }).catch(() => caches.match(e.request)));
    return;
  }
  e.respondWith(fetch(e.request).then(r => {
    const copy = r.clone();
    caches.open(C).then(c => c.put(e.request, copy));
    return r;
  }).catch(() => caches.match(e.request)));
});`;

const ICONS = {
  '/icon-192.png': 'iVBORw0KGgoAAAANSUhEUgAAAMAAAADACAIAAADdvvtQAAACV0lEQVR42u3dMU7DMBiGYQdV7N6ZOjAgthyNc3C0bIiBoVNPwcRaMUSK7ci/5edZ2wTUvvqUSq2y5JwTlHryEiAgBISAEBAICAEhIAQEAkJACAgBgYAQEAJCQCAgBISAEBACAgEhIASEgEBACAgBISAQEAJCQAgIBISAEBACQkAgIASEgBAQCAgBISAEBAJCQAgIAYGAEBACQkAgIASEgBAQAgIBISAEhIBAQJzr4iWI5rauO49ety3Uf7vknL1nQ6QTMyMBDZZOtIxcA41aT82BAsKnMFqsSPcREhACmnV+IoyQgBAQAkJACAgEhIAQEAICASEgBETynehJ3D9/95/w8vHsVRJQSTqPT5ORgA6nIyPXQG3qaXKsgGD6gOonZPIRskAIqPd4zDxCFggBISAEhIBAQAgIASEgEBACQkAICASEgBAQAgIBISCSHxb+9/X9s/Po+9urt01AJek8PkdGAjqcjoxcA7Wpp/5AXEQjoBYrYoQsEALquh9GyAIhIAQEAkJACAgBgYAQEAJCQBAwoCbfCCs+Sas7XRSf57pt9X+9yUksELMGVDlClYfXj1DlGSr3o+/8DL9A3b8T3fd2T93riRJQWQet6imOoFU9ZR1EqCeltOSc01A/6zlvew7d8uKM7bmt61j1hAsowg8Lu98zdT+jOOnEDQifwhAQCAgBISAEBAJCQAgIAYGAEBACQkAICASEgBAQAgIBISAEhIBAQAgIASEgEBACQkAICAGBgBAQAkJAICAEhIAQEAgIASEgBAQCQkAICAGBgBAQAkJATOoPGjFyZoRhxsQAAAAASUVORK5CYII=',
  '/icon-512.png': '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',
};
