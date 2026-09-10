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
:root{--bg:#111;--fg:#e5e7eb;--dim:#9ca3af;--line:#262626}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.3 ui-monospace,Menlo,monospace;padding:16px}
#grid{display:grid;gap:10px;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));max-width:760px;margin:0 auto}
.b{border:1px solid var(--line);border-radius:10px;padding:10px 12px;position:relative;overflow:hidden}
.b .bar{position:absolute;left:0;top:0;height:3px;background:currentColor;opacity:.9}
.hd{color:var(--dim);font-size:12px;letter-spacing:.04em;text-transform:lowercase}
.tag{color:#a78bfa}
.pct{font-size:34px;font-weight:700;line-height:1.05;margin-top:4px}
.sub{color:var(--dim);font-size:12px;margin-top:2px}
.gold{color:#eab308}
#foot{max-width:760px;margin:14px auto 0;color:var(--dim);font-size:12px;text-align:center}
</style>
<div id=grid></div><div id=foot>…</div>
<script>
const C = u => u >= 85 ? '#EF4444' : u >= 70 ? '#F97316' : u >= 50 ? '#F59E0B' : '#e5e7eb';
const clock = e => {
  const d = e - Date.now() / 1000;
  if (d <= 0) return '0:00';
  const h = Math.floor(d / 3600), m = Math.floor((d % 3600) / 60);
  return h >= 24 ? Math.round(h / 24) + 'd' : h + ':' + String(m).padStart(2, '0');
};
const esc = s => String(s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const num = (b, k) => typeof b[k] === 'number' ? b[k] : null;

function render(d) {
  document.getElementById('grid').innerHTML = (d.blocks || []).map(b => {
    const five = num(b, 'w5h'), week = num(b, 'w1w');
    const lead = five !== null ? five : week;               // one window -> that one
    const pct = b.text ? esc(b.text)
      : (five !== null && week !== null)
        ? '<span style="color:' + C(five) + '">' + five + '</span><span style="color:var(--dim)">·</span><span style="color:' + C(week) + '">' + week + '</span>'
        : '<span style="color:' + C(lead) + '">' + lead + '</span>';
    const sub = [b.resetsAt ? 'resets ' + clock(b.resetsAt) : null,
                 b.resets ? '<span class=gold>' + b.resets + ' resets</span>' : null]
                .filter(Boolean).join(' · ');
    return '<div class="b" style="color:' + C(lead) + '">'
      + '<div class=bar style="width:' + (lead || 0) + '%"></div>'
      + '<div class=hd>' + esc(b.label) + (b.tag ? '<span class=tag>' + esc(b.tag) + '</span>' : '') + '</div>'
      + '<div class=pct>' + pct + '</div>'
      + '<div class=sub>' + (sub || '&nbsp;') + '</div></div>';
  }).join('');
  const age = Math.round(Date.now() / 1000 - (d.ts || 0));
  document.getElementById('foot').textContent = d.ts
    ? 'updated ' + (age < 90 ? age + 's' : Math.round(age / 60) + 'm') + ' ago'
    : 'no data yet';
}

const tick = () => fetch('/u.json', { cache: 'no-store' }).then(r => r.json()).then(render).catch(() => {});
tick(); setInterval(tick, 30000);
document.addEventListener('visibilitychange', () => document.hidden || tick());
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
