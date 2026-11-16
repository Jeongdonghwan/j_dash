#!/usr/bin/env bash
# SEO 대시보드 설치 (nginx 정적 사이트 서버). 다시 돌리면 프로그램만 새로 깔린다.
set -euo pipefail
mkdir -p /opt/seo-dash /var/lib/seo-dash/out
chmod 700 /var/lib/seo-dash

cat > /opt/seo-dash/dash.py <<'DASH_PY_EOF'
#!/usr/bin/env python3
"""SEO 대시보드 수집기 — 정적 사이트 서버(nginx)에서 하루 두 번 돈다. 표준 라이브러리만.

  python3 dash.py [--indexnow]

읽는 것: nginx sites-enabled(사이트 이름·root) / 각 root 의 sitemap(공개 주소, .ops.json 있으면 남은 일정)
        / nginx 접속 기록. vhost.log(맨 앞에 $host)가 있으면 그것을, 그 전 날짜는 access.log 를 경로로 사이트를
        역추적해 대략 복원한다(메인·robots 는 못 가린다 — 화면에서 '추정'으로 표시).
쓰는 것: $DASH_OUT/data.json(전체 현황) · site-<호스트>.json(사이트 상세) — dash_app.py 가 로그인한 사람에게만 내준다.
        $DASH_STATE/state.json (날짜별 집계·수집된 경로·IndexNow 대기열·도메인 등록일)
--indexnow: 새로 열린 주소를 네이버·IndexNow 로 보낸다(미리보기 사이트 제외). 거절한 창구에만 다음 실행 때 다시.

방문 = 같은 IP·브라우저가 30분 넘게 쉬지 않고 이어 본 묶음. 전화 클릭 = 사이트의 tel: 링크를 누를 때 보내는 /_t?e=tel 요청.
"""
import datetime as dt, glob, gzip, html, http.client, json, os, re, secrets, socket, sys, urllib.error, urllib.parse, urllib.request
from collections import Counter, defaultdict

for _s in (sys.stdout, sys.stderr):
    try: _s.reconfigure(encoding='utf-8')
    except Exception: pass
E = os.environ.get
NGINX, LOGS = E('DASH_NGINX', '/etc/nginx/sites-enabled'), E('DASH_LOGS', '/var/log/nginx')
STATE = E('DASH_STATE', '/var/lib/seo-dash')
OUT = E('DASH_OUT', STATE + '/out')
NOW = dt.datetime.now(dt.timezone(dt.timedelta(hours=9)))  # KST
TODAY = NOW.date().isoformat()
BOTS = [('naver', 'Yeti'), ('google', 'Googlebot'), ('bing', 'bingbot'), ('daum', 'Daum'), ('ai', 'GPTBot'), ('ai', 'OAI-SearchBot'),
        ('ai', 'ChatGPT-User'), ('ai', 'ClaudeBot'), ('ai', 'Claude-SearchBot'), ('ai', 'Claude-User'), ('ai', 'PerplexityBot')]
OTHER_BOT = re.compile(r'bot|crawl|spider|slurp|scan|checker|monitor|python|curl|wget|go-http|java/|okhttp|headless|lighthouse|'
                       r'facebookexternalhit|kakaotalk-scrap|whatsapp|axios|scrapy|ahrefs|semrush|bytespider|yandex|baidu|feedfetcher', re.I)
LINE = re.compile(r'(\S+) \S+ \S+ \[(\d\d)/(\w{3})/(\d{4}):(\d\d):(\d\d):\d\d[^\]]*\] "(\S+) (\S+)[^"]*" (\d{3}) \S+ "([^"]*)" "([^"]*)"')
MON = {m: f'{i:02d}' for i, m in enumerate('Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec'.split(), 1)}
SEARCH = ('naver', 'google', 'daum', 'bing')


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
    only = set(E('DASH_ONLY', '').split())   # 다른 서버에 수집기만 깔 때: 이 호스트의 사이트만
    for s in out.values():
        if not s['hosts'] or (only and not only & set(s['hosts'])): continue
        h = s['hosts'][0]
        try: s['name'] = h.encode('ascii').decode('idna')
        except Exception: s['name'] = h
        s['preview'] = 'sslip.io' in h
        s['id'] = re.sub(r'[^a-z0-9.-]', '', h.lower())
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


def ptype(path, part=''):
    """페이지 유형 — 검색에 어떤 종류의 페이지가 걸리는지 보려고 나눈다."""
    if path == '/': return 'home'
    if re.match(r'/blog/.+', path): return 'post'
    if part.startswith('sitemap-kw'): return 'kw'
    if part == 'sitemap-core.xml': return 'hub'
    return 'kw' if path.count('/') == 2 and '-' in path else 'hub'   # 묶음을 안 나눈 사이트: 한 단 주소에 '-' 가 있으면 키워드 페이지


def is_page(path):
    return not path.startswith('/_next') and ('.' not in path.rsplit('/', 1)[-1] or path.endswith('.html'))


def is_human(ua):
    return ua.startswith('Mozilla/') and len(ua) > 40 and not OTHER_BOT.search(ua)


def device(ua):
    d = '모바일' if re.search(r'Mobile|Android|iPhone|iPad', ua) else 'PC'
    app = '네이버 앱' if 'NAVER(' in ua else '카카오톡' if 'KAKAOTALK' in ua else '인스타그램' if 'Instagram' in ua else '페이스북' if 'FBAN' in ua or 'FBAV' in ua else ''
    return d + (' · ' + app if app else '')


def source(ref, own):
    """리퍼러 → (출처 코드, 표시할 호스트, 검색어). 검색어는 리퍼러에 남아 있을 때만(대부분 안 남는다)."""
    if not ref or ref == '-': return 'direct', '', ''
    u = urllib.parse.urlparse(ref); h = u.netloc.lower().split(':')[0]
    if not h or h in own: return 'direct', '', ''
    q = urllib.parse.parse_qs(u.query)
    kw = lambda k: (q.get(k) or [''])[0].strip()[:60]
    if h.endswith('search.naver.com'): return 'naver', h, kw('query')
    if h.endswith('naver.com') or h.endswith('naver.me'):
        return ('naver_blog' if 'blog.' in h else 'naver_cafe' if 'cafe.' in h else 'naver_place' if 'place.' in h or 'map.' in h else 'naver_etc'), h, ''
    if re.search(r'(^|\.)google\.', h): return 'google', h, kw('q')
    if h.endswith('daum.net'): return 'daum', h, kw('q')
    if h.endswith('bing.com'): return 'bing', h, kw('q')
    if 'kakao' in h: return 'kakao', h, ''
    if re.search(r'instagram|facebook|youtube|youtu\.be|threads|tiktok|t\.co$|x\.com$', h): return 'sns', h, ''
    return 'site', h, ''


def mask(ip):
    return ip.rsplit('.', 1)[0] + '.*' if '.' in ip else ':'.join(ip.split(':')[:3]) + ':*'


def parse_logs(sites):
    """사이트별 집계. 반환: {root: {...}}, vhost 기록이 시작된 날"""
    by_host = {h: s['root'] for s in sites for h in s['hosts']}
    own = {s['root']: set(s['hosts']) for s in sites}
    seg = {}  # 첫 경로 조각 → root (한 사이트에만 있는 것만) — host 없는 옛 기록용
    for s in sites:
        for base, pre in ((s['root'], ''), (s['root'] + '/blog', 'blog/')):
            for n in (os.listdir(base) if os.path.isdir(base) else []):
                k = pre + n
                seg[k] = None if k in seg and seg[k] != s['root'] else s['root']
    A = defaultdict(lambda: {'days': defaultdict(Counter), 'crawled': defaultdict(set), 'uv': defaultdict(set), 'open': {}, 'sess': [],
                             'top': Counter(), 'e404': Counter(), 'hours': Counter()})
    mt = lambda fs: sorted(fs, key=os.path.getmtime)   # 오래된 파일부터 — 방문 묶음은 시간 순서로 봐야 한다
    vfiles, afiles = mt(glob.glob(LOGS + '/vhost.log*')), mt(glob.glob(LOGS + '/access.log*'))
    vdates, ordc = set(), {}
    for f in vfiles:   # vhost 기록이 있는 날은 그쪽만 쓴다 → 날짜부터 모은다
        with (gzip.open if f.endswith('.gz') else open)(f, 'rt', encoding='utf-8', errors='ignore') as fh:
            for line in fh:
                m = re.search(r'\[(\d\d)/(\w{3})/(\d{4})', line)
                if m: vdates.add(f'{m.group(3)}-{MON.get(m.group(2), "00")}-{m.group(1)}')

    def feed(files, has_host):
        for f in files:
            with (gzip.open if f.endswith('.gz') else open)(f, 'rt', encoding='utf-8', errors='ignore') as fh:
                for line in fh:
                    host = None
                    if has_host: host, _, line = line.partition(' ')
                    m = LINE.match(line)
                    if not m: continue
                    ip, dd, mon, yy, hh, mi, method, req, status, ref, ua = m.groups()
                    d = f'{yy}-{MON.get(mon, "00")}-{dd}'
                    if not has_host and d in vdates: continue
                    path = norm(req)
                    if has_host: root = by_host.get(host)
                    else:
                        parts = path.strip('/').split('/')
                        root = seg.get('blog/' + parts[1] if parts[0] == 'blog' and len(parts) > 1 else parts[0])
                        if not root: root = by_host.get(urllib.parse.urlparse(ref).netloc)
                    if not root: continue
                    a = A[root]; c = a['days'][d]
                    bot = next((b for b, k in BOTS if k in ua), None)
                    human = not bot and is_human(ua)
                    if d not in ordc: ordc[d] = dt.date.fromisoformat(d).toordinal() * 1440
                    tmin = ordc[d] + int(hh) * 60 + int(mi)
                    key = (ip, ua)
                    if path.startswith('/_t'):   # 전화·카톡 클릭 신호 (정적 서버라 404 로 남는다 — 기록만 쓰면 된다)
                        ev = (urllib.parse.parse_qs(req.partition('?')[2]).get('e') or [''])[0]
                        if human and ev in ('tel', 'kakao', 'sms'):
                            c[ev] += 1
                            s = a['open'].get(key)
                            if s and tmin - s['_t'] <= 30: s[ev] = 1
                        continue
                    if '_rsc=' in req:
                        if bot: c['rsc_' + bot] += 1
                        continue
                    if method != 'GET' or not is_page(path): continue
                    if status == '404':
                        c['404'] += 1; a['e404'][path[:120]] += 1
                    if status not in ('200', '304'): continue
                    if bot:
                        c['bot_' + bot] += 1; a['crawled'][bot].add(path)
                    elif not human: c['bot_other'] += 1
                    else:
                        c['views'] += 1; a['uv'][d].add(key); a['top'][path] += 1; a['hours'][int(hh)] += 1
                        s = a['open'].get(key)
                        if not s or tmin - s['_t'] > 30:
                            src, rh, kw = source(ref, own[root])
                            s = {'t': f'{d} {hh}:{mi}', 'd': d, 'ip': mask(ip), 'src': src, 'ref': rh, 'kw': kw, 'land': path, 'pages': [], 'n': 0, 'dev': device(ua)}
                            a['open'][key] = s; a['sess'].append(s)
                            c['visits'] += 1; c['src_' + src] += 1
                        s['_t'] = tmin; s['n'] += 1
                        if len(s['pages']) < 12: s['pages'].append(path)
    feed(afiles, False); feed(vfiles, True)
    for a in A.values():
        for d, u in a['uv'].items(): a['days'][d]['visitors'] = len(u)
    return A, min(vdates) if vdates else None


