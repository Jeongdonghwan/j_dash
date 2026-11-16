#!/usr/bin/env bash
# SEO 대시보드 설치 (nginx 정적 사이트 서버). 다시 돌리면 스크립트·화면만 새로 깔린다.
set -euo pipefail
mkdir -p /opt/seo-dash /var/www/seo-dash /var/lib/seo-dash

cat > /opt/seo-dash/dash.py <<'DASH_PY_EOF'
#!/usr/bin/env python3
"""SEO 대시보드 수집기 — 정적 사이트 서버(nginx)에서 하루 한 번 돈다. 표준 라이브러리만.

  python3 dash.py [--indexnow]

읽는 것: nginx sites-enabled(사이트 이름·root) / 각 root 의 sitemap(공개 페이지·블로그 글, .ops.json 있으면 전체 제작 수·남은 일정)
        / nginx 접속 기록(로봇 수집·검색 유입·404). vhost.log(맨 앞에 $host)가 있으면 그것을, 그 전 날짜는 access.log 를
        경로로 사이트를 역추적해 대략 복원한다(메인·robots 는 못 가린다).
쓰는 것: $DASH_OUT/data.json (index.html 이 읽는다), $DASH_STATE/state.json (날짜별 집계·수집된 경로·IndexNow 대기열)
--indexnow: 새로 열린 주소를 네이버·IndexNow 로 보낸다(미리보기 사이트 제외). 429 가 오면 그 사이트는 멈추고 다음 날 다시.
"""
import datetime as dt, glob, gzip, html, http.client, json, os, re, secrets, sys, urllib.error, urllib.parse, urllib.request
from collections import Counter, defaultdict

for _s in (sys.stdout, sys.stderr):
    try: _s.reconfigure(encoding='utf-8')
    except Exception: pass
E = os.environ.get
NGINX, LOGS = E('DASH_NGINX', '/etc/nginx/sites-enabled'), E('DASH_LOGS', '/var/log/nginx')
STATE, OUT = E('DASH_STATE', '/var/lib/seo-dash'), E('DASH_OUT', '/var/www/seo-dash')
TODAY = dt.datetime.now(dt.timezone(dt.timedelta(hours=9))).date().isoformat()  # KST
BOTS = [('naver', 'Yeti'), ('google', 'Googlebot'), ('bing', 'bingbot'), ('daum', 'Daum'), ('ai', 'GPTBot'), ('ai', 'OAI-SearchBot'),
        ('ai', 'ChatGPT-User'), ('ai', 'ClaudeBot'), ('ai', 'Claude-SearchBot'), ('ai', 'Claude-User'), ('ai', 'PerplexityBot')]
REFS = [('naver', 'search.naver.com'), ('naver_etc', 'naver.com'), ('google', 'google.'), ('daum', 'search.daum.net'), ('bing', 'bing.com')]
LINE = re.compile(r'(\S+) \S+ \S+ \[(\d\d)/(\w{3})/(\d{4})[^\]]*\] "(\S+) (\S+)[^"]*" (\d{3}) \S+ "([^"]*)" "([^"]*)"')
MON = {m: f'{i:02d}' for i, m in enumerate('Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec'.split(), 1)}


def find_sites():
    out = {}
    for f in sorted(glob.glob(NGINX + '/*')):
        for blk in re.split(r'\n\s*server\s*\{', '\n' + open(f, encoding='utf-8', errors='ignore').read())[1:]:
            names, root = re.search(r'server_name\s+([^;]+);', blk), re.search(r'\broot\s+([^;]+);', blk)
            if not names or not root: continue
            root = root.group(1).strip().rstrip('/')
            if not os.path.isfile(root + '/sitemap.xml'): continue
            s = out.setdefault(root, {'root': root, 'hosts': []})
            s['hosts'] += [h for h in names.group(1).split() if h != '_' and h not in s['hosts']]
    res = []
    for s in out.values():
        if not s['hosts']: continue
        h = s['hosts'][0]
        try: s['name'] = h.encode('ascii').decode('idna')
        except Exception: s['name'] = h
        s['preview'] = 'sslip.io' in h
        res.append(s)
    return res


def norm(p):
    p = urllib.parse.unquote(p.split('?')[0])
    return p if p.endswith('/') or '.' in p.rsplit('/', 1)[-1] else p + '/'


