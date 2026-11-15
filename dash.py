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
        f = os.path.join(site['root'], p.strip('/'), 'index.html')
        if not os.path.isfile(f): bad['파일 없음'] += 1; continue
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


def indexnow(site, st, urls):
    key = st.setdefault('key', secrets.token_hex(16))
    kf = os.path.join(site['root'], key + '.txt')
    if not os.path.exists(kf): open(kf, 'w').write(key)
    u0 = urllib.parse.urlparse(urls[0]); res = {}
    for name, ep in (('naver', 'https://searchadvisor.naver.com/indexnow'), ('indexnow', 'https://api.indexnow.org/indexnow')):
        for i in range(0, len(urls), 10000):
            body = json.dumps({'host': u0.netloc, 'key': key, 'keyLocation': f'{u0.scheme}://{u0.netloc}/{key}.txt', 'urlList': urls[i:i + 10000]}).encode()
            try: code = urllib.request.urlopen(urllib.request.Request(ep, body, {'Content-Type': 'application/json; charset=utf-8'}), timeout=60).status
            except urllib.error.HTTPError as e: code = e.code
            except Exception as e: code = str(e)[:60]
            res[name] = code
            if code == 429: break
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
        if not s['preview']:
            st['pending'] = list(dict.fromkeys(st.get('pending', []) + [sm[p][1] for p in new]))
        inow = st.get('indexnow')
        if '--indexnow' in sys.argv and st['pending'] and not s['preview']:
            inow = {'date': TODAY, 'count': len(st['pending']), **indexnow(s, st, st['pending'])}
            if any(v in (200, 202) for k, v in inow.items() if k in ('naver', 'indexnow')): st['pending'] = []
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