def window(sess, sm, days):
    """최근 N일 방문 묶음 요약 — 어디서, 어떤 페이지로, 어떤 검색어로."""
    since = (NOW.date() - dt.timedelta(days=days - 1)).isoformat()
    src, land, kw, ref, dev, typ = Counter(), defaultdict(lambda: [0, 0]), Counter(), Counter(), Counter(), defaultdict(lambda: [0, 0])
    for s in sess:
        if s['d'] < since: continue
        is_search = s['src'] in SEARCH
        src[s['src']] += 1; dev[s['dev']] += 1
        land[s['land']][0] += 1; land[s['land']][1] += is_search
        t = ptype(s['land'], sm.get(s['land'], ('', '', ''))[2])
        typ[t][0] += 1; typ[t][1] += is_search
        if s['kw']: kw[(s['src'], s['kw'])] += 1
        if s['src'] in ('site', 'sns', 'kakao', 'naver_blog', 'naver_cafe', 'naver_place', 'naver_etc'): ref[s['ref']] += 1
    return {'src': dict(src), 'dev': dict(dev), 'type': typ,
            'land': [[p, v[0], v[1], ptype(p, sm.get(p, ('', '', ''))[2])] for p, v in sorted(land.items(), key=lambda x: -x[1][0])[:25]],
            'kw': [[k[1], k[0], n] for k, n in kw.most_common(25)], 'ref': ref.most_common(15)}


def whois_created(host):
    """도메인 등록일 (없으면 '') — .kr 은 KISA, 나머지는 베리사인. 사이트당 한 번만 묻고 상태에 적어 둔다."""
    labels = host.lower().split('.')
    dom = '.'.join(labels[-3:] if len(labels) > 2 and labels[-2] in ('co', 'or', 'ne', 'pe', 're', 'go') else labels[-2:])
    server = 'whois.kisa.or.kr' if dom.endswith('.kr') else 'whois.verisign-grs.com' if dom.endswith(('.com', '.net')) else None
    if not server: return ''
    try:
        with socket.create_connection((server, 43), timeout=10) as c:
            c.sendall((dom + '\r\n').encode()); buf = b''
            while True:
                b = c.recv(4096)
                if not b: break
                buf += b
        t = buf.decode('utf-8', 'ignore')
        m = re.search(r'(?:등록일|Registered Date|Creation Date)\s*:\s*(\d{4})\D{1,3}(\d{1,2})\D{1,3}(\d{1,2})', t)
        return f'{m.group(1)}-{int(m.group(2)):02d}-{int(m.group(3)):02d}' if m else ''
    except Exception:
        return ''


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
    except Exception:
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
    A, vstart = parse_logs(sites)
    data = {'updated': NOW.strftime('%Y-%m-%d %H:%M'), 'today': TODAY, 'exact_from': vstart, 'sites': []}
    for s in sites:
        st = state.setdefault(s['root'], {'paths': {}, 'crawled': {}, 'days': {}, 'pending': []})
        a = A[s['root']]
        sm = read_sitemap(s['root'])
        first = not st['paths']
        new = [p for p in sm if p not in st['paths']]
        for p in new: st['paths'][p] = '' if first else TODAY   # 첫 실행은 기준선(오늘 열림으로 세지 않는다)
        for p in [p for p in st['paths'] if p not in sm]: del st['paths'][p]
        blog = [p for p in sm if re.match(r'/blog/.+', p)]
        for d, c in a['days'].items(): st['days'].setdefault(d, {}).update(c)
        st['days'].setdefault(TODAY, {}).update({
            'pages': len(sm) - len(blog), 'posts': len(blog),
            'new_pages': sum(1 for p in sm if st['paths'][p] == TODAY and p not in blog),
            'new_posts': sum(1 for p in blog if st['paths'][p] == TODAY)})
        for b, ps in a['crawled'].items(): st['crawled'][b] = sorted(set(st['crawled'].get(b, [])) | ps)
        got = {b: set(st['crawled'].get(b, [])) & set(sm) for b in ('naver', 'google')}
        parts, types = defaultdict(lambda: [0, 0, 0]), Counter()
        for p, (_, _, name) in sm.items():
            parts[name][0] += 1; parts[name][1] += p in got['naver']; parts[name][2] += p in got['google']
            types[ptype(p, name)] += 1
        inow = st.get('indexnow')
        if not s['preview']:
            if 'pending_etc' not in st:  # 옛 상태: 공용 창구가 거절했으면 전체를 다시 보낸다
                st['pending_etc'] = [] if (inow or {}).get('indexnow') in (200, 202) else [v[1] for v in sm.values()]
            for q in ('pending', 'pending_etc'):
                st[q] = list(dict.fromkeys(st.get(q, []) + [sm[p][1] for p in new]))
            if 'created' not in st or (not st['created'] and st.get('created_try') != TODAY[:7]):   # 실패하면 달에 한 번만 다시
                st['created'], st['created_try'] = whois_created(s['hosts'][0]), TODAY[:7]
        if '--indexnow' in sys.argv and not s['preview'] and (st['pending'] or st.get('pending_etc')):
            n = max(len(st['pending']), len(st['pending_etc']))
            inow = {**(inow or {}), 'date': TODAY, 'count': n, **indexnow(s, st)}
            st['indexnow'] = inow
        ops = {}
        try: ops = json.load(open(os.path.join(s['root'], '.ops.json'), encoding='utf-8'))
        except Exception: pass
        sched = [x for x in ops.get('schedule', []) if x.get('date', '') > TODAY]
        left_pages, left_posts = sum(x.get('pages', 0) for x in sched), sum(x.get('posts', 0) for x in sched)
        dl = sorted(st['days'])[-45:]
        days = [dict(st['days'][d], d=d, est=0 if vstart and d >= vstart else 1) for d in dl]
        base = {'id': s['id'], 'name': s['name'], 'host': s['hosts'][0], 'preview': s['preview'], 'created': st.get('created', ''),
                'pages': len(sm) - len(blog), 'posts': len(blog), 'total': len(sm),
                'left_pages': left_pages, 'left_posts': left_posts,   # 전체 제작 = 공개(total) + 남은 것 — 같은 기준으로 센다
                'crawl': {b: len(got[b]) for b in got}, 'health': health(s, sm), 'days': days}
        data['sites'].append(base)
        sess = sorted(a['sess'], key=lambda x: x['t'], reverse=True)
        detail = dict(base, updated=data['updated'], today=TODAY, exact_from=vstart, types=dict(types), schedule=sched,
                      parts=[[n] + v for n, v in sorted(parts.items())], indexnow=inow,
                      pending=max(len(st['pending']), len(st.get('pending_etc', []))),
                      w7=window(sess, sm, 7), w14=window(sess, sm, 14),
                      top=[[p, n, ptype(p, sm.get(p, ('', '', ''))[2])] for p, n in a['top'].most_common(25)],
                      e404=a['e404'].most_common(15), hours=[a['hours'].get(h, 0) for h in range(24)],
                      visits=[{k: v for k, v in x.items() if k not in ('_t', 'd')} for x in sess[:400]])
        json.dump(detail, open(os.path.join(OUT, f'site-{s["id"]}.json'), 'w', encoding='utf-8'), ensure_ascii=False)
    rf = os.path.join(STATE, 'remotes.txt')   # 다른 서버 수집기의 결과 주소(한 줄에 하나) — 그쪽 사이트를 이 화면에 합친다
    for base in ([l.strip().rstrip('/') for l in open(rf, encoding='utf-8') if l.strip() and not l.startswith('#')] if os.path.exists(rf) else []):
        try:
            get = lambda n: urllib.request.urlopen(f'{base}/{n}', timeout=30).read()
            for x in json.loads(get('data.json'))['sites']:
                if not re.fullmatch(r'[a-z0-9.-]{1,120}', x.get('id', '')): continue
                open(os.path.join(OUT, f'site-{x["id"]}.json'), 'wb').write(get(f'site-{x["id"]}.json'))
                data['sites'] = [y for y in data['sites'] if y['id'] != x['id']] + [x]
        except Exception as e:
            print(f'  다른 서버 자료를 못 받음: {urllib.parse.urlparse(base).netloc} {str(e)[:80]}')
    data['sites'].sort(key=lambda x: (x['preview'], -x['total']))
    json.dump(state, open(sp, 'w', encoding='utf-8'), ensure_ascii=False)
    json.dump(data, open(os.path.join(OUT, 'data.json'), 'w', encoding='utf-8'), ensure_ascii=False)
    print(f'{data["updated"]} 사이트 {len(sites)}개, 공개 주소 {sum(x["total"] for x in data["sites"])}개')
    for x in data['sites']:
        y = next((d for d in x['days'] if d['d'] == (NOW.date() - dt.timedelta(days=1)).isoformat()), {})
        i = next((state[s['root']].get('indexnow') for s in sites if s['id'] == x['id']), None)
        print(f'  {x["name"]}: 공개 {x["total"]} · 어제 방문자 {y.get("visitors", 0)} · 네이버 수집 {y.get("bot_naver", 0)} · 구글 수집 {y.get("bot_google", 0)}'
              + (f' · IndexNow {i}' if i and i.get('date') == TODAY else '') + (f' · 점검 {x["health"]}' if x['health'] else ''))


