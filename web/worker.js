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
</script>`;