def read_sitemap(root):
    """경로 → (lastmod, 원래 loc, 묶음 파일 이름)"""
    def rd(n):
        p = os.path.join(root, n)
        return open(p, encoding='utf-8', errors='ignore').read() if os.path.isfile(p) else ''
    raw, res = rd('sitemap.xml'), {}
    parts = [(os.path.basename(u), rd(os.path.basename(u))) for u in re.findall(r'<loc>(.*?)</loc>', raw)] if '<sitemapindex' in raw else [('sitemap.xml', raw)]
    for name, body in parts:
        for blk in re.findall(r'<url>(.*?)</url>', body, re.S):
            loc, lm = re.search(r'<loc>(.*?)</loc>', blk), re.search(r'<lastmod>(.*?)</lastmod>', blk)
            if loc:
                u = html.unescape(loc.group(1).strip())
                res[norm(urllib.parse.urlparse(u).path)] = (lm.group(1)[:10] if lm else '', u, name)
    return res


def is_page(path):
    return not path.startswith('/_next') and ('.' not in path.rsplit('/', 1)[-1] or path.endswith('.html'))


def parse_logs(sites):
    """날짜·사이트별 집계. 반환: days[root][date] = Counter, crawled[root][bot] = {경로}, landing[root] = Counter(최근 7일)"""
    by_host = {h: s['root'] for s in sites for h in s['hosts']}
    seg = {}  # 첫 경로 조각 → root (한 사이트에만 있는 것만) — host 없는 옛 기록용
    for s in sites:
        for base, pre in ((s['root'], ''), (s['root'] + '/blog', 'blog/')):
            for n in (os.listdir(base) if os.path.isdir(base) else []):
                k = pre + n
                seg[k] = None if k in seg and seg[k] != s['root'] else s['root']
    days, crawled, landing = defaultdict(lambda: defaultdict(Counter)), defaultdict(lambda: defaultdict(set)), defaultdict(Counter)
    week = (dt.date.fromisoformat(TODAY) - dt.timedelta(days=7)).isoformat()
    vfiles, afiles = sorted(glob.glob(LOGS + '/vhost.log*')), sorted(glob.glob(LOGS + '/access.log*'))
    vdates = set()

    def feed(files, has_host):
        for f in files:
            with (gzip.open if f.endswith('.gz') else open)(f, 'rt', encoding='utf-8', errors='ignore') as fh:
                for line in fh:
                    host = None
                    if has_host:
                        host, _, line = line.partition(' ')
                    m = LINE.match(line)
                    if not m: continue
                    _, dd, mon, yy, method, req, status, ref, ua = m.groups()
                    d = f'{yy}-{MON.get(mon, "00")}-{dd}'
                    if has_host: vdates.add(d)
                    elif d in vdates: continue  # vhost 기록이 있는 날은 그쪽만
                    path = norm(req)
                    if has_host: root = by_host.get(host)
                    else:
                        parts = path.strip('/').split('/')
                        root = seg.get('blog/' + parts[1] if parts[0] == 'blog' and len(parts) > 1 else parts[0])
                        if not root:
                            rh = urllib.parse.urlparse(ref).netloc
                            root = by_host.get(rh)
                    if not root: continue
                    c = days[root][d]
                    bot = next((b for b, k in BOTS if k in ua), None)
                    if '_rsc=' in req:
                        if bot: c['rsc_' + bot] += 1
                        continue
                    if method != 'GET' or not is_page(path): continue
                    if status == '404': c['404'] += 1
                    if status != '200': continue
                    if bot:
                        c['bot_' + bot] += 1
                        crawled[root][bot].add(path)
                    else:
                        c['views'] += 1
                        rh = urllib.parse.urlparse(ref).netloc
                        src = next((n for n, k in REFS if k in rh), None) if rh else None
                        if src:
                            c['ref_' + src] += 1
                            if d >= week: landing[root][path] += 1
    feed(vfiles, True); feed(afiles, False)
    return days, crawled, landing, min(vdates) if vdates else None