if __name__ == '__main__':
    main()
DASH_PY_EOF

cat > /opt/seo-dash/dash_app.py <<'DASH_APP_EOF'
#!/usr/bin/env python3
"""SEO 대시보드 화면 서버 — 로그인한 사람에게만 화면과 자료를 내준다. 표준 라이브러리만, nginx 뒤(127.0.0.1)에서 돈다.

  python3 dash_app.py                 서버 실행 (DASH_PORT 기본 8791)
  python3 dash_app.py --set-password  표준 입력의 첫 줄을 admin 비밀번호로 저장

자료: $DASH_OUT/data.json · site-<id>.json (dash.py 가 만든다). 계정: $DASH_STATE/auth.json (비밀번호는 PBKDF2 해시만 저장).
"""
import hashlib, hmac, http.server, json, os, re, secrets, sys, time, urllib.parse

E = os.environ.get
STATE = E('DASH_STATE', '/var/lib/seo-dash')
OUT = E('DASH_OUT', STATE + '/out')
HERE = os.path.dirname(os.path.abspath(__file__))
AUTH = os.path.join(STATE, 'auth.json')
DAYS30 = 30 * 86400
FAILS = {}  # ip → [실패 시각] — 10분에 8번 틀리면 잠깐 막는다


def pw_hash(pw, salt):
    return hashlib.pbkdf2_hmac('sha256', pw.encode(), bytes.fromhex(salt), 200_000).hex()


def load_auth():
    return json.load(open(AUTH, encoding='utf-8'))


