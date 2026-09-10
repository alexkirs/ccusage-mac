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
:root{--bg:#111;--card:#161616;--fg:#e5e7eb;--dim:#9ca3af;--faint:#6b7280;--line:#262626;--violet:#a78bfa;--gold:#eab308}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.35 ui-monospace,Menlo,monospace;padding:14px}
#wrap{max-width:1000px;margin:0 auto}
h1{font-size:13px;font-weight:400;color:var(--faint);letter-spacing:.12em;text-transform:uppercase;margin:2px 0 12px}
#grid{display:grid;gap:12px;grid-template-columns:repeat(auto-fit,minmax(300px,1fr))}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px 14px}
.top{display:flex;align-items:baseline;gap:8px}
.name{font-size:20px;font-weight:700}
.tag{color:var(--violet);font-size:13px;font-weight:700}
.plan{margin-left:auto;color:var(--dim);font-size:12px;text-align:right}
.mail{color:var(--faint);font-size:11px;margin-top:1px}
.win{margin-top:10px}
.wl{display:flex;align-items:baseline;gap:8px;font-size:12px;color:var(--dim)}
.wl .pct{margin-left:auto;font-size:15px;font-weight:700}
.track{height:6px;border-radius:3px;background:#222;margin-top:4px;overflow:hidden}
.fill{height:100%;border-radius:3px}
.sect{margin-top:12px;border-top:1px solid var(--line);padding-top:8px}
.sh{font-size:11px;color:var(--faint);letter-spacing:.1em;text-transform:uppercase}
.mrow{margin-top:7px}
.mname{font-size:12px;color:var(--dim)}
.kv{display:flex;font-size:12px;color:var(--dim);margin-top:5px}
.kv b{margin-left:auto;color:var(--fg);font-weight:700}
.gold{color:var(--gold)}
.err{color:#EF4444;font-size:12px;margin-top:8px}
.stale{opacity:.55}
#foot{color:var(--faint);font-size:12px;text-align:center;margin-top:14px}
</style>
<div id=wrap><h1>limits</h1><div id=grid></div><div id=foot>…</div></div>
<script>
var C = function (u) { return u >= 85 ? '#EF4444' : u >= 70 ? '#F97316' : u >= 50 ? '#F59E0B' : '#10B981'; };
var esc = function (s) { return String(s).replace(/[&<>"]/g, function (c) { return ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'})[c]; }); };
var clock = function (e) {
  var d = e - Date.now() / 1000;
  if (d <= 0) return 'now';
  var h = Math.floor(d / 3600), m = Math.floor((d % 3600) / 60);
  if (h >= 24) return Math.round(h / 24) + 'd';
  return h ? h + 'h ' + m + 'm' : m + 'm';
};
var ago = function (t) {
  var d = Math.round(Date.now() / 1000 - t);
  return d < 90 ? d + 's' : d < 5400 ? Math.round(d / 60) + 'm' : Math.round(d / 3600) + 'h';
};

// One window: name on the left, percent on the right, bar under both.
function win(name, w, big) {
  if (!w || typeof w.percentUsed !== 'number') return '';
  var u = w.percentUsed;
  return '<div class=win><div class=wl><span>' + name + '</span>'
    + (w.resetsAt ? '<span>resets ' + clock(w.resetsAt) + '</span>' : '')
    + '<span class=pct style="color:' + C(u) + ';font-size:' + (big ? 17 : 14) + 'px">' + u + '%</span></div>'
    + '<div class=track><div class=fill style="width:' + u + '%;background:' + C(u) + '"></div></div></div>';
}

function card(a) {
  var s = a.s || {}, ac = s.account || {};
  var body = '';
  if (s.status !== 'ok') {
    body = '<div class=err>' + esc(s.status === 'needs_login' ? 'needs login' : (s.errorMsg || s.status || 'no data')) + '</div>';
  } else {
    body = win('5h', s.fiveHour, true) + win('1w', s.weekly, true);
    var add = s.additional || [];
    if (add.length) {
      body += '<div class=sect><div class=sh>models</div>'
        + add.map(function (m) {
            return '<div class=mrow><div class=mname>' + esc(m.label || 'model') + '</div>'
              + win('5h', m.fiveHour) + win('1w', m.weekly) + '</div>';
          }).join('') + '</div>';
    }
    var extra = '';
    if (typeof s.resets === 'number') {
      extra += '<div class=kv><span>limit resets on hand</span><b class="' + (s.resets ? 'gold' : '') + '">' + s.resets + '</b></div>';
    }
    var x = s.extraUsage;
    if (x) {
      extra += '<div class=kv><span>extra usage</span><b>' + (x.isEnabled ? 'on' : 'off') + '</b></div>';
      if (typeof x.monthlyLimit === 'number') {
        extra += '<div class=kv><span>credits</span><b>' + (x.usedCredits || 0).toFixed(2) + ' / ' + x.monthlyLimit.toFixed(0) + ' ' + esc(x.currency || '') + '</b></div>';
      }
    }
    (s.warnings || []).forEach(function (w) { extra += '<div class=err>' + esc(w) + '</div>'; });
    if (extra) body += '<div class=sect>' + extra + '</div>';
  }
  var stale = s.lastFetch && Date.now() / 1000 - s.lastFetch > 900;
  return '<div class="card' + (stale ? ' stale' : '') + '">'
    + '<div class=top><span class=name>' + esc(a.label || a.provider) + '</span>'
    + (a.tag ? '<span class=tag>' + esc(a.tag) + '</span>' : '')
    + '<span class=plan>' + esc(ac.orgName || a.provider) + '</span></div>'
    + (ac.email ? '<div class=mail>' + esc(ac.email) + '</div>' : '')
    + body
    + (s.lastFetch ? '<div class=kv style="margin-top:10px;color:var(--faint)"><span>fetched ' + ago(s.lastFetch) + ' ago</span></div>' : '')
    + '</div>';
}

function render(d) {
  document.getElementById('grid').innerHTML = (d.accounts || []).map(card).join('');
  document.getElementById('foot').textContent = d.ts ? 'pushed ' + ago(d.ts) + ' ago' : 'no data yet';
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