def health(site, sm):
    bad, paths = Counter(), list(sm)[:: max(1, len(sm) // 30)][:30]
    for p in paths:
        q = os.path.join(site['root'], p.strip('/'))
        f = next((x for x in (os.path.join(q, 'index.html'), q + '.html', q) if os.path.isfile(x)), None)
        if not f: bad['파일 없음'] += 1; continue
        t = open(f, encoding='utf-8', errors='ignore').read(20000)
        if 'rel="canonical"' not in t: bad['canonical 없음'] += 1
        if re.search(r'<meta name="robots" content="[^"]*noindex', t): bad['noindex'] += 1
    try:
        c = http.client.HTTPConnection('127.0.0.1', 80, timeout=10); c.request('GET', '/', headers={'Host': site['hosts'][0]})
        st = c.getresponse().status
        if st not in (200, 301, 302, 308): bad[f'메인 {st}'] += 1
    except Exception as e:
        bad['메인 접속 실패'] += 1
    return dict(bad)


def indexnow(site, st):
    """창구마다 대기 목록을 따로 둔다 — 한쪽이 거절해도 다른 쪽에 같은 주소를 또 보내지 않는다."""
    key = st.setdefault('key', secrets.token_hex(16))
    kf = os.path.join(site['root'], key + '.txt')
    if not os.path.exists(kf): open(kf, 'w').write(key)
    res = {}
    for name, ep, q in (('naver', 'https://searchadvisor.naver.com/indexnow', 'pending'), ('indexnow', 'https://api.indexnow.org/indexnow', 'pending_etc')):
        urls = st.get(q) or []
        if not urls: continue
        u0 = urllib.parse.urlparse(urls[0])
        for i in range(0, len(urls), 10000):
            body = json.dumps({'host': u0.netloc, 'key': key, 'keyLocation': f'{u0.scheme}://{u0.netloc}/{key}.txt', 'urlList': urls[i:i + 10000]}).encode()
            try: code = urllib.request.urlopen(urllib.request.Request(ep, body, {'Content-Type': 'application/json; charset=utf-8'}), timeout=60).status
            except urllib.error.HTTPError as e: code = e.code
            except Exception as e: code = str(e)[:60]
            res[name] = code
            if code not in (200, 202): break
        else: st[q] = []
    return res


def main():
    os.makedirs(STATE, exist_ok=True); os.makedirs(OUT, exist_ok=True)
    sp = os.path.join(STATE, 'state.json')
    state = json.load(open(sp, encoding='utf-8')) if os.path.exists(sp) else {}
    sites = find_sites()
    days, crawled, landing, vstart = parse_logs(sites)
    data = {'updated': dt.datetime.now(dt.timezone(dt.timedelta(hours=9))).strftime('%Y-%m-%d %H:%M'), 'exact_from': vstart, 'sites': []}
    for s in sites:
        st = state.setdefault(s['root'], {'paths': {}, 'crawled': {}, 'days': {}, 'pending': []})
        sm = read_sitemap(s['root'])
        first = not st['paths']
        new = [p for p in sm if p not in st['paths']]
        for p in new: st['paths'][p] = '' if first else TODAY   # 첫 실행은 기준선(오늘 열림으로 세지 않는다)
        for p in [p for p in st['paths'] if p not in sm]: del st['paths'][p]
        blog = [p for p in sm if re.match(r'/blog/.+', p)]
        for d, c in days[s['root']].items(): st['days'].setdefault(d, {}).update(c)
        st['days'].setdefault(TODAY, {}).update({
            'pages': len(sm) - len(blog), 'posts': len(blog),
            'new_pages': sum(1 for p in sm if st['paths'][p] == TODAY and p not in blog),
            'new_posts': sum(1 for p in blog if st['paths'][p] == TODAY)})
        for b, ps in crawled[s['root']].items(): st['crawled'][b] = sorted(set(st['crawled'].get(b, [])) | ps)
        got = {b: set(st['crawled'].get(b, [])) & set(sm) for b in ('naver', 'google')}
        parts = defaultdict(lambda: [0, 0, 0])
        for p, (_, _, name) in sm.items():
            parts[name][0] += 1; parts[name][1] += p in got['naver']; parts[name][2] += p in got['google']
        inow = st.get('indexnow')
        if not s['preview']:
            if 'pending_etc' not in st:  # 옛 상태: 공용 창구가 거절했으면 전체를 다시 보낸다
                st['pending_etc'] = [] if (inow or {}).get('indexnow') in (200, 202) else [v[1] for v in sm.values()]
            for q in ('pending', 'pending_etc'):
                st[q] = list(dict.fromkeys(st.get(q, []) + [sm[p][1] for p in new]))
        if '--indexnow' in sys.argv and not s['preview'] and (st['pending'] or st['pending_etc']):
            n = max(len(st['pending']), len(st['pending_etc']))
            inow = {**(inow or {}), 'date': TODAY, 'count': n, **indexnow(s, st)}
            st['indexnow'] = inow
        ops = {}
        try: ops = json.load(open(os.path.join(s['root'], '.ops.json'), encoding='utf-8'))
        except Exception: pass
        hl = health(s, sm)
        dl = sorted(st['days'])[-45:]
        data['sites'].append({
            'name': s['name'], 'host': s['hosts'][0], 'preview': s['preview'], 'pages': len(sm) - len(blog), 'posts': len(blog),
            'crawl': {b: len(got[b]) for b in got}, 'total': len(sm), 'ops': ops, 'health': hl, 'indexnow': inow, 'pending': len(st['pending']),
            'parts': [[n] + v for n, v in sorted(parts.items())],
            'top': landing[s['root']].most_common(15),
            'days': [dict(d=d, **st['days'][d]) for d in dl]})
    data['sites'].sort(key=lambda x: (x['preview'], -x['total']))
    json.dump(state, open(sp, 'w', encoding='utf-8'), ensure_ascii=False)
    json.dump(data, open(os.path.join(OUT, 'data.json'), 'w', encoding='utf-8'), ensure_ascii=False)
    print(f'{data["updated"]} 사이트 {len(sites)}개, 공개 주소 {sum(x["total"] for x in data["sites"])}개')
    for x in data['sites']:
        print(f'  {x["name"]}: 페이지 {x["pages"]} · 글 {x["posts"]} · 네이버 수집 {x["crawl"]["naver"]} · 구글 수집 {x["crawl"]["google"]}'
              + (f' · IndexNow {x["indexnow"]}' if x['indexnow'] and x['indexnow'].get('date') == TODAY else '') + (f' · 점검 {x["health"]}' if x['health'] else ''))


if __name__ == '__main__':
    main()
DASH_PY_EOF

cat > /var/www/seo-dash/index.html <<'DASH_HTML_EOF'
<!doctype html>
<html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow">
<title>SEO 대시보드</title>
<style>
:root{--bg:#f6f7f8;--card:#fff;--ink:#16191d;--mute:#69707a;--line:#dfe3e8;--naver:#0a8f4d;--google:#2b62d9;--warn:#b4380d;--bar:#c9d2dc}
@media(prefers-color-scheme:dark){:root{--bg:#111316;--card:#1a1d21;--ink:#e8eaed;--mute:#98a0aa;--line:#2c3138;--naver:#35c17a;--google:#7aa2f7;--warn:#f0855a;--bar:#3a424c}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.5 Pretendard,system-ui,'Malgun Gothic',sans-serif}
.wrap{max-width:1500px;margin:0 auto;padding:24px 16px 80px}h1{font-size:20px;margin:0}
.top{display:flex;justify-content:space-between;align-items:baseline;gap:16px;flex-wrap:wrap;margin-bottom:6px}.mute{color:var(--mute)}.small{font-size:12px}
.sum{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:1px;background:var(--line);border:1px solid var(--line);margin:16px 0 20px}
.sum div{background:var(--card);padding:12px 14px}.sum b{display:block;font-size:20px;font-variant-numeric:tabular-nums}
.scroll{overflow-x:auto;border:1px solid var(--line);background:var(--card)}
table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}th,td{padding:8px 10px;border-bottom:1px solid var(--line);text-align:right;white-space:nowrap}
th{font-weight:600;font-size:12px;color:var(--mute);background:var(--card);position:sticky;top:0}th:first-child,td:first-child{text-align:left}
tr.site{cursor:pointer}tr.site:hover td{background:rgba(127,127,127,.07)}tr.pre td:first-child{color:var(--mute)}
.n{color:var(--naver)}.g{color:var(--google)}.w{color:var(--warn)}.zero{color:var(--mute)}
td.detail{text-align:left;padding:16px;background:var(--bg);white-space:normal}.cols{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:20px}
.detail h3{font-size:13px;margin:0 0 6px}.detail table th,.detail table td{padding:4px 8px;font-size:12px}.detail .scroll{max-height:420px}
svg{vertical-align:middle}a{color:inherit}
</style></head><body><div class="wrap">
<div class="top"><h1>SEO 대시보드</h1><span class="mute small" id="upd"></span></div>
<p class="mute small" id="note"></p>
<div class="sum" id="sum"></div>
<div class="scroll"><table id="t"></table></div>
<p class="mute small">행을 누르면 날짜별 기록·묶음별 수집률·유입 상위 페이지가 열립니다. 수집 = 검색 로봇이 페이지를 정상(200)으로 가져간 횟수. 수집률 = 로봇이 한 번이라도 가져간 페이지 ÷ 공개 페이지. 네이버 앱 유입은 경로가 안 남는 경우가 있어 실제보다 적게 잡힙니다.</p>
</div><script>
const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const f=n=>n?Number(n).toLocaleString('ko-KR'):'<span class="zero">0</span>';
const pct=(a,b)=>b?Math.round(a/b*1000)/10+'%':'-';
const day=(n)=>{const d=new Date(Date.now()+9*36e5-n*864e5);return d.toISOString().slice(0,10)};
const sumk=(days,k,from)=>days.filter(x=>x.d>=from).reduce((a,x)=>a+(x[k]||0),0);
function spark(days,k,color){const last=[];for(let i=13;i>=0;i--){const d=day(i),x=days.find(y=>y.d===d);last.push(x?x[k]||0:0)}
  const m=Math.max(1,...last);return '<svg width="86" height="20">'+last.map((v,i)=>`<rect x="${i*6}" y="${20-Math.max(v?2:1,v/m*20)}" width="5" height="${Math.max(v?2:1,v/m*20)}" fill="${v?color:'var(--bar)'}"><title>${day(13-i)}: ${v}</title></rect>`).join('')+'</svg>'}
function detail(s){
  const rows=s.days.slice().reverse().slice(0,30).map(x=>`<tr><td>${x.d}</td><td>${f(x.new_pages)}</td><td>${f(x.new_posts)}</td><td class="n">${f(x.bot_naver)}</td><td class="g">${f(x.bot_google)}</td><td>${f((x.bot_bing||0)+(x.bot_daum||0))}</td><td>${f(x.bot_ai)}</td><td class="w">${f(x.rsc_naver)}</td><td class="n">${f(x.ref_naver)}</td><td>${f(x.ref_naver_etc)}</td><td class="g">${f(x.ref_google)}</td><td>${f((x.ref_daum||0)+(x.ref_bing||0))}</td><td>${f(x.views)}</td><td>${f(x['404'])}</td></tr>`).join('');
  const parts=s.parts.map(p=>`<tr><td>${esc(p[0])}</td><td>${f(p[1])}</td><td class="n">${f(p[2])} (${pct(p[2],p[1])})</td><td class="g">${f(p[3])} (${pct(p[3],p[1])})</td></tr>`).join('');
  const top=s.top.map(p=>`<tr><td><a href="https://${esc(s.host)}${encodeURI(p[0])}" target="_blank" rel="noopener">${esc(p[0])}</a></td><td>${f(p[1])}</td></tr>`).join('')||'<tr><td class="mute">최근 7일 검색 유입 없음</td><td></td></tr>';
  const o=s.ops||{},inow=s.indexnow;
  const sched=(o.schedule||[]).filter(x=>x.date>day(0)).map(x=>`${x.date} 페이지 ${x.pages||0} · 글 ${x.posts||0}`).join('<br>');
  return `<div class="cols"><div style="grid-column:1/-1"><h3>날짜별</h3><div class="scroll"><table><tr><th>날짜</th><th>열린 페이지</th><th>발행 글</th><th>네이버 수집</th><th>구글 수집</th><th>빙·다음</th><th>AI 로봇</th><th>네이버 낭비(_rsc)</th><th>네이버 검색 유입</th><th>네이버 기타</th><th>구글 유입</th><th>다음·빙</th><th>사람 조회</th><th>404</th></tr>${rows}</table></div></div>
  <div><h3>묶음별 수집률</h3><div class="scroll"><table><tr><th>사이트맵 묶음</th><th>주소</th><th>네이버</th><th>구글</th></tr>${parts}</table></div></div>
  <div><h3>검색 유입 상위 (7일)</h3><div class="scroll"><table><tr><th>페이지</th><th>유입</th></tr>${top}</table></div></div>
  <div><h3>기타</h3><p class="small">IndexNow: ${inow?`${esc(inow.date)} ${f(inow.count)}개 전송 (네이버 ${esc(inow.naver)}, 공용 ${esc(inow.indexnow)})`:'전송 기록 없음'} · 대기 ${f(s.pending)}개<br>
  점검: ${Object.keys(s.health||{}).length?'<span class="w">'+esc(JSON.stringify(s.health))+'</span>':'이상 없음'}<br>
  ${o.total_pages?`전체 제작 페이지 ${f(o.total_pages)} · 써 둔 글 ${f(o.total_posts)}<br>`:''}${sched?'남은 일정<br>'+sched:''}</p></div></div>`}
fetch('data.json?'+Date.now()).then(r=>r.json()).then(d=>{
  document.getElementById('upd').textContent='갱신 '+d.updated;
  document.getElementById('note').textContent=d.exact_from?`${d.exact_from}부터는 사이트별로 정확히 집계합니다. 그 전 날짜는 주소로 역추적한 값이라 메인·robots 요청이 빠져 있습니다.`:'사이트별 기록이 아직 없어 주소로 역추적한 값입니다(메인·robots 요청 제외).';
  const y=day(1),w=day(7),live=d.sites.filter(s=>!s.preview);
  const tot=(fn)=>live.reduce((a,s)=>a+fn(s),0);
  document.getElementById('sum').innerHTML=[['운영 사이트',live.length],['공개 페이지',tot(s=>s.pages)],['공개 글',tot(s=>s.posts)],['오늘 열린 페이지',tot(s=>sumk(s.days,'new_pages',day(0)))],['오늘 발행 글',tot(s=>sumk(s.days,'new_posts',day(0)))],['어제 네이버 수집',tot(s=>sumk(s.days.filter(x=>x.d===y),'bot_naver',y))],['어제 구글 수집',tot(s=>sumk(s.days.filter(x=>x.d===y),'bot_google',y))],['7일 검색 유입',tot(s=>sumk(s.days,'ref_naver',w)+sumk(s.days,'ref_google',w)+sumk(s.days,'ref_daum',w))]].map(([k,v])=>`<div><span class="mute small">${k}</span><b>${f(v)}</b></div>`).join('');
  const head='<tr><th>사이트</th><th>전체 제작</th><th>공개 페이지</th><th>오늘 열림</th><th>공개 글</th><th>오늘 발행</th><th>네이버 수집 어제 / 7일</th><th>14일</th><th>구글 수집 어제 / 7일</th><th>14일</th><th>수집률 네이버</th><th>수집률 구글</th><th>검색 유입 7일 (네이버 / 구글 / 다음)</th><th>상태</th></tr>';
  const t=document.getElementById('t');
  t.innerHTML=head+d.sites.map((s,i)=>{const yd=s.days.find(x=>x.d===y)||{},td=s.days.find(x=>x.d===day(0))||{},bad=Object.keys(s.health||{}).length;
    return `<tr class="site${s.preview?' pre':''}" data-i="${i}"><td>${esc(s.name)}${s.preview?' <span class="small">(미리보기)</span>':''}</td><td>${s.ops&&s.ops.total_pages?f(s.ops.total_pages):'<span class="zero">-</span>'}</td><td>${f(s.pages)}</td><td>${f(td.new_pages)}</td><td>${f(s.posts)}</td><td>${f(td.new_posts)}</td>
    <td class="n">${f(yd.bot_naver)} / ${f(sumk(s.days,'bot_naver',w))}</td><td>${spark(s.days,'bot_naver','var(--naver)')}</td><td class="g">${f(yd.bot_google)} / ${f(sumk(s.days,'bot_google',w))}</td><td>${spark(s.days,'bot_google','var(--google)')}</td>
    <td class="n">${pct(s.crawl.naver,s.total)}</td><td class="g">${pct(s.crawl.google,s.total)}</td><td>${f(sumk(s.days,'ref_naver',w))} / ${f(sumk(s.days,'ref_google',w))} / ${f(sumk(s.days,'ref_daum',w))}</td><td>${bad?'<span class="w">점검 '+bad+'</span>':'정상'}</td></tr>`}).join('');
  t.addEventListener('click',e=>{const tr=e.target.closest('tr.site');if(!tr)return;const nx=tr.nextElementSibling;
    if(nx&&nx.classList.contains('dt')){nx.remove();return}const r=document.createElement('tr');r.className='dt';r.innerHTML=`<td class="detail" colspan="14">${detail(d.sites[tr.dataset.i])}</td>`;tr.after(r)});
}).catch(e=>{document.getElementById('note').textContent='data.json 을 읽지 못했습니다: '+e});
</script></body></html>
DASH_HTML_EOF

# 1) 접속 기록에 사이트 이름을 남기는 파일 추가 (기존 access.log 는 그대로)
if grep -q "conf.d/\*.conf" /etc/nginx/nginx.conf; then
cat > /etc/nginx/conf.d/vhostlog.conf <<'EOF'
log_format vhost '$host $remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent"';
access_log /var/log/nginx/vhost.log vhost;
EOF
else echo "!! nginx.conf 가 conf.d 를 읽지 않음 — 사이트별 기록 추가를 건너뜀"; fi

# 2) 비밀번호 (처음 한 번)
if [ ! -f /etc/nginx/.seo-dash.htpasswd ]; then
  PW=$(openssl rand -hex 6)
  printf 'admin:%s\n' "$(openssl passwd -apr1 "$PW")" > /etc/nginx/.seo-dash.htpasswd
  chown root:www-data /etc/nginx/.seo-dash.htpasswd; chmod 640 /etc/nginx/.seo-dash.htpasswd
  echo "$PW" > /root/seo-dash-password.txt; chmod 600 /root/seo-dash-password.txt
fi

# 3) 대시보드 주소
if [ ! -f /etc/nginx/sites-available/seo-dash ]; then
cat > /etc/nginx/sites-available/seo-dash <<'EOF'
server {
    listen 80;
    server_name ops.172.237.20.244.sslip.io;
    root /var/www/seo-dash;
    index index.html;
    auth_basic "seo-dash";
    auth_basic_user_file /etc/nginx/.seo-dash.htpasswd;
    add_header X-Robots-Tag "noindex, nofollow" always;
}
EOF
ln -sf /etc/nginx/sites-available/seo-dash /etc/nginx/sites-enabled/seo-dash
fi
if nginx -t; then systemctl reload nginx; else rm -f /etc/nginx/conf.d/vhostlog.conf /etc/nginx/sites-enabled/seo-dash; echo "!! nginx 설정 오류 — 추가한 설정을 되돌림"; exit 1; fi
grep -q "ssl" /etc/nginx/sites-available/seo-dash || certbot --nginx -d ops.172.237.20.244.sslip.io --agree-tos --register-unsafely-without-email --redirect -n || echo "(HTTPS 발급 실패 — http 로 사용)"

# 4) 하루 두 번 갱신 (서버가 deploy 브랜치를 받은 뒤)
echo '30 7,15 * * * root /usr/bin/python3 /opt/seo-dash/dash.py --indexnow >> /var/log/seo-dash.log 2>&1' > /etc/cron.d/seo-dash

# 5) deploy 브랜치를 자동으로 받지 않는 사이트 확인
echo "== 자동 받기(cron)가 없는 사이트 폴더"
for d in /var/www/*/; do d=${d%/}; [ -d "$d/.git" ] && [ -f "$d/sitemap.xml" ] && ! crontab -l 2>/dev/null | grep -q "cd $d " && echo "  $d"; done; true

# 6) 첫 실행 (열려 있는 주소를 IndexNow 로 한 번 보낸다)
echo "== 첫 실행"
python3 /opt/seo-dash/dash.py --indexnow | tee -a /var/log/seo-dash.log
echo
echo "대시보드: http://ops.172.237.20.244.sslip.io/  (https 발급됐으면 https)"
echo "아이디 admin / 비밀번호 $(cat /root/seo-dash-password.txt)"