def save_password(pw):
    a = load_auth() if os.path.exists(AUTH) else {'user': 'admin', 'secret': secrets.token_hex(32)}
    a['salt'] = secrets.token_hex(16); a['hash'] = pw_hash(pw, a['salt'])
    os.makedirs(STATE, exist_ok=True)
    fd = os.open(AUTH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as f: json.dump(a, f)


def sign(a, exp):
    # 비밀번호 해시를 섞어 둔다 → 비밀번호를 바꾸면 예전 로그인은 모두 풀린다
    return hmac.new(bytes.fromhex(a['secret']), f'{a["user"]}.{exp}.{a["hash"]}'.encode(), 'sha256').hexdigest()


def valid(a, token):
    exp, _, sig = (token or '').partition('.')
    return exp.isdigit() and int(exp) > time.time() and hmac.compare_digest(sig, sign(a, exp))


def page(name):
    return open(os.path.join(HERE, name), 'rb').read()


class H(http.server.BaseHTTPRequestHandler):
    server_version = 'dash'

    def log_message(self, *a): pass

    def send(self, code, body=b'', ctype='text/html; charset=utf-8', extra=()):
        if isinstance(body, str): body = body.encode()
        self.send_response(code)
        for k, v in (('Content-Type', ctype), ('Content-Length', str(len(body))), ('Cache-Control', 'no-store'),
                     ('X-Robots-Tag', 'noindex, nofollow'), ('X-Frame-Options', 'DENY'), ('X-Content-Type-Options', 'nosniff'),
                     ('Referrer-Policy', 'same-origin'),
                     ('Content-Security-Policy', "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'"), *extra):
            self.send_header(k, v)
        self.end_headers(); self.wfile.write(body)

    def cookie(self, value, age):
        secure = '; Secure' if self.headers.get('X-Forwarded-Proto') == 'https' else ''
        return ('Set-Cookie', f'sd={value}; Path=/; Max-Age={age}; HttpOnly; SameSite=Lax{secure}')

    def authed(self):
        m = re.search(r'(?:^|;\s*)sd=([^;]+)', self.headers.get('Cookie', ''))
        return bool(m) and valid(load_auth(), m.group(1))

    def same_origin(self):   # 다른 사이트가 대신 보내는 요청 막기 (쿠키 SameSite=Lax 에 더해)
        o = self.headers.get('Origin') or self.headers.get('Referer') or ''
        return urllib.parse.urlparse(o).netloc == self.headers.get('Host', '')

    def body(self):
        n = min(int(self.headers.get('Content-Length') or 0), 10_000)
        return self.rfile.read(n).decode('utf-8', 'ignore')

    def do_GET(self):
        p = urllib.parse.urlparse(self.path).path
        if p == '/login': return self.send(200, page('login.html'))
        if not self.authed():
            return self.send(401, '{"error":"login"}', 'application/json') if p.startswith('/api/') else self.send(302, extra=[('Location', '/login')])
        if p == '/': return self.send(200, page('app.html'))
        m = re.fullmatch(r'/api/(data|site/([a-z0-9.-]{1,120}))', p)
        if m:
            f = os.path.join(OUT, 'data.json' if m.group(1) == 'data' else f'site-{m.group(2)}.json')
            if os.path.isfile(f): return self.send(200, open(f, 'rb').read(), 'application/json; charset=utf-8')
        self.send(404, 'not found', 'text/plain')

    def do_POST(self):
        p = urllib.parse.urlparse(self.path).path
        ip = self.headers.get('X-Real-IP') or self.client_address[0]
        a = load_auth()
        if p == '/login':
            now = time.time(); FAILS[ip] = [t for t in FAILS.get(ip, []) if now - t < 600]
            if len(FAILS[ip]) >= 8: return self.send(302, extra=[('Location', '/login?e=wait')])
            f = urllib.parse.parse_qs(self.body())
            ok = hmac.compare_digest((f.get('user') or [''])[0], a['user']) and hmac.compare_digest(pw_hash((f.get('pw') or [''])[0], a['salt']), a['hash'])
            if not ok:
                FAILS[ip].append(now); time.sleep(1)
                return self.send(302, extra=[('Location', '/login?e=1')])
            exp = int(now) + DAYS30
            return self.send(302, extra=[('Location', '/'), self.cookie(f'{exp}.{sign(a, exp)}', DAYS30)])
        if not self.authed() or not self.same_origin(): return self.send(403, '{"error":"forbidden"}', 'application/json')
        if p == '/logout': return self.send(302, extra=[('Location', '/login'), self.cookie('', 0)])
        if p == '/api/password':
            try: d = json.loads(self.body())
            except Exception: d = {}
            old, new = str(d.get('old', '')), str(d.get('new', ''))
            if not hmac.compare_digest(pw_hash(old, a['salt']), a['hash']): return self.send(400, '{"error":"지금 비밀번호가 맞지 않습니다"}', 'application/json')
            if len(new) < 8: return self.send(400, '{"error":"새 비밀번호는 8자 이상이어야 합니다"}', 'application/json')
            save_password(new); a = load_auth(); exp = int(time.time()) + DAYS30
            return self.send(200, '{"ok":true}', 'application/json', [self.cookie(f'{exp}.{sign(a, exp)}', DAYS30)])
        self.send(404, 'not found', 'text/plain')


def demo():
    import tempfile
    global AUTH, STATE
    with tempfile.TemporaryDirectory() as d:
        STATE, AUTH = d, os.path.join(d, 'auth.json')
        save_password('first-pass'); a = load_auth()
        exp = int(time.time()) + 60; tok = f'{exp}.{sign(a, exp)}'
        assert valid(a, tok) and not valid(a, tok[:-1] + ('0' if tok[-1] != '0' else '1')) and not valid(a, f'1.{sign(a, 1)}')   # 변조·만료 거절
        assert 'first-pass' not in open(AUTH).read()                                                                              # 평문 저장 안 함
        save_password('second-pass'); assert not valid(load_auth(), tok)                                                          # 비밀번호 바꾸면 예전 로그인 풀림
    print('demo ok')


if __name__ == '__main__':
    if '--demo' in sys.argv: demo()
    elif '--set-password' in sys.argv:
        pw = sys.stdin.readline().strip()
        if len(pw) < 8: sys.exit('비밀번호는 8자 이상')
        save_password(pw); print('saved')
    else:
        http.server.ThreadingHTTPServer(('127.0.0.1', int(E('DASH_PORT', '8791'))), H).serve_forever()
DASH_APP_EOF

cat > /opt/seo-dash/app.html <<'DASH_HTML_EOF'
<!doctype html>
<html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow">
<title>사이트 운영 현황</title>
<style>
:root{color-scheme:light;--side:#14181d;--side-ink:#c9d0d8;--bg:#f3f4f6;--card:#fff;--ink:#16191d;--mute:#5f6772;--line:#dfe3e8;--soft:#eef0f3;
--naver:#0a8f4d;--google:#2b62d9;--search:#c2540a;--visit:#6b4fbb;--bar:#55657a;--bad:#b3261e;--est:#e9ebef}
*{box-sizing:border-box}html,body{margin:0}body{background:var(--bg);color:var(--ink);font:14px/1.5 Pretendard,system-ui,'Malgun Gothic',sans-serif}
a{color:inherit}button,select,input{font:inherit;color:inherit}
.shell{display:grid;grid-template-columns:232px minmax(0,1fr);min-height:100vh}
aside{background:var(--side);color:var(--side-ink);padding:20px 0;position:sticky;top:0;height:100vh;overflow-y:auto}
aside .brand{padding:0 20px 16px;color:#fff;font-weight:800;font-size:16px;letter-spacing:-.01em;border-bottom:1px solid #262c34}
aside .grp{padding:16px 20px 6px;font-size:11px;color:#7d8794;letter-spacing:.06em}
aside a{display:flex;justify-content:space-between;gap:8px;padding:7px 20px;text-decoration:none;border-left:3px solid transparent;font-size:13px}
aside a:hover{background:#1c2229;color:#fff}aside a.on{background:#1c2229;color:#fff;border-left-color:#fff}
aside a .n{color:#7d8794;font-variant-numeric:tabular-nums}aside a.pre{color:#7d8794}
aside form{padding:6px 20px}aside form button{background:none;border:0;padding:0;color:#7d8794;cursor:pointer;font-size:13px;text-decoration:underline;text-underline-offset:3px}
.mnav{display:none}
main{padding:28px 32px 80px;min-width:0}
h1{font-size:22px;margin:0;letter-spacing:-.02em}h2{font-size:14px;margin:0 0 10px}
.head{display:flex;justify-content:space-between;align-items:flex-end;gap:16px;flex-wrap:wrap;margin-bottom:18px}
.mute{color:var(--mute)}.small{font-size:12px}.num{font-variant-numeric:tabular-nums}
.note{border-left:3px solid var(--line);padding:2px 0 2px 10px;margin:0 0 16px}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(168px,1fr));background:var(--card);border:1px solid var(--line);border-right:0;border-bottom:0;margin-bottom:20px}
.tile{padding:14px 16px;border-right:1px solid var(--line);border-bottom:1px solid var(--line)}.tile .lab{font-size:12px;color:var(--mute)}.tile b{display:block;font-size:24px;line-height:1.25;font-variant-numeric:tabular-nums;letter-spacing:-.02em}
.tile small{color:var(--mute);font-size:12px}.up{color:var(--naver)}.down{color:var(--bad)}
[data-h]{cursor:help;border-bottom:1px dotted #a5adb8}
.grid2{display:grid;grid-template-columns:repeat(auto-fit,minmax(420px,1fr));gap:20px;margin-bottom:20px}
.card{background:var(--card);border:1px solid var(--line);padding:16px;min-width:0}.card.full{margin-bottom:20px}
.chead{display:flex;justify-content:space-between;align-items:baseline;gap:12px;flex-wrap:wrap;margin-bottom:8px}.chead h2{margin:0}
.legend{display:flex;gap:14px;flex-wrap:wrap;font-size:12px;color:var(--mute)}.legend i{display:inline-block;width:10px;height:10px;margin-right:5px;vertical-align:-1px}
.seg{display:inline-flex;border:1px solid var(--line)}.seg button{background:var(--card);border:0;border-right:1px solid var(--line);padding:5px 12px;cursor:pointer;font-size:12px}
.seg button:last-child{border-right:0}.seg button.on{background:var(--ink);color:#fff}
.tabs{display:flex;gap:0;border-bottom:1px solid var(--line);margin:0 0 20px}.tabs a{padding:9px 16px;text-decoration:none;color:var(--mute);border-bottom:2px solid transparent;margin-bottom:-1px}
.tabs a.on{color:var(--ink);border-bottom-color:var(--ink);font-weight:600}
.scroll{overflow-x:auto}table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}
th,td{padding:8px 10px;border-bottom:1px solid var(--line);text-align:right;white-space:nowrap}th{font-size:12px;font-weight:600;color:var(--mute);background:var(--soft)}
th:first-child,td:first-child,th.l,td.l{text-align:left}td.wrap{white-space:normal;word-break:break-all;max-width:420px}
tr.row{cursor:pointer}tr.row:hover td{background:#f7f8fa}tr.pre td:first-child{color:var(--mute)}
.zero{color:#a5adb8}.warn{color:var(--bad);font-weight:600}
.hb{display:grid;grid-template-columns:minmax(110px,180px) 1fr 86px;gap:10px;align-items:center;padding:5px 0;font-size:13px}
.hb .t{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.hb .b{height:10px;background:var(--soft)}.hb .b i{display:block;height:100%;background:var(--bar);border-radius:0 2px 2px 0}
.hb .v{text-align:right;font-variant-numeric:tabular-nums}
.chart{position:relative}.chart svg{display:block;width:100%}
#tip{position:fixed;z-index:9;pointer-events:none;background:#16191d;color:#fff;padding:8px 10px;font-size:12px;line-height:1.5;max-width:300px;display:none}
#tip i{display:inline-block;width:8px;height:8px;margin-right:6px}#tip b{font-variant-numeric:tabular-nums}
.filters{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:12px}.filters select,.filters input,.form input{border:1px solid var(--line);background:var(--card);padding:7px 10px;border-radius:0}
.trail{background:var(--soft);white-space:normal;text-align:left;line-height:1.9}.trail span{color:var(--mute)}
.tag{display:inline-block;font-size:11px;padding:0 5px;border:1px solid var(--line);color:var(--mute);margin-left:6px}
.form{max-width:360px;display:grid;gap:10px}.form label{display:grid;gap:4px;font-size:12px;color:var(--mute)}
.btn{background:var(--ink);color:#fff;border:0;padding:10px 16px;cursor:pointer;font-weight:600}
dl.gloss{margin:0;display:grid;grid-template-columns:200px 1fr;border-top:1px solid var(--line)}dl.gloss dt,dl.gloss dd{margin:0;padding:10px 12px;border-bottom:1px solid var(--line)}dl.gloss dt{font-weight:600;background:var(--soft)}
details summary{cursor:pointer;color:var(--mute);font-size:12px;margin-top:10px}
@media(max-width:860px){.shell{grid-template-columns:minmax(0,1fr)}aside{display:none}.mnav{display:flex;gap:8px;background:var(--side);padding:10px 16px;position:sticky;top:0;z-index:5}
.mnav select{flex:1;background:#1c2229;color:#fff;border:1px solid #2f3741;padding:8px}main{padding:20px 16px 60px}.grid2{grid-template-columns:1fr}dl.gloss{grid-template-columns:1fr}dl.gloss dt{border-bottom:0}}
</style></head><body>
<div class="shell"><aside id="side"></aside><div><div class="mnav"><select id="msel" aria-label="화면 이동"></select></div><main id="main"><p class="mute">불러오는 중</p></main></div></div>
<div id="tip" role="tooltip"></div>
<script>
const HELP={
visitors:['방문자','그날 사이트에 들어온 사람 수입니다. 같은 IP와 같은 브라우저는 하루에 한 명으로 셉니다. 검색 로봇과 자동 프로그램은 빼고 셉니다.'],
visits:['방문','한 사람이 들어와서 30분 넘게 쉬지 않고 이어 본 한 묶음입니다. 같은 사람이 오전과 오후에 따로 들어오면 2번으로 셉니다.'],
views:['조회','사람이 페이지를 연 횟수입니다. 한 번 방문에 3쪽을 보면 3입니다.'],
search:['검색 유입','네이버·구글·다음·빙 검색 결과를 눌러 들어온 방문 수입니다. 네이버 앱은 경로를 안 남기는 경우가 있어 실제보다 적게 잡힙니다.'],
tel:['전화 클릭','사이트의 전화 버튼을 누른 횟수입니다. 실제 통화 연결 여부까지는 알 수 없습니다. 전화 버튼에 집계 코드를 넣은 사이트만 셉니다.'],
total:['공개 주소','지금 검색 로봇에게 열려 있는 주소 수입니다. 사이트맵에 올라 있는 페이지와 블로그 글을 모두 셉니다.'],
made:['전체 제작','만들어 둔 주소 전체입니다. 공개 주소에 아직 열리지 않은 페이지와 예약된 글을 더한 수입니다.'],
left:['남은 수','만들어 뒀지만 아직 열리지 않은 페이지와 글입니다. 일정에 따라 자동으로 열립니다.'],
new_pages:['오늘 열림','오늘 새로 공개된 페이지 수입니다. 대시보드 설치일(2026-11-16)은 기준일이라 0이고 그다음 날부터 셉니다.'],
new_posts:['오늘 발행','오늘 새로 공개된 블로그 글 수입니다. 설치일은 기준일이라 0입니다.'],
bot_naver:['네이버 수집','네이버 검색 로봇(Yeti)이 페이지를 정상으로 가져간 횟수입니다. 가져가야 색인이 됩니다.'],
bot_google:['구글 수집','구글 검색 로봇(Googlebot)이 페이지를 정상으로 가져간 횟수입니다.'],
cov_naver:['네이버 수집률','네이버 로봇이 한 번이라도 가져간 주소 ÷ 공개 주소입니다. 100%에 가까울수록 사이트 전체를 로봇이 본 것입니다.'],
cov_google:['구글 수집률','구글 로봇이 한 번이라도 가져간 주소 ÷ 공개 주소입니다.'],
rsc:['수집 낭비','네이버 로봇이 페이지 대신 화면 전환용 보조 파일(_rsc)을 가져간 횟수입니다. 하루 수집 한도를 깎아 먹습니다.'],
e404:['없는 주소 요청','없는 주소를 요청해 404가 나간 횟수입니다. 삭제한 주소나 잘못 걸린 링크가 있으면 늘어납니다.'],
src:['유입 경로','방문이 시작될 때 어디서 왔는지입니다. 주소를 직접 치거나 앱에서 열어 경로가 안 남으면 "직접·알 수 없음"으로 셉니다.'],
ptype:['페이지 유형','메인 / 허브·서비스(지역 목록, 소개, 서비스 안내) / 지역·키워드(대량 제작 페이지) / 콘텐츠(블로그 글)로 나눕니다.'],
kw:['검색어','검색 결과에서 넘어올 때 검색어가 함께 넘어온 경우만 보입니다. 네이버와 구글은 대부분 검색어를 넘겨주지 않아 일부만 잡힙니다.'],
land:['들어온 페이지','방문이 시작된 첫 페이지입니다. 검색에 걸려 있는 페이지가 무엇인지 알 수 있습니다.'],
created:['도메인 등록일','도메인을 처음 등록한 날짜입니다. 등록 정보에서 조회합니다.'],
est:['추정 값','사이트별 기록을 남기기 전(2026-11-16 13시 이전) 날짜는 주소로 사이트를 역추적한 값입니다. 메인 페이지 요청이 빠져 있어 실제보다 적습니다.'],
indexnow:['IndexNow','새로 열린 주소를 네이버와 빙에 바로 알리는 기능입니다. 매일 자동으로 보냅니다.'],
health:['점검','표본 30쪽을 열어 파일이 있는지, 대표 주소(canonical)가 있는지, 색인 차단(noindex)이 걸려 있지 않은지 봅니다.']};
const SRC={naver:'네이버 검색',google:'구글 검색',daum:'다음 검색',bing:'빙 검색',naver_blog:'네이버 블로그',naver_place:'네이버 플레이스·지도',naver_cafe:'네이버 카페',naver_etc:'네이버 기타',kakao:'카카오',sns:'SNS',site:'다른 사이트',direct:'직접·알 수 없음'};
const TYPE={home:'메인',hub:'허브·서비스',kw:'지역·키워드',post:'콘텐츠(글)'};
const C={naver:'var(--naver)',google:'var(--google)',search:'var(--search)',visit:'var(--visit)'};
const $=s=>document.querySelector(s),main=$('#main'),tip=$('#tip');
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const f=n=>n?Number(n).toLocaleString('ko-KR'):'<span class="zero">0</span>';
const pct=(a,b)=>b?(Math.round(a/b*1000)/10)+'%':'-';
const h=(k,t)=>`<span data-h="${k}">${esc(t||HELP[k][0])}</span>`;
let D=null,range=30,win=7;const cache={};
const day=n=>{const d=new Date(D.today+'T00:00:00Z');d.setUTCDate(d.getUTCDate()-n);return d.toISOString().slice(0,10)};
const searchOf=x=>(x.src_naver||0)+(x.src_google||0)+(x.src_daum||0)+(x.src_bing||0);
const val=(x,k)=>typeof k==='function'?k(x):(x[k]||0);
const sum=(days,k,from,to)=>days.reduce((a,x)=>a+(x.d>=from&&(!to||x.d<=to)?val(x,k):0),0);
function delta(cur,prev){if(!prev)return'<small>비교할 이전 값 없음</small>';const p=Math.round((cur-prev)/prev*100);return `<small class="${p>0?'up':p<0?'down':''}">${p>0?'▲':p<0?'▼':''} ${Math.abs(p)}% <span class="mute">이전 ${f(prev)}</span></small>`}
const tile=(k,v,sub,label)=>`<div class="tile"><span class="lab">${h(k,label)}</span><b>${v}</b>${sub||''}</div>`;
function series(days,n){const m=Object.fromEntries(days.map(x=>[x.d,x]));const out=[];for(let i=n-1;i>=0;i--){const d=day(i);out.push(m[d]||{d,est:D.exact_from&&d>=D.exact_from?0:1})}return out}
function merge(sites){const m={};sites.forEach(s=>s.days.forEach(x=>{const o=m[x.d]||(m[x.d]={d:x.d,est:x.est});for(const k in x)if(typeof x[k]==='number'&&k!=='est')o[k]=(o[k]||0)+x[k];o.est=o.est&&x.est}));return Object.values(m)}

/* 그래프: 선(추이) — 가로축 날짜, 세로축 하나, 마우스를 올리면 날짜와 값 */
function lineChart(el,days,ser){
  const W=Math.max(320,el.clientWidth),H=220,L=44,R=14,T=10,B=26,n=days.length;
  const max=Math.max(4,...days.flatMap(x=>ser.map(s=>val(x,s.k)))),step=Math.pow(10,Math.floor(Math.log10(max))),top=Math.ceil(max/step)*step;
  const X=i=>L+(n>1?i*(W-L-R)/(n-1):0),Y=v=>T+(H-T-B)*(1-v/top);
  let g='';for(let i=0;i<=4;i++){const v=top*i/4,y=Y(v);g+=`<line x1="${L}" x2="${W-R}" y1="${y}" y2="${y}" stroke="#e6e9ed"/><text x="${L-8}" y="${y+4}" text-anchor="end" font-size="11" fill="#5f6772">${Math.round(v).toLocaleString('ko-KR')}</text>`}
  const estN=days.filter(x=>x.est).length;if(estN)g=`<rect x="${L}" y="${T}" width="${Math.max(0,X(Math.min(estN,n-1))-L)}" height="${H-T-B}" fill="var(--est)"/>`+g;
  const every=Math.ceil(n/7);days.forEach((x,i)=>{if(i%every===0||i===n-1)g+=`<text x="${X(i)}" y="${H-8}" text-anchor="${i===n-1?'end':'middle'}" font-size="11" fill="#5f6772">${x.d.slice(5)}</text>`});
  ser.forEach(s=>{g+=`<polyline fill="none" stroke="${s.c}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" points="${days.map((x,i)=>X(i)+','+Y(val(x,s.k))).join(' ')}"/><circle cx="${X(n-1)}" cy="${Y(val(days[n-1],s.k))}" r="3.5" fill="${s.c}" stroke="#fff" stroke-width="2"/>`});
  el.innerHTML=`<svg viewBox="0 0 ${W} ${H}" height="${H}" role="img" aria-label="${esc(ser.map(s=>s.t).join(', '))} 날짜별 추이">${g}<line id="x" y1="${T}" y2="${H-B}" stroke="#16191d" stroke-width="1" visibility="hidden"/><rect x="${L}" y="${T}" width="${W-L-R}" height="${H-T-B}" fill="transparent"/></svg>`;
  const svg=el.firstChild,cross=svg.querySelector('#x');
  svg.onmousemove=e=>{const r=svg.getBoundingClientRect(),px=(e.clientX-r.left)*W/r.width,i=Math.max(0,Math.min(n-1,Math.round((px-L)/((W-L-R)/Math.max(1,n-1))))),x=days[i];
    cross.setAttribute('x1',X(i));cross.setAttribute('x2',X(i));cross.setAttribute('visibility','visible');
    showTip(e,`<div>${x.d}${x.est?' · 추정':''}</div>`+ser.map(s=>`<div><i style="background:${s.c}"></i>${esc(s.t)} <b>${val(x,s.k).toLocaleString('ko-KR')}</b></div>`).join(''))};
  svg.onmouseleave=()=>{cross.setAttribute('visibility','hidden');tip.style.display='none'}}
/* 그래프: 막대(시간대) */
function barChart(el,vals,label){
  const W=Math.max(320,el.clientWidth),H=170,L=36,R=8,T=8,B=24,n=vals.length,max=Math.max(4,...vals),bw=(W-L-R)/n;
  let g=`<line x1="${L}" x2="${W-R}" y1="${H-B}" y2="${H-B}" stroke="#cfd5dc"/><text x="${L-8}" y="${T+8}" text-anchor="end" font-size="11" fill="#5f6772">${max.toLocaleString('ko-KR')}</text>`;
  vals.forEach((v,i)=>{const bh=(H-T-B)*v/max;g+=`<rect data-i="${i}" x="${L+i*bw+1}" y="${H-B-bh}" width="${Math.max(2,bw-2)}" height="${bh}" rx="2" fill="var(--bar)"/><rect data-i="${i}" x="${L+i*bw}" y="${T}" width="${bw}" height="${H-T-B}" fill="transparent"/>`;
    if(i%3===0)g+=`<text x="${L+i*bw+bw/2}" y="${H-7}" text-anchor="middle" font-size="11" fill="#5f6772">${i}시</text>`});
  el.innerHTML=`<svg viewBox="0 0 ${W} ${H}" height="${H}" role="img" aria-label="${esc(label)}">${g}</svg>`;
  el.firstChild.onmousemove=e=>{const i=e.target.dataset.i;if(i==null){tip.style.display='none';return}showTip(e,`<div>${i}시 ~ ${+i+1}시</div><div>${esc(label)} <b>${vals[i].toLocaleString('ko-KR')}</b></div>`)};
  el.firstChild.onmouseleave=()=>tip.style.display='none'}
function showTip(e,html){tip.innerHTML=html;tip.style.display='block';const w=tip.offsetWidth,x=e.clientX+14+w>innerWidth?e.clientX-w-14:e.clientX+14;tip.style.left=x+'px';tip.style.top=Math.min(innerHeight-tip.offsetHeight-8,e.clientY+14)+'px'}
const legend=ser=>`<div class="legend">${ser.map(s=>`<span><i style="background:${s.c}"></i>${esc(s.t)}</span>`).join('')}</div>`;
function hbars(items,unit){const max=Math.max(1,...items.map(x=>x[1]));return items.length?items.map(x=>`<div class="hb"><span class="t" title="${esc(x[0])}">${esc(x[0])}</span><span class="b"><i style="width:${x[1]/max*100}%"></i></span><span class="v">${f(x[1])}${x[2]!=null?` <span class="mute small">${esc(x[2])}</span>`:''}</span></div>`).join(''):`<p class="mute small">${unit||'자료 없음'}</p>`}
const seg=(name,opts,cur)=>`<span class="seg" data-seg="${name}">${opts.map(o=>`<button type="button" data-v="${o[0]}" class="${o[0]==cur?'on':''}">${o[1]}</button>`).join('')}</span>`;
const charts=[];function draw(){charts.forEach(c=>c())}
function dayTable(days,cols){return `<details><summary>날짜별 표로 보기</summary><div class="scroll"><table><tr><th>날짜</th>${cols.map(c=>`<th>${esc(c[0])}</th>`).join('')}</tr>${days.slice().reverse().map(x=>`<tr><td>${x.d}${x.est?' <span class="tag">추정</span>':''}</td>${cols.map(c=>`<td>${f(val(x,c[1]))}</td>`).join('')}</tr>`).join('')}</table></div></details>`}
const estNote=()=>`<p class="note small mute">${D.exact_from?`${D.exact_from}부터는 사이트별로 정확히 셉니다. 그래프의 회색 구간은 그 전 날짜를 `:'아직 사이트별 기록이 없어 모든 날짜가 '}${h('est','추정한 값')}입니다.</p>`;
const VS=[{k:'visitors',t:'방문자',c:C.visit},{k:searchOf,t:'검색 유입',c:C.search}],BS=[{k:'bot_naver',t:'네이버 수집',c:C.naver},{k:'bot_google',t:'구글 수집',c:C.google}];
const made=s=>s.total+s.left_pages+s.left_posts;

function overview(){
  const live=D.sites.filter(s=>!s.preview),all=merge(live),y=day(1),w=day(7),t=D.today;
  const tot=fn=>live.reduce((a,s)=>a+fn(s),0),dsum=(k,a,b)=>sum(all,k,a,b);
  const bad=live.filter(s=>Object.keys(s.health||{}).length);
  main.innerHTML=`<div class="head"><div><h1>전체 현황</h1><div class="mute small">운영 사이트 ${live.length}곳 · 미리보기 ${D.sites.length-live.length}곳 · 갱신 ${esc(D.updated)}</div></div>${seg('range',[[14,'14일'],[30,'30일'],[45,'45일']],range)}</div>
  ${estNote()}
  <div class="tiles">${tile('visitors',f(dsum('visitors',y,y)),delta(dsum('visitors',y,y),dsum('visitors',day(2),day(2))),'어제 방문자')}
  ${tile('search',f(dsum(searchOf,w,y)),delta(dsum(searchOf,w,y),dsum(searchOf,day(14),day(8))),'검색 유입 7일')}
  ${tile('tel',f(dsum('tel',w)),'<small>최근 7일</small>','전화 클릭 7일')}
  ${tile('total',f(tot(s=>s.total)),`<small>전체 제작 ${f(tot(made))}</small>`)}
  ${tile('new_pages',f(dsum('new_pages',t,t)),`<small>발행 글 ${f(dsum('new_posts',t,t))}</small>`)}
  ${tile('bot_naver',f(dsum('bot_naver',y,y)),'<small>어제</small>','어제 네이버 수집')}
  ${tile('bot_google',f(dsum('bot_google',y,y)),'<small>어제</small>','어제 구글 수집')}
  ${tile('health',bad.length?`<span class="warn">${bad.length}곳</span>`:'이상 없음',bad.length?`<small>${esc(bad.map(s=>s.name).join(', '))}</small>`:'<small>전체 정상</small>','점검')}</div>
  <div class="grid2"><div class="card"><div class="chead"><h2>방문자와 검색 유입 (운영 사이트 합계)</h2>${legend(VS)}</div><div class="chart" id="c1"></div>${dayTable(series(all,range),[['방문자','visitors'],['방문','visits'],['검색 유입',searchOf],['전화 클릭','tel']])}</div>
  <div class="card"><div class="chead"><h2>검색 로봇 수집 (운영 사이트 합계)</h2>${legend(BS)}</div><div class="chart" id="c2"></div>${dayTable(series(all,range),[['네이버','bot_naver'],['구글','bot_google'],['수집 낭비','rsc_naver']])}</div></div>
  <div class="card full"><h2>사이트별</h2><div class="scroll"><table><tr><th>사이트</th><th>${h('visitors','방문자 어제')}</th><th>${h('search','검색 유입 7일')}</th><th>${h('tel','전화 7일')}</th><th>${h('total')}</th><th>${h('made')}</th><th>${h('new_pages')}</th><th>${h('new_posts')}</th><th>${h('bot_naver','네이버 수집 7일')}</th><th>${h('bot_google','구글 수집 7일')}</th><th>${h('cov_naver')}</th><th>${h('cov_google')}</th><th>${h('health')}</th></tr>
  ${D.sites.map(s=>{const b=Object.keys(s.health||{}).length,d=s.days;return `<tr class="row${s.preview?' pre':''}" data-go="#/s/${esc(s.id)}"><td>${esc(s.name)}${s.preview?'<span class="tag">미리보기</span>':''}</td><td>${f(sum(d,'visitors',y,y))}</td><td>${f(sum(d,searchOf,w,y))}</td><td>${f(sum(d,'tel',w))}</td><td>${f(s.total)}</td><td>${f(made(s))}</td><td>${f(sum(d,'new_pages',t,t))}</td><td>${f(sum(d,'new_posts',t,t))}</td><td>${f(sum(d,'bot_naver',w,y))}</td><td>${f(sum(d,'bot_google',w,y))}</td><td>${pct(s.crawl.naver,s.total)}</td><td>${pct(s.crawl.google,s.total)}</td><td>${b?`<span class="warn">확인 필요 ${b}</span>`:'정상'}</td></tr>`}).join('')}</table></div>
  <p class="mute small">줄을 누르면 그 사이트의 상세 화면으로 갑니다. 점선 밑줄이 있는 이름에 마우스를 올리면 뜻이 나옵니다.</p></div>`;
  charts.length=0;charts.push(()=>lineChart($('#c1'),series(all,range),VS),()=>lineChart($('#c2'),series(all,range),BS));draw()}

async function site(id,tab){
  const s=cache[id]||(cache[id]=await api('site/'+id));if(!s)return;
  const d=s.days,y=day(1),w=day(7),t=D.today,W=win==7?s.w7:s.w14,bad=Object.entries(s.health||{});
  const age=s.created?Math.floor((new Date(t)-new Date(s.created))/864e5):null;
  const tabs=[['','개요'],['visits','방문 기록'],['crawl','수집·색인'],['publish','공개·발행']];
  let body='';charts.length=0;
  if(!tab){
    const types=Object.entries(W.type).sort((a,b)=>b[1][0]-a[1][0]).map(([k,v])=>[TYPE[k]||k,v[0],`검색 ${v[1]}`]);
    body=`<div class="tiles">${tile('visitors',f(sum(d,'visitors',w,y)),delta(sum(d,'visitors',w,y),sum(d,'visitors',day(14),day(8))),'방문자 7일')}
    ${tile('search',f(sum(d,searchOf,w,y)),delta(sum(d,searchOf,w,y),sum(d,searchOf,day(14),day(8))),'검색 유입 7일')}
    ${tile('tel',f(sum(d,'tel',w)),`<small>카톡 ${f(sum(d,'kakao',w))}</small>`,'전화 클릭 7일')}
    ${tile('total',f(s.total),`<small>전체 제작 ${f(made(s))}</small>`)}
    ${tile('cov_naver',pct(s.crawl.naver,s.total),`<small>${f(s.crawl.naver)} / ${f(s.total)}</small>`)}
    ${tile('cov_google',pct(s.crawl.google,s.total),`<small>${f(s.crawl.google)} / ${f(s.total)}</small>`)}</div>
    <div class="card full"><div class="chead"><h2>방문자와 검색 유입</h2><span>${legend(VS)}</span>${seg('range',[[14,'14일'],[30,'30일'],[45,'45일']],range)}</div><div class="chart" id="c1"></div>${dayTable(series(d,range),[['방문자','visitors'],['방문','visits'],['조회','views'],['검색 유입',searchOf],['전화 클릭','tel']])}</div>
    <div class="head" style="margin:0 0 10px"><h2 style="margin:0">어디서 어떻게 들어왔는지</h2>${seg('win',[[7,'최근 7일'],[14,'최근 14일']],win)}</div>
    <div class="grid2"><div class="card"><h2>${h('src')}</h2>${hbars(Object.entries(W.src).sort((a,b)=>b[1]-a[1]).map(([k,v])=>[SRC[k]||k,v]),'이 기간에 방문이 없습니다')}</div>
    <div class="card"><h2>들어온 ${h('ptype')}</h2>${hbars(types,'이 기간에 방문이 없습니다')}<p class="mute small">공개된 주소: ${Object.entries(s.types).map(([k,v])=>`${TYPE[k]||k} ${v.toLocaleString('ko-KR')}`).join(' · ')}</p></div></div>
    <div class="grid2"><div class="card"><h2>${h('land')} 상위</h2><div class="scroll"><table><tr><th>페이지</th><th>유형</th><th>방문</th><th>그중 검색</th></tr>${W.land.map(p=>`<tr><td class="wrap"><a href="https://${esc(s.host)}${esc(encodeURI(p[0]))}" target="_blank" rel="noopener noreferrer">${esc(p[0])}</a></td><td>${TYPE[p[3]]||''}</td><td>${f(p[1])}</td><td>${f(p[2])}</td></tr>`).join('')||'<tr><td class="mute" colspan="4">이 기간에 방문이 없습니다</td></tr>'}</table></div></div>
    <div class="card"><h2>${h('kw')}</h2><div class="scroll"><table><tr><th>검색어</th><th>검색</th><th>방문</th></tr>${W.kw.map(k=>`<tr><td class="wrap">${esc(k[0])}</td><td>${esc((SRC[k[1]]||k[1]).replace(' 검색',''))}</td><td>${f(k[2])}</td></tr>`).join('')||'<tr><td class="mute" colspan="3">검색어가 넘어온 방문이 없습니다</td></tr>'}</table></div>
    <h2 style="margin-top:18px">링크를 걸어 준 곳</h2>${hbars(W.ref,'다른 사이트에서 넘어온 방문이 없습니다')}</div></div>
    <div class="grid2"><div class="card"><h2>시간대별 조회 (최근 14일)</h2><div class="chart" id="c2"></div></div>
    <div class="card"><h2>기기</h2>${hbars(Object.entries(W.dev).sort((a,b)=>b[1]-a[1]),'이 기간에 방문이 없습니다')}</div></div>
    <div class="card full"><h2>많이 본 페이지 (최근 14일)</h2><div class="scroll"><table><tr><th>페이지</th><th>유형</th><th>${h('views')}</th></tr>${s.top.map(p=>`<tr><td class="wrap"><a href="https://${esc(s.host)}${esc(encodeURI(p[0]))}" target="_blank" rel="noopener noreferrer">${esc(p[0])}</a></td><td>${TYPE[p[2]]||''}</td><td>${f(p[1])}</td></tr>`).join('')||'<tr><td class="mute" colspan="3">자료 없음</td></tr>'}</table></div></div>`;
    charts.push(()=>lineChart($('#c1'),series(d,range),VS),()=>barChart($('#c2'),s.hours,'조회'));
  }else if(tab==='visits'){
    const srcs=[...new Set(s.visits.map(v=>v.src))];
    body=`<p class="note small mute">최근 방문 ${s.visits.length}건입니다(최대 400건). ${h('visits','방문')} 한 건은 한 사람이 이어서 본 묶음이고, 줄을 누르면 본 순서가 펼쳐집니다. IP는 끝자리를 가렸습니다.</p>
    <div class="filters"><select id="fsrc" aria-label="유입 경로"><option value="">유입 경로 전체</option>${srcs.map(k=>`<option value="${esc(k)}">${esc(SRC[k]||k)}</option>`).join('')}</select>
    <select id="ftel" aria-label="전화 클릭"><option value="">전체</option><option value="1">전화·카톡 누른 방문만</option></select><input id="fq" type="search" placeholder="페이지·검색어 찾기" aria-label="찾기"></div>
    <div class="card" style="padding:0"><div class="scroll"><table id="vt"></table></div></div>`;
  }else if(tab==='crawl'){
    const i=s.indexnow;
    body=`<div class="tiles">${tile('bot_naver',f(sum(d,'bot_naver',y,y)),`<small>7일 ${f(sum(d,'bot_naver',w,y))}</small>`,'어제 네이버 수집')}${tile('bot_google',f(sum(d,'bot_google',y,y)),`<small>7일 ${f(sum(d,'bot_google',w,y))}</small>`,'어제 구글 수집')}
    ${tile('cov_naver',pct(s.crawl.naver,s.total),`<small>${f(s.crawl.naver)} / ${f(s.total)}</small>`)}${tile('cov_google',pct(s.crawl.google,s.total),`<small>${f(s.crawl.google)} / ${f(s.total)}</small>`)}
    ${tile('rsc',f(sum(d,'rsc_naver',w,y)),'<small>최근 7일</small>','수집 낭비 7일')}${tile('e404',f(sum(d,'404',w,y)),'<small>최근 7일</small>','없는 주소 요청 7일')}</div>
    <div class="card full"><div class="chead"><h2>검색 로봇 수집</h2><span>${legend(BS)}</span>${seg('range',[[14,'14일'],[30,'30일'],[45,'45일']],range)}</div><div class="chart" id="c1"></div>${dayTable(series(d,range),[['네이버','bot_naver'],['구글','bot_google'],['빙','bot_bing'],['다음','bot_daum'],['AI 로봇','bot_ai'],['수집 낭비','rsc_naver'],['404','404']])}</div>
    <div class="grid2"><div class="card"><h2>사이트맵 묶음별 수집률</h2><div class="scroll"><table><tr><th>묶음</th><th>주소</th><th>네이버</th><th>구글</th></tr>${s.parts.map(p=>`<tr><td>${esc(p[0])}</td><td>${f(p[1])}</td><td>${f(p[2])} (${pct(p[2],p[1])})</td><td>${f(p[3])} (${pct(p[3],p[1])})</td></tr>`).join('')}</table></div>
    <p class="mute small">core는 메인과 허브, blog는 글, kw는 지역·키워드 페이지 1,000개씩입니다.</p></div>
    <div class="card"><h2>${h('indexnow')}</h2><p>${i?`마지막 전송 ${esc(i.date)} · ${f(i.count)}개<br>네이버 응답 ${esc(i.naver??'-')} · 빙 쪽 응답 ${esc(i.indexnow??'-')} <span class="mute small">(200·202면 접수)</span>`:'전송 기록이 없습니다'}<br>보낼 차례를 기다리는 주소 ${f(s.pending)}개</p>
    <h2 style="margin-top:18px">${h('health')}</h2><p>${bad.length?bad.map(([k,v])=>`<span class="warn">${esc(k)} ${v}건</span>`).join(' · '):'이상 없음'}</p>
    <h2 style="margin-top:18px">${h('e404')} 상위 (최근 14일)</h2>${hbars(s.e404,'없는 주소 요청이 없습니다')}</div></div>`;
    charts.push(()=>lineChart($('#c1'),series(d,range),BS));
  }else{
    const dd=series(d,range).reverse();
    body=`<div class="tiles">${tile('made',f(made(s)))}${tile('total',f(s.total),`<small>페이지 ${f(s.pages)} · 글 ${f(s.posts)}</small>`)}${tile('left',f(s.left_pages+s.left_posts),`<small>페이지 ${f(s.left_pages)} · 글 ${f(s.left_posts)}</small>`)}
    ${tile('new_pages',f(sum(d,'new_pages',t,t)),`<small>7일 ${f(sum(d,'new_pages',w))}</small>`)}${tile('new_posts',f(sum(d,'new_posts',t,t)),`<small>7일 ${f(sum(d,'new_posts',w))}</small>`)}</div>
    <div class="grid2"><div class="card"><div class="chead"><h2>날짜별 공개 기록</h2>${seg('range',[[14,'14일'],[30,'30일'],[45,'45일']],range)}</div><div class="scroll"><table><tr><th>날짜</th><th>열린 페이지</th><th>발행 글</th><th>공개 페이지 누계</th><th>공개 글 누계</th></tr>${dd.map(x=>`<tr><td>${x.d}</td><td>${f(x.new_pages)}</td><td>${f(x.new_posts)}</td><td>${x.pages!=null?f(x.pages):'<span class="zero">-</span>'}</td><td>${x.posts!=null?f(x.posts):'<span class="zero">-</span>'}</td></tr>`).join('')}</table></div>
    <p class="mute small">누계는 대시보드를 설치한 날부터 기록됩니다.</p></div>
    <div class="card"><h2>남은 일정</h2><div class="scroll"><table><tr><th>날짜</th><th>열릴 페이지</th><th>발행될 글</th></tr>${(s.schedule||[]).map(x=>`<tr><td>${esc(x.date)}</td><td>${f(x.pages)}</td><td>${f(x.posts)}</td></tr>`).join('')||'<tr><td class="mute" colspan="3">예약된 일정이 없습니다</td></tr>'}</table></div></div></div>`;
  }
  main.innerHTML=`<div class="head"><div><h1>${esc(s.name)}${s.preview?'<span class="tag">미리보기</span>':''}</h1><div class="mute small"><a href="https://${esc(s.host)}/" target="_blank" rel="noopener noreferrer">${esc(s.host)}</a>
  · ${h('created')} ${s.created?esc(s.created)+` (${age.toLocaleString('ko-KR')}일째)`:'확인 안 됨'} · 갱신 ${esc(s.updated)}</div></div></div>
  <nav class="tabs">${tabs.map(x=>`<a href="#/s/${esc(id)}${x[0]?'/'+x[0]:''}" class="${(tab||'')===x[0]?'on':''}">${x[1]}</a>`).join('')}</nav>${tab==='visits'?'':estNote()}${body}`;
  if(tab==='visits'){const paint=()=>{const fs=$('#fsrc').value,ft=$('#ftel').value,q=$('#fq').value.trim();
      const rows=s.visits.filter(v=>(!fs||v.src===fs)&&(!ft||v.tel||v.kakao)&&(!q||(v.land+' '+v.kw+' '+v.pages.join(' ')+' '+v.ref).includes(q)));
      $('#vt').innerHTML=`<tr><th>시각</th><th class="l">어디서</th><th class="l">처음 본 페이지</th><th>본 쪽수</th><th class="l">기기</th><th class="l">전화·카톡</th><th class="l">IP</th></tr>`+(rows.map((v,i)=>`<tr class="row" data-v="${i}"><td>${esc(v.t)}</td><td class="l">${esc(SRC[v.src]||v.src)}${v.kw?` <span class="mute">“${esc(v.kw)}”</span>`:v.ref&&!['naver','google','daum','bing'].includes(v.src)?` <span class="mute">${esc(v.ref)}</span>`:''}</td><td class="l wrap">${esc(v.land)}</td><td>${v.n}</td><td class="l">${esc(v.dev)}</td><td class="l">${v.tel?'전화':''}${v.tel&&v.kakao?' · ':''}${v.kakao?'카톡':''}</td><td class="l mute">${esc(v.ip)}</td></tr>`).join('')||'<tr><td class="mute l" colspan="7">조건에 맞는 방문이 없습니다</td></tr>');
      $('#vt').onclick=e=>{const tr=e.target.closest('tr.row');if(!tr)return;const nx=tr.nextElementSibling;if(nx&&nx.classList.contains('tr2')){nx.remove();return}
        const v=rows[tr.dataset.v],r=document.createElement('tr');r.className='tr2';r.innerHTML=`<td colspan="7" class="trail"><span>본 순서</span> ${v.pages.map(p=>esc(p)).join(' <span>→</span> ')}${v.n>v.pages.length?` <span>외 ${v.n-v.pages.length}쪽</span>`:''}</td>`;tr.after(r)}};
    ['fsrc','ftel','fq'].forEach(i=>$('#'+i).oninput=paint);paint()}
  draw()}

function help(){const groups=[['방문',['visitors','visits','views','search','src','land','kw','ptype','tel']],['공개·발행',['total','made','left','new_pages','new_posts']],['수집·색인',['bot_naver','bot_google','cov_naver','cov_google','rsc','e404','indexnow','health']],['기타',['est','created']]];
  main.innerHTML=`<div class="head"><h1>용어 설명</h1></div>`+groups.map(g=>`<div class="card full"><h2>${g[0]}</h2><dl class="gloss">${g[1].map(k=>`<dt>${esc(HELP[k][0])}</dt><dd>${esc(HELP[k][1])}</dd>`).join('')}</dl></div>`).join('')
  +`<div class="card full"><h2>자료가 어디서 오는지</h2><p>모든 숫자는 서버의 접속 기록과 각 사이트의 사이트맵에서 계산합니다. 하루 두 번(7시 30분, 15시 30분) 갱신합니다. 검색 순위, 검색량, 백링크는 서버 기록으로 알 수 없어 넣지 않았습니다. 구글 순위와 클릭 수는 서치콘솔을 연결하면 추가할 수 있습니다.</p></div>`}
function account(){main.innerHTML=`<div class="head"><h1>비밀번호 변경</h1></div><div class="card"><form class="form" id="pf"><label>지금 비밀번호<input type="password" name="old" required autocomplete="current-password"></label><label>새 비밀번호 (8자 이상)<input type="password" name="new" required minlength="8" autocomplete="new-password"></label><button class="btn">바꾸기</button><p id="pm" class="small" role="status"></p></form></div>`;
  $('#pf').onsubmit=async e=>{e.preventDefault();const fd=new FormData(e.target),r=await fetch('/api/password',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({old:fd.get('old'),new:fd.get('new')})}),j=await r.json().catch(()=>({}));
    $('#pm').textContent=r.ok?'바꿨습니다. 다른 기기의 로그인은 모두 풀립니다.':(j.error||'바꾸지 못했습니다');if(r.ok)e.target.reset()}}

async function api(p){const r=await fetch('/api/'+p,{cache:'no-store'});if(r.status===401){location.href='/login';return null}if(!r.ok){main.innerHTML=`<p class="warn">자료를 불러오지 못했습니다 (${r.status}). 수집이 아직 한 번도 돌지 않았을 수 있습니다.</p>`;return null}return r.json()}
function nav(){const cur=location.hash||'#/',live=D.sites.filter(s=>!s.preview),pre=D.sites.filter(s=>s.preview),y=day(1);
  const item=s=>`<a href="#/s/${esc(s.id)}" class="${cur.startsWith('#/s/'+s.id)?'on':''}${s.preview?' pre':''}"><span>${esc(s.name.replace('.172.237.20.244.sslip.io',''))}</span><span class="n" title="어제 방문자">${sum(s.days,'visitors',y,y).toLocaleString('ko-KR')}</span></a>`;
  $('#side').innerHTML=`<div class="brand">사이트 운영 현황</div><div class="grp">전체</div><a href="#/" class="${cur==='#/'?'on':''}">전체 현황</a><div class="grp">운영 사이트 · 어제 방문자</div>${live.map(item).join('')}${pre.length?`<div class="grp">미리보기</div>${pre.map(item).join('')}`:''}
  <div class="grp">도움</div><a href="#/help" class="${cur==='#/help'?'on':''}">용어 설명</a><a href="#/account" class="${cur==='#/account'?'on':''}">비밀번호 변경</a><form method="post" action="/logout"><button>로그아웃</button></form>`;
  $('#msel').innerHTML=`<option value="#/">전체 현황</option>${D.sites.map(s=>`<option value="#/s/${esc(s.id)}" ${cur.startsWith('#/s/'+s.id)?'selected':''}>${esc(s.name)}</option>`).join('')}<option value="#/help" ${cur==='#/help'?'selected':''}>용어 설명</option><option value="#/account" ${cur==='#/account'?'selected':''}>비밀번호 변경</option>`}
async function route(){if(!D){D=await api('data');if(!D)return}const p=(location.hash||'#/').slice(2).split('/');nav();tip.style.display='none';
  if(p[0]==='s'&&D.sites.some(s=>s.id===p[1]))await site(p[1],p[2]||'');else if(p[0]==='help')help();else if(p[0]==='account')account();else overview();scrollTo(0,0)}
addEventListener('hashchange',route);$('#msel').onchange=e=>location.hash=e.target.value;
let rt;addEventListener('resize',()=>{clearTimeout(rt);rt=setTimeout(draw,150)});
document.addEventListener('click',e=>{const b=e.target.closest('[data-seg] button');if(b){const n=b.parentNode.dataset.seg;if(n==='range')range=+b.dataset.v;else win=+b.dataset.v;const y=scrollY;route().then(()=>scrollTo(0,y));return}
  const tr=e.target.closest('tr[data-go]');if(tr)location.hash=tr.dataset.go});
document.addEventListener('mouseover',e=>{const t=e.target.closest('[data-h]');if(t&&HELP[t.dataset.h])showTip(e,`<b>${esc(HELP[t.dataset.h][0])}</b><div>${esc(HELP[t.dataset.h][1])}</div>`)});
document.addEventListener('mouseout',e=>{if(e.target.closest('[data-h]'))tip.style.display='none'});
route();
</script></body></html>
DASH_HTML_EOF

cat > /opt/seo-dash/login.html <<'DASH_LOGIN_EOF'
<!doctype html>
<html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow">
<title>로그인 · 사이트 운영 현황</title>
<style>
*{box-sizing:border-box}html,body{margin:0;height:100%}
body{display:grid;grid-template-columns:minmax(0,1.1fr) minmax(360px,.9fr);font:15px/1.5 Pretendard,system-ui,'Malgun Gothic',sans-serif;color:#16191d;color-scheme:light}
.left{background:#14181d;color:#c9d0d8;padding:56px;display:flex;flex-direction:column;justify-content:space-between}
.left h1{color:#fff;font-size:34px;line-height:1.25;letter-spacing:-.03em;margin:0 0 20px;max-width:12em}
.left dl{margin:0;border-top:1px solid #2a313a;max-width:440px}.left dt{float:left;width:112px;color:#fff;font-weight:600;padding:12px 0}.left dd{margin:0;padding:12px 0 12px 112px;border-bottom:1px solid #2a313a}
.left small{color:#7d8794}
.right{background:#fff;display:flex;align-items:center;justify-content:center;padding:32px}
form{width:100%;max-width:340px;display:grid;gap:14px}h2{font-size:20px;margin:0 0 6px;letter-spacing:-.02em}
label{display:grid;gap:5px;font-size:13px;color:#5f6772}
input{font:inherit;padding:11px 12px;border:1px solid #cfd5dc;border-radius:0;color:#16191d}input:focus{outline:2px solid #16191d;outline-offset:-1px}
button{font:inherit;font-weight:700;background:#16191d;color:#fff;border:0;padding:13px;cursor:pointer}button:hover{background:#2b3138}
.err{color:#b3261e;font-size:13px;margin:0;min-height:1.5em}
@media(max-width:760px){body{grid-template-columns:1fr}.left{padding:28px 24px}.left h1{font-size:24px}.left dl{display:none}}
</style></head><body>
<section class="left"><div><h1>사이트 운영 현황</h1>
<dl><dt>방문</dt><dd>사이트별 방문자와 어디서 어떻게 들어왔는지</dd><dt>검색 로봇</dt><dd>네이버와 구글이 하루에 몇 쪽을 가져갔는지</dd><dt>공개·발행</dt><dd>오늘 열린 페이지와 발행된 글, 남은 일정</dd><dt>전화 클릭</dt><dd>전화 버튼을 누른 횟수</dd></dl></div>
<small>하루 두 번 갱신 · 7시 30분, 15시 30분</small></section>
<section class="right"><form method="post" action="/login"><h2>로그인</h2>
<label>아이디<input name="user" autocomplete="username" required autofocus></label>
<label>비밀번호<input name="pw" type="password" autocomplete="current-password" required></label>
<p class="err" id="e" role="alert"></p><button>들어가기</button></form></section>
<script>var q=new URLSearchParams(location.search).get('e');if(q)document.getElementById('e').textContent=q==='wait'?'여러 번 틀려 잠시 막았습니다. 10분 뒤에 다시 해 주세요.':'아이디 또는 비밀번호가 맞지 않습니다.';</script>
</body></html>
DASH_LOGIN_EOF

# 1) 접속 기록에 사이트 이름을 남기는 파일 추가 (기존 access.log 는 그대로)
if grep -q "conf.d/\*.conf" /etc/nginx/nginx.conf; then
cat > /etc/nginx/conf.d/vhostlog.conf <<'EOF'
log_format vhost '$host $remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent"';
access_log /var/log/nginx/vhost.log vhost;
EOF
else echo "!! nginx.conf 가 conf.d 를 읽지 않음 — 사이트별 기록 추가를 건너뜀"; fi

# 2) 로그인 계정 (처음 한 번 — 예전 비밀번호가 있으면 그대로 쓴다)
if [ ! -f /var/lib/seo-dash/auth.json ]; then
  [ -f /root/seo-dash-password.txt ] || { openssl rand -hex 6 > /root/seo-dash-password.txt; chmod 600 /root/seo-dash-password.txt; }
  python3 /opt/seo-dash/dash_app.py --set-password < /root/seo-dash-password.txt
fi

# 3) 화면 서버 (127.0.0.1:8791, nginx 가 앞에서 받는다)
cat > /etc/systemd/system/seo-dash.service <<'EOF'
[Unit]
Description=SEO dashboard (127.0.0.1:8791)
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/seo-dash/dash_app.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable -q seo-dash
systemctl restart seo-dash

# 4) 대시보드 주소 — 예전(파일을 그대로 보여 주던) 설정이면 화면 서버로 넘기도록 바꾼다
NG=/etc/nginx/sites-available/seo-dash
PROXY='    location / { proxy_pass http://127.0.0.1:8791; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; proxy_set_header X-Forwarded-Proto $scheme; }'
if [ ! -f "$NG" ]; then
  printf 'server {\n    listen 80;\n    server_name ops.172.237.20.244.sslip.io;\n%s\n}\n' "$PROXY" > "$NG"
elif ! grep -q proxy_pass "$NG"; then
  cp "$NG" /root/seo-dash.nginx.bak
  python3 - "$NG" "$PROXY" <<'EOF'
import re, sys
p, proxy = sys.argv[1], sys.argv[2]
t = open(p).read()
t = re.sub(r'^[ \t]*root /var/www/seo-dash;[ \t]*$', lambda m: proxy, t, count=1, flags=re.M)
t = re.sub(r'^[ \t]*(index index\.html;|auth_basic[^\n]*)[ \t]*\n', '', t, flags=re.M)
open(p, 'w').write(t)
EOF
fi
ln -sf "$NG" /etc/nginx/sites-enabled/seo-dash
if nginx -t; then systemctl reload nginx
else
  [ -f /root/seo-dash.nginx.bak ] && cp /root/seo-dash.nginx.bak "$NG" || rm -f /etc/nginx/sites-enabled/seo-dash
  rm -f /etc/nginx/conf.d/vhostlog.conf; echo "!! nginx 설정 오류 — 추가한 설정을 되돌림"; exit 1
fi
grep -q "ssl" "$NG" || certbot --nginx -d ops.172.237.20.244.sslip.io --agree-tos --register-unsafely-without-email --redirect -n || echo "(HTTPS 발급 실패 — http 로 사용)"
rm -rf /var/www/seo-dash /etc/nginx/.seo-dash.htpasswd   # 예전 방식의 공개 폴더·브라우저 비밀번호 창은 더 쓰지 않는다

# 5) 하루 두 번 갱신 (서버가 deploy 브랜치를 받은 뒤)
echo '30 7,15 * * * root /usr/bin/python3 /opt/seo-dash/dash.py --indexnow >> /var/log/seo-dash.log 2>&1' > /etc/cron.d/seo-dash

# 6) deploy 브랜치를 자동으로 받지 않는 사이트 확인
echo "== 자동 받기(cron)가 없는 사이트 폴더"
for d in /var/www/*/; do d=${d%/}; [ -d "$d/.git" ] && [ -f "$d/sitemap.xml" ] && ! crontab -l 2>/dev/null | grep -q "cd $d " && echo "  $d"; done; true

# 7) 첫 실행
echo "== 수집 실행"
python3 /opt/seo-dash/dash.py --indexnow | tee -a /var/log/seo-dash.log
echo
echo "화면 서버: $(systemctl is-active seo-dash) · 로그인 화면 응답 $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8791/login)"
echo "대시보드: $(grep -q ssl "$NG" && echo https || echo http)://ops.172.237.20.244.sslip.io/"
echo "아이디 admin / 처음 비밀번호는 /root/seo-dash-password.txt (화면에서 바꾸면 그 파일은 옛 값이 된다)"
