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
--push <대시보드 주소>: 다른 서버에서 돌 때 — 결과를 대시보드 서버의 /api/push 로 올린다(그 서버가 다음 수집 때 합친다).

방문 = 같은 IP·브라우저가 30분 넘게 쉬지 않고 이어 본 묶음. 전화 클릭 = 사이트의 tel: 링크를 누를 때 보내는 /_t?e=tel 요청.
"""
import datetime as dt, glob, gzip, html, http.client, json, os, re, secrets, socket, subprocess, sys, urllib.error, urllib.parse, urllib.request
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
                             'top': Counter(), 'e404': Counter(), 'hours': Counter(), 'real': set()})
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
                            c[ev] += 1; a['real'].add(key)
                            s = a['open'].get(key)
                            if s and tmin - s['_t'] <= 30: s[ev] = 1
                        continue
                    if '_rsc=' in req:
                        if bot: c['rsc_' + bot] += 1
                        elif human: a['real'].add(key)
                        continue
                    if bot and status in ('200', '304') and re.search(r'/(sitemap[^/]*\.xml|rss\.xml)$', path): c['sm_' + bot] += 1   # 로봇이 사이트맵·RSS 를 읽어 간 횟수
                    if human and method == 'GET' and status in ('200', '304') and not is_page(path): a['real'].add(key)   # 그림·스크립트까지 받아 간 접속 = 실제 브라우저
                    if method != 'GET' or not is_page(path): continue
                    if status == '404':
                        c['404'] += 1; a['e404'][path[:120]] += 1
                    if status not in ('200', '304'): continue
                    if bot:
                        c['bot_' + bot] += 1; a['crawled'][bot].add(path)
                    elif not human: c['bot_other'] += 1
                    else:
                        s = a['open'].get(key)
                        if not s or tmin - s['_t'] > 30:
                            src, rh, kw = source(ref, own[root])
                            s = {'t': f'{d} {hh}:{mi}', 'd': d, 'ip': mask(ip), 'src': src, 'ref': rh, 'kw': kw, 'land': path, 'pages': [], 'n': 0, 'dev': device(ua), '_k': key, '_pv': []}
                            a['open'][key] = s; a['sess'].append(s)
                        s['_t'] = tmin; s['n'] += 1; s['_pv'].append((int(hh), path))
                        if len(s['pages']) < 12: s['pages'].append(path)
    feed(afiles, False); feed(vfiles, True)
    # 사람 판정은 기록을 다 읽은 뒤에: 페이지만 가져가고 그림·스크립트는 한 번도 안 받은 접속은 브라우저 흉내 낸 프로그램으로 본다
    for a in A.values():
        keep = []
        for s in a['sess']:
            c = a['days'][s['d']]
            if s['_k'] not in a['real']:
                c['bot_other'] += s['n']; continue
            keep.append(s); c['visits'] += 1; c['src_' + s['src']] += 1; c['views'] += s['n']; a['uv'][s['d']].add(s['_k'])
            for hh, path in s['_pv']: a['top'][path] += 1; a['hours'][hh] += 1
        a['sess'] = keep
        for d, u in a['uv'].items(): a['days'][d]['visitors'] = len(u)
    return A, min(vdates) if vdates else None


MEDIA = {'naver': 'naver', 'google': 'google', 'daum': 'search_etc', 'bing': 'search_etc', 'naver_blog': 'naver_etc', 'naver_place': 'naver_etc',
         'naver_cafe': 'naver_etc', 'naver_etc': 'naver_etc', 'direct': 'direct'}   # 그 밖(다른 사이트·SNS·카카오) = other


def window(sess, sm, days):
    """최근 N일 방문 묶음 요약 — 어느 매체에서, 어떤 페이지로 들어왔는지. 페이지·유형마다 매체별 방문 수를 함께 낸다."""
    since = (NOW.date() - dt.timedelta(days=days - 1)).isoformat()
    src, land, kw, ref, dev, typ = Counter(), defaultdict(Counter), Counter(), Counter(), Counter(), defaultdict(Counter)
    pt = lambda p: ptype(p, sm.get(p, ('', '', ''))[2])
    for s in sess:
        if s['d'] < since: continue
        m = MEDIA.get(s['src'], 'other')
        src[s['src']] += 1; dev[s['dev']] += 1
        land[s['land']][m] += 1; typ[pt(s['land'])][m] += 1
        if s['kw'] and not s['kw'].startswith('http'): kw[(s['src'], s['kw'])] += 1   # 구글 링크 넘김(q=주소)은 검색어가 아니다
        if m in ('other', 'naver_etc'): ref[s['ref']] += 1
    tot = lambda c: sum(c.values())
    pick = {p for p, _ in sorted(land.items(), key=lambda x: -tot(x[1]))[:30]}
    for m in ('naver', 'google', 'search_etc', 'naver_etc', 'direct', 'other'):   # 매체별 상위도 빠지지 않게
        pick |= {p for p, c in sorted(land.items(), key=lambda x: -x[1][m])[:12] if c[m]}
    return {'src': dict(src), 'dev': dict(dev), 'type': {k: dict(v) for k, v in typ.items()},
            'land': [[p, pt(p), dict(land[p])] for p in sorted(pick, key=lambda p: -tot(land[p]))],
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


def deployed_at(root):
    """마지막으로 사이트 내용이 바뀐 시각(KST) — deploy 브랜치를 받는 폴더는 마지막 커밋 시각, 서버에서 빌드하는 폴더는 sitemap.xml 수정 시각."""
    ts = None
    if os.path.isdir(os.path.join(root, '.git')):
        try: ts = int(subprocess.run(['git', '-C', root, 'log', '-1', '--format=%ct'], capture_output=True, text=True, timeout=20).stdout.strip())
        except Exception: ts = None
    if not ts:
        try: ts = os.path.getmtime(os.path.join(root, 'sitemap.xml'))
        except Exception: return ''
    return dt.datetime.fromtimestamp(ts, dt.timezone(dt.timedelta(hours=9))).strftime('%Y-%m-%d %H:%M')


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
            t0 = st['days'].setdefault(TODAY, {})   # 날짜별 작업 기록: 그날 보낸 주소 수(여러 번 보내면 합산)와 마지막 응답
            t0['inow'] = t0.get('inow', 0) + n; t0['inow_naver'] = inow.get('naver', t0.get('inow_naver', '')); t0['inow_etc'] = inow.get('indexnow', t0.get('inow_etc', ''))
        ops = {}
        try: ops = json.load(open(os.path.join(s['root'], '.ops.json'), encoding='utf-8'))
        except Exception: pass
        plan = st.setdefault('plan', {})   # 일정 파일은 '앞으로 열릴 것'만 담으므로, 본 날마다 적어 두었다가 그날 실제 열린 수와 견준다
        for x in ops.get('schedule', []):
            if re.fullmatch(r'\d{4}-\d\d-\d\d', str(x.get('date', ''))): plan[x['date']] = {'pages': x.get('pages', 0), 'posts': x.get('posts', 0)}
        for k in [k for k in plan if k < (NOW.date() - dt.timedelta(days=60)).isoformat()]: del plan[k]
        t0 = st['days'].setdefault(TODAY, {}); dep = deployed_at(s['root'])
        t0['deployed'] = 1 if dep[:10] == TODAY else 0
        if dep[:10] == TODAY: t0['deploy_at'] = dep[11:]
        if TODAY in plan: t0['plan_pages'], t0['plan_posts'] = plan[TODAY]['pages'], plan[TODAY]['posts']
        sched = [x for x in ops.get('schedule', []) if x.get('date', '') > TODAY]
        left_pages, left_posts = sum(x.get('pages', 0) for x in sched), sum(x.get('posts', 0) for x in sched)
        dl = sorted(st['days'])[-45:]
        days = [dict(st['days'][d], d=d, est=0 if vstart and d >= vstart else 1) for d in dl]
        base = {'id': s['id'], 'name': s['name'], 'host': s['hosts'][0], 'preview': s['preview'], 'created': st.get('created', ''),
                'pages': len(sm) - len(blog), 'posts': len(blog), 'total': len(sm),
                'left_pages': left_pages, 'left_posts': left_posts,   # 전체 제작 = 공개(total) + 남은 것 — 같은 기준으로 센다
                'crawl': {b: len(got[b]) for b in got}, 'health': health(s, sm), 'days': days,
                'pending': max(len(st.get('pending', [])), len(st.get('pending_etc', []))), 'last_deploy': dep}
        data['sites'].append(base)
        sess = sorted(a['sess'], key=lambda x: x['t'], reverse=True)
        detail = dict(base, updated=data['updated'], today=TODAY, exact_from=vstart, types=dict(types), schedule=sched,
                      parts=[[n] + v for n, v in sorted(parts.items())], indexnow=inow,
                      pending=max(len(st['pending']), len(st.get('pending_etc', []))),
                      w7=window(sess, sm, 7), w14=window(sess, sm, 14),
                      top=[[p, n, ptype(p, sm.get(p, ('', '', ''))[2])] for p, n in a['top'].most_common(25)],
                      e404=a['e404'].most_common(15), hours=[a['hours'].get(h, 0) for h in range(24)],
                      visits=[{k: v for k, v in x.items() if k != 'd' and not k.startswith('_')} for x in sess[:400]])
        json.dump(detail, open(os.path.join(OUT, f'site-{s["id"]}.json'), 'w', encoding='utf-8'), ensure_ascii=False)
    for rd in sorted(glob.glob(os.path.join(OUT, 'remote', '*'))):   # 다른 서버 수집기가 올려 둔 결과(dash_app.py /api/push) — 그쪽 사이트를 이 화면에 합친다
        try:
            for x in json.load(open(os.path.join(rd, 'data.json'), encoding='utf-8'))['sites']:
                f = os.path.join(rd, f'site-{x.get("id", "")}.json')
                if not re.fullmatch(r'[a-z0-9.-]{1,120}', x.get('id', '')) or not os.path.isfile(f): continue
                open(os.path.join(OUT, f'site-{x["id"]}.json'), 'wb').write(open(f, 'rb').read())
                data['sites'] = [y for y in data['sites'] if y['id'] != x['id']] + [dict(x, node=os.path.basename(rd))]
        except Exception as e:
            print(f'  다른 서버 자료를 못 읽음: {os.path.basename(rd)} {str(e)[:80]}')
    data['sites'].sort(key=lambda x: (x['preview'], -x['total']))
    json.dump(state, open(sp, 'w', encoding='utf-8'), ensure_ascii=False)
    json.dump(data, open(os.path.join(OUT, 'data.json'), 'w', encoding='utf-8'), ensure_ascii=False)
    print(f'{data["updated"]} 사이트 {len(sites)}개, 공개 주소 {sum(x["total"] for x in data["sites"])}개')
    for x in data['sites']:
        y = next((d for d in x['days'] if d['d'] == (NOW.date() - dt.timedelta(days=1)).isoformat()), {})
        i = next((state[s['root']].get('indexnow') for s in sites if s['id'] == x['id']), None)
        print(f'  {x["name"]}: 공개 {x["total"]} · 어제 방문자 {y.get("visitors", 0)} · 네이버 수집 {y.get("bot_naver", 0)} · 구글 수집 {y.get("bot_google", 0)}'
              + (f' · IndexNow {i}' if i and i.get('date') == TODAY else '') + (f' · 점검 {x["health"]}' if x['health'] else ''))


def push(base):
    """이 서버의 결과를 대시보드 서버로 올린다. 토큰은 $DASH_STATE/push_token_node, 서버 이름은 $DASH_NODE(없으면 호스트 이름)."""
    tok = open(os.path.join(STATE, 'push_token_node')).read().strip()
    node = re.sub(r'[^a-z0-9-]', '', (E('DASH_NODE') or socket.gethostname()).lower())[:30] or 'node'
    res = Counter()
    for f in [os.path.join(OUT, 'data.json')] + sorted(glob.glob(os.path.join(OUT, 'site-*.json'))):
        req = urllib.request.Request(f'{base.rstrip("/")}/api/push/{os.path.basename(f)}', open(f, 'rb').read(),
                                     {'Content-Type': 'application/json', 'X-Dash-Token': tok, 'X-Dash-Node': node})
        try: res[urllib.request.urlopen(req, timeout=60).status] += 1
        except urllib.error.HTTPError as e: res[e.code] += 1
        except Exception as e: res[str(e)[:50]] += 1
    print(f'  대시보드로 올림({node}): {dict(res)}')


if __name__ == '__main__':
    main()
    if '--push' in sys.argv: push(sys.argv[sys.argv.index('--push') + 1])
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

    def push(self, name):
        """다른 서버의 수집기가 결과 파일을 올린다 — 로그인 대신 토큰($DASH_STATE/push_token)으로 확인한다."""
        tf = os.path.join(STATE, 'push_token')
        tok = open(tf).read().strip() if os.path.isfile(tf) else ''
        node = re.sub(r'[^a-z0-9-]', '', self.headers.get('X-Dash-Node', '').lower())[:30]
        n = int(self.headers.get('Content-Length') or 0)
        if not tok or not node or not hmac.compare_digest(self.headers.get('X-Dash-Token', ''), tok): return self.send(403, '{"error":"token"}', 'application/json')
        if not 0 < n <= 8_000_000: return self.send(413, '{"error":"size"}', 'application/json')
        raw = self.rfile.read(n)
        try: json.loads(raw)
        except Exception: return self.send(400, '{"error":"json"}', 'application/json')
        d = os.path.join(OUT, 'remote', node); os.makedirs(d, exist_ok=True)
        tmp = os.path.join(d, name + '.tmp')
        open(tmp, 'wb').write(raw); os.replace(tmp, os.path.join(d, name))
        self.send(200, '{"ok":true}', 'application/json')

    def do_POST(self):
        p = urllib.parse.urlparse(self.path).path
        m = re.fullmatch(r'/api/push/((?:data|site-[a-z0-9.-]{1,120})\.json)', p)
        if m: return self.push(m.group(1))
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
:root{color-scheme:light;--side:#111418;--side-ink:#aab2bd;--bg:#f3f4f7;--card:#fff;--ink:#15181d;--mute:#667080;--line:#e8ebef;--soft:#f5f6f8;
--naver:#0a8f4d;--google:#2b62d9;--search:#c2540a;--visit:#6b4fbb;--bar:#6b7a90;--bad:#c0291f;--good:#0a8f4d;--est:#eef0f3;--accent:#f39221;--r:14px}
*{box-sizing:border-box}html,body{margin:0}body{background:var(--bg);color:var(--ink);font:14px/1.5 Pretendard,system-ui,'Malgun Gothic',sans-serif}
a{color:inherit}button,select,input{font:inherit;color:inherit}svg.i{width:18px;height:18px;flex:none;fill:none;stroke:currentColor;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round}
.shell{display:grid;grid-template-columns:228px minmax(0,1fr);min-height:100vh}
aside{background:var(--side);color:var(--side-ink);padding:22px 14px;position:sticky;top:0;height:100vh;display:flex;flex-direction:column;gap:2px;overflow-y:auto}
.brand{display:flex;align-items:center;gap:10px;color:#fff;font-weight:800;font-size:16px;letter-spacing:-.01em;padding:0 8px 20px}
.brand i{width:30px;height:30px;border-radius:9px;background:var(--accent);display:grid;place-items:center;color:#111}
aside .grp{padding:16px 10px 6px;font-size:11px;color:#6b7482;letter-spacing:.06em}
aside a,aside button.nav{display:flex;align-items:center;gap:10px;padding:9px 10px;border-radius:10px;text-decoration:none;font-size:14px;background:none;border:0;width:100%;text-align:left;cursor:pointer;color:inherit}
aside a:hover,aside button.nav:hover{background:#1b2027;color:#fff}aside a.on{background:#232931;color:#fff}aside a.on svg{color:var(--accent)}
aside .sp{flex:1}
main{padding:0 28px 80px;min-width:0}
.topbar{display:flex;align-items:center;gap:12px;flex-wrap:wrap;padding:18px 0;position:sticky;top:0;background:var(--bg);z-index:6}
.topbar .grow{flex:1;min-width:0}
h1{font-size:22px;margin:0;letter-spacing:-.02em;line-height:1.3}h2{font-size:15px;margin:0;letter-spacing:-.01em}
.mute{color:var(--mute)}.small{font-size:12px}
.sw{position:relative}.swbtn{display:flex;align-items:center;gap:10px;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:9px 12px;cursor:pointer;min-width:220px;max-width:320px;box-shadow:0 1px 2px rgba(16,24,40,.04)}
.swbtn b{flex:1;text-align:left;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-weight:600}.swbtn:hover{border-color:#cfd5dd}
.pop{position:absolute;top:calc(100% + 6px);left:0;width:340px;max-width:92vw;background:var(--card);border:1px solid var(--line);border-radius:14px;box-shadow:0 12px 32px rgba(16,24,40,.14);padding:10px;display:none;z-index:8}
.pop.open{display:block}.pop input{width:100%;border:1px solid var(--line);border-radius:10px;padding:9px 12px;background:var(--soft);outline:0}.pop input:focus{border-color:#aab2bd;background:#fff}
.pop .list{max-height:380px;overflow-y:auto;margin-top:8px}.pop .g{font-size:11px;color:var(--mute);padding:8px 8px 4px;letter-spacing:.04em}
.pop a{display:flex;justify-content:space-between;gap:10px;padding:8px 10px;border-radius:9px;text-decoration:none}.pop a:hover,.pop a.on{background:var(--soft)}.pop a span:last-child{color:var(--mute);font-variant-numeric:tabular-nums;font-size:12px}
.seg{display:inline-flex;background:#e9ecf0;border-radius:10px;padding:3px}.seg button{background:none;border:0;padding:6px 12px;cursor:pointer;font-size:13px;border-radius:8px;color:var(--mute)}
.seg button.on{background:var(--card);color:var(--ink);font-weight:600;box-shadow:0 1px 2px rgba(16,24,40,.08)}
.tabs{display:none}
.note{background:#fff7ea;border:1px solid #f6dfb8;color:#6b4a12;border-radius:10px;padding:8px 12px;margin:0 0 16px;font-size:12px}
.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:14px;margin-bottom:18px}
@media(min-width:1100px){.kpis.k4{grid-template-columns:repeat(4,1fr)}}
.kpi{background:var(--card);border:1px solid var(--line);border-radius:var(--r);padding:16px;box-shadow:0 1px 2px rgba(16,24,40,.04)}
.kpi .kh{display:flex;align-items:center;gap:10px;color:var(--mute);font-size:13px;margin-bottom:10px}
.chip{width:34px;height:34px;border-radius:10px;display:grid;place-items:center;flex:none}
.c-visit{background:#efeafb;color:var(--visit)}.c-search{background:#fdf0e3;color:var(--search)}.c-naver{background:#e5f5ec;color:var(--naver)}.c-google{background:#e8effd;color:var(--google)}.c-ink{background:#eceff3;color:#3a4350}.c-bad{background:#fdecea;color:var(--bad)}
.kpi b{display:block;font-size:26px;line-height:1.2;font-variant-numeric:tabular-nums;letter-spacing:-.02em}.kpi .ks{margin-top:6px;font-size:12px;color:var(--mute);min-height:18px}
.dl{display:inline-block;padding:1px 7px;border-radius:6px;font-weight:600;font-variant-numeric:tabular-nums;margin-right:6px}.dl.up{background:#e5f5ec;color:var(--good)}.dl.down{background:#fdecea;color:var(--bad)}.dl.flat{background:#eceff3;color:var(--mute)}
[data-h]{cursor:help;border-bottom:1px dotted #b3bbc6}
.grid2{display:grid;grid-template-columns:repeat(auto-fit,minmax(420px,1fr));gap:18px;margin-bottom:18px}.grid3{display:grid;grid-template-columns:minmax(0,1.6fr) minmax(320px,1fr);gap:18px;margin-bottom:18px}
.card{background:var(--card);border:1px solid var(--line);border-radius:var(--r);padding:18px;min-width:0;box-shadow:0 1px 2px rgba(16,24,40,.04)}.card.full{margin-bottom:18px}.card.flush{padding:0;overflow:hidden}
.chead{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:12px}.card.flush .chead{padding:16px 18px 0}
.legend{display:flex;gap:14px;flex-wrap:wrap;font-size:12px;color:var(--mute)}.legend i{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:6px;vertical-align:-1px}
.scroll{overflow-x:auto}table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}
th,td{padding:10px 14px;border-bottom:1px solid var(--line);text-align:right;white-space:nowrap}th{font-size:12px;font-weight:600;color:var(--mute);background:var(--soft)}
tr:last-child td{border-bottom:0}th:first-child,td:first-child,th.l,td.l{text-align:left}td.wrap{white-space:normal;word-break:break-all;max-width:420px}
th[data-ls]{cursor:pointer;user-select:none}th[data-ls]:hover{color:var(--ink)}.sw2{display:inline-block;width:8px;height:8px;border-radius:2px;margin-right:6px;vertical-align:1px}
th[data-sort]{cursor:pointer;user-select:none}th[data-sort]:hover{color:var(--ink)}th .ar{display:inline-block;width:10px;color:var(--accent)}
.pb{display:inline-block;width:54px;height:6px;border-radius:3px;background:#eceff3;vertical-align:middle;margin-right:8px;overflow:hidden}.pb i{display:block;height:100%;border-radius:3px}
tr.row{cursor:pointer}tr.row:hover td{background:#fafbfc}tr.pre td:first-child{color:var(--mute)}tr.more{display:none}.open tr.more{display:table-row}
.morebtn{display:block;width:100%;background:var(--soft);border:0;border-top:1px solid var(--line);padding:10px;cursor:pointer;color:var(--mute);font-size:13px}.morebtn:hover{color:var(--ink)}
.card:not(.flush) .morebtn{border:1px solid var(--line);border-radius:10px;margin-top:10px}
.zero{color:#b3bbc6}.warn{color:var(--bad);font-weight:600}.ok{color:var(--good);font-weight:600}
.tag{display:inline-block;font-size:11px;padding:1px 7px;border-radius:6px;background:#eceff3;color:var(--mute);margin-left:6px;font-weight:500}
.hb{display:grid;grid-template-columns:minmax(110px,170px) 1fr 92px;gap:10px;align-items:center;padding:6px 0;font-size:13px}
.hb .t{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.hb .b{height:8px;background:var(--soft);border-radius:4px;overflow:hidden}.hb .b i{display:block;height:100%;background:var(--bar);border-radius:4px}.hb .v{text-align:right;font-variant-numeric:tabular-nums}
.donut{display:grid;grid-template-columns:170px 1fr;gap:18px;align-items:center}.donut ul{list-style:none;margin:0;padding:0;display:grid;gap:8px;font-size:13px}
.donut li{display:grid;grid-template-columns:14px 1fr auto auto;gap:8px;align-items:center}.donut li i{width:10px;height:10px;border-radius:3px}.donut li b{font-variant-numeric:tabular-nums}.donut li span:last-child{color:var(--mute);font-size:12px;width:44px;text-align:right}
.chart{position:relative}.chart svg{display:block;width:100%}
#tip{position:fixed;z-index:20;pointer-events:none;background:#15181d;color:#fff;padding:9px 11px;font-size:12px;line-height:1.55;max-width:300px;border-radius:10px;display:none;box-shadow:0 8px 20px rgba(0,0,0,.2)}
#tip i{display:inline-block;width:8px;height:8px;border-radius:2px;margin-right:6px}#tip b{font-variant-numeric:tabular-nums}
.filters{display:flex;gap:8px;flex-wrap:wrap}.filters select,.filters input,.form input{border:1px solid var(--line);background:var(--card);padding:8px 12px;border-radius:10px;outline:0}.filters input:focus,.form input:focus{border-color:#aab2bd}
.trail{background:var(--soft);white-space:normal;text-align:left;line-height:1.9}.trail span{color:var(--mute)}
.form{max-width:360px;display:grid;gap:12px}.form label{display:grid;gap:5px;font-size:12px;color:var(--mute)}
.btn{background:var(--ink);color:#fff;border:0;padding:11px 16px;cursor:pointer;font-weight:600;border-radius:10px}
dl.gloss{margin:0;display:grid;grid-template-columns:190px 1fr}dl.gloss dt,dl.gloss dd{margin:0;padding:11px 4px;border-bottom:1px solid var(--line)}dl.gloss dt{font-weight:600}dl.gloss dd{color:#3a4350}
details summary{cursor:pointer;color:var(--mute);font-size:12px;margin-top:12px}details .scroll{margin-top:8px;border:1px solid var(--line);border-radius:10px}
.al{display:grid;grid-template-columns:auto 1fr;gap:10px;align-items:start;padding:8px 0}.al .lv{font-size:11px;font-weight:700;padding:2px 8px;border-radius:6px;white-space:nowrap;margin-top:1px}.alsite{padding:12px 0;border-top:1px solid var(--line)}.alsite:first-of-type{border-top:0;padding-top:0}.alsite>a{text-decoration:none}
.sitehead{display:flex;gap:10px 18px;flex-wrap:wrap;align-items:center;margin:-4px 0 16px;font-size:12px;color:var(--mute)}.sitehead a{color:var(--ink)}
@media(max-width:900px){.shell{grid-template-columns:minmax(0,1fr)}aside{display:none}main{padding:0 14px 60px}.grid2,.grid3{grid-template-columns:minmax(0,1fr)}.donut{grid-template-columns:1fr}dl.gloss{grid-template-columns:1fr}dl.gloss dt{border-bottom:0;padding-bottom:0}
.tabs{display:flex;gap:6px;overflow-x:auto;margin:0 0 14px}.tabs a{padding:7px 12px;border-radius:9px;background:var(--card);border:1px solid var(--line);text-decoration:none;white-space:nowrap;font-size:13px}.tabs a.on{background:var(--ink);color:#fff;border-color:var(--ink)}.swbtn{min-width:0;max-width:none;width:100%}.sw,.topbar .grow{flex:1 0 100%}.topbar{position:static;padding:14px 0}.kpis{grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.kpi{padding:12px}.kpi b{font-size:22px}}
</style></head><body>
<div class="shell"><aside id="side"></aside><main><div class="topbar" id="top"></div><div id="main"><p class="mute">불러오는 중</p></div></main></div>
<div id="tip" role="tooltip"></div>
<script>
const HELP={
visitors:['방문자','그날 사이트에 들어온 사람 수입니다. 같은 IP와 같은 브라우저는 하루에 한 명으로 셉니다. 페이지의 그림이나 스크립트까지 불러온 접속만 사람으로 세고, 페이지 글자만 가져간 접속은 자동 프로그램으로 보고 뺍니다.'],
visits:['방문','한 사람이 들어와서 30분 넘게 쉬지 않고 이어 본 한 묶음입니다. 같은 사람이 오전과 오후에 따로 들어오면 2번으로 셉니다.'],
views:['조회','사람이 페이지를 연 횟수입니다. 한 번 방문에 3쪽을 보면 3입니다.'],
search:['검색 유입','네이버·구글·다음·빙 검색 결과를 눌러 들어온 방문 수입니다. 네이버 앱은 경로를 안 남기는 경우가 있어 실제보다 적게 잡힙니다.'],
tel:['전화 클릭','사이트의 전화 버튼을 누른 횟수입니다. 실제 통화 연결 여부까지는 알 수 없습니다. 전화 버튼에 집계 코드를 넣은 사이트만 셉니다.'],
total:['공개 주소','지금 검색 로봇에게 열려 있는 주소 수입니다. 사이트맵에 올라 있는 페이지와 블로그 글을 모두 셉니다.'],
made:['전체 제작','만들어 둔 주소 전체입니다. 공개 주소에 아직 열리지 않은 페이지와 예약된 글을 더한 수입니다.'],
left:['남은 수','만들어 뒀지만 아직 열리지 않은 페이지와 글입니다. 일정에 따라 자동으로 열립니다.'],
new_pages:['오늘 열림','오늘 새로 공개된 페이지 수입니다. 대시보드가 그 사이트를 처음 본 날은 기준일이라 0이고 그다음 날부터 셉니다.'],
new_posts:['오늘 발행','오늘 새로 공개된 블로그 글 수입니다. 기준일은 0입니다.'],
bot_naver:['네이버 수집','네이버 검색 로봇(Yeti)이 페이지를 정상으로 가져간 횟수입니다. 가져가야 색인이 됩니다.'],
bot_google:['구글 수집','구글 검색 로봇(Googlebot)이 페이지를 정상으로 가져간 횟수입니다.'],
cov_naver:['네이버 수집률','네이버 로봇이 한 번이라도 가져간 주소 ÷ 공개 주소입니다. 100%에 가까울수록 사이트 전체를 로봇이 본 것입니다.'],
cov_google:['구글 수집률','구글 로봇이 한 번이라도 가져간 주소 ÷ 공개 주소입니다.'],
rsc:['수집 낭비','네이버 로봇이 페이지 대신 화면 전환용 보조 파일(_rsc)을 가져간 횟수입니다. 하루 수집 한도를 깎아 먹습니다.'],
e404:['없는 주소 요청','없는 주소를 요청해 404가 나간 횟수입니다. 삭제한 주소나 잘못 걸린 링크가 있으면 늘어납니다.'],
src:['유입 경로','방문이 시작될 때 어디서 왔는지입니다. 매체는 네이버 검색 / 구글 검색 / 다음·빙 / 네이버 블로그·플레이스·카페 / 직접 / 그 밖(다른 사이트·SNS·카카오)으로 나눕니다. 주소를 직접 치거나 앱에서 열어 경로가 안 남으면 "직접·알 수 없음"으로 셉니다.'],
ptype:['페이지 유형','메인 / 허브·서비스(지역 목록, 소개, 서비스 안내) / 지역·키워드(대량 제작 페이지) / 콘텐츠(블로그 글)로 나눕니다.'],
kw:['검색어','검색 결과에서 넘어올 때 검색어가 함께 넘어온 경우만 보입니다. 네이버와 구글은 대부분 검색어를 넘겨주지 않아 일부만 잡힙니다.'],
land:['들어온 페이지','방문이 시작된 첫 페이지입니다. 검색에 걸려 있는 페이지가 무엇인지 알 수 있습니다.'],
created:['도메인 등록일','도메인을 처음 등록한 날짜입니다. 등록 정보에서 조회합니다.'],
est:['추정 값','사이트별 기록을 남기기 전(2026-11-16 13시 이전) 날짜는 주소로 사이트를 역추적한 값입니다. 메인 페이지 요청이 빠져 있어 실제보다 적습니다.'],
indexnow:['IndexNow','새로 열린 주소를 네이버와 빙에 바로 알리는 기능입니다. 매일 자동으로 보냅니다.'],
smread:['사이트맵 읽어감','검색 로봇이 사이트맵(sitemap.xml)이나 RSS 를 가져간 횟수입니다. 읽어 가야 새 주소를 알게 됩니다. 사이트별 기록을 남기기 시작한 날부터 셉니다.'],
health:['점검','표본 30쪽을 열어 파일이 있는지, 대표 주소(canonical)가 있는지, 색인 차단(noindex)이 걸려 있지 않은지 봅니다.']};
const SRC={naver:'네이버 검색',google:'구글 검색',daum:'다음 검색',bing:'빙 검색',naver_blog:'네이버 블로그',naver_place:'네이버 플레이스·지도',naver_cafe:'네이버 카페',naver_etc:'네이버 기타',kakao:'카카오',sns:'SNS',site:'다른 사이트',direct:'직접·알 수 없음'};
const TYPE={home:'메인',hub:'허브·서비스',kw:'지역·키워드',post:'콘텐츠(글)'};
const C={naver:'var(--naver)',google:'var(--google)',search:'var(--search)',visit:'var(--visit)'};
const IC={grid:'M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z',pulse:'M3 12h4l3-8 4 16 3-8h4',users:'M16 20v-1a4 4 0 0 0-4-4H7a4 4 0 0 0-4 4v1M9.5 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7M21 20v-1a4 4 0 0 0-3-3.9M15.5 4.2a3.5 3.5 0 0 1 0 6.6',bot:'M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14M20 20l-4-4',cal:'M5 6h14a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1M8 3v5M16 3v5M4 11h16',book:'M5 4h11a3 3 0 0 1 3 3v13H8a3 3 0 0 1-3-3zM5 17a3 3 0 0 1 3-3h11',key:'M14 10a4 4 0 1 0-3.5 3.9L12 15.5V18h2.5v2H17v-3l-3.6-3.6A4 4 0 0 0 14 10M9 9h.01',out:'M10 4H5v16h5M15 8l4 4-4 4M19 12H9',down:'M6 9l6 6 6-6',phone:'M6 3h3l2 5-2.5 1.5a11 11 0 0 0 6 6L16 13l5 2v3a2 2 0 0 1-2 2A16 16 0 0 1 4 5a2 2 0 0 1 2-2',globe:'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18M3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18',file:'M7 3h7l5 5v13H7zM14 3v5h5',eye:'M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6',alert:'M12 4l9 16H3zM12 10v4M12 17h.01',plus:'M12 5v14M5 12h14',ban:'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18M6 6l12 12'};
const ic=n=>`<svg class="i" viewBox="0 0 24 24" aria-hidden="true"><path d="${IC[n]}"/></svg>`;
const $=s=>document.querySelector(s),main=$('#main'),tip=$('#tip');
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const f=n=>n?Number(n).toLocaleString('ko-KR'):'<span class="zero">0</span>';
const pct=(a,b)=>b?(Math.round(a/b*1000)/10)+'%':'-';
const h=(k,t)=>`<span data-h="${k}">${esc(t||HELP[k][0])}</span>`;
let D=null,range=30,win=7,lsort='all',sortK=1,sortDir=-1,query='';const cache={};
const day=n=>{const d=new Date(D.today+'T00:00:00Z');d.setUTCDate(d.getUTCDate()-n);return d.toISOString().slice(0,10)};
const searchOf=x=>(x.src_naver||0)+(x.src_google||0)+(x.src_daum||0)+(x.src_bing||0);
const val=(x,k)=>typeof k==='function'?k(x):(x[k]||0);
const sum=(days,k,from,to)=>days.reduce((a,x)=>a+(x.d>=from&&(!to||x.d<=to)?val(x,k):0),0);
function delta(cur,prev,label){if(!prev)return `<span class="dl flat">-</span>${label||'비교할 이전 값 없음'}`;const p=Math.round((cur-prev)/prev*100);return `<span class="dl ${p>0?'up':p<0?'down':'flat'}">${p>0?'▲':p<0?'▼':''} ${Math.abs(p)}%</span>이전 ${Number(prev).toLocaleString('ko-KR')}`}
const kpi=(k,icon,cls,v,sub,label)=>`<div class="kpi"><div class="kh"><span class="chip ${cls}">${ic(icon)}</span>${h(k,label)}</div><b>${v}</b><div class="ks">${sub||''}</div></div>`;
function series(days,n){const m=Object.fromEntries(days.map(x=>[x.d,x]));const out=[];for(let i=n-1;i>=0;i--){const d=day(i);out.push(m[d]||{d,est:D.exact_from&&d>=D.exact_from?0:1})}return out}
function merge(sites){const m={};sites.forEach(s=>s.days.forEach(x=>{const o=m[x.d]||(m[x.d]={d:x.d,est:x.est});for(const k in x)if(typeof x[k]==='number'&&k!=='est')o[k]=(o[k]||0)+x[k];o.est=o.est&&x.est}));return Object.values(m)}

/* 추이 그래프: 가로축 날짜, 세로축 하나. 첫 계열은 면으로 채우고, 마우스를 올리면 날짜와 값 */
function lineChart(el,days,ser){
  const W=Math.max(320,el.clientWidth),H=240,L=44,R=14,T=12,B=28,n=days.length,id='g'+Math.random().toString(36).slice(2,7);
  const max=Math.max(4,...days.flatMap(x=>ser.map(s=>val(x,s.k)))),step=Math.pow(10,Math.floor(Math.log10(max))),top=Math.ceil(max/step)*step;
  const X=i=>L+(n>1?i*(W-L-R)/(n-1):0),Y=v=>T+(H-T-B)*(1-v/top);
  let g=`<defs><linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${ser[0].c}" stop-opacity=".2"/><stop offset="1" stop-color="${ser[0].c}" stop-opacity="0"/></linearGradient></defs>`;
  const estN=days.filter(x=>x.est).length;if(estN)g+=`<rect x="${L}" y="${T}" width="${Math.max(0,X(Math.min(estN,n-1))-L)}" height="${H-T-B}" fill="var(--est)" rx="6"/>`;
  for(let i=0;i<=4;i++){const v=top*i/4,y=Y(v);g+=`<line x1="${L}" x2="${W-R}" y1="${y}" y2="${y}" stroke="#eceef1" stroke-dasharray="${i?'3 4':''}"/><text x="${L-8}" y="${y+4}" text-anchor="end" font-size="11" fill="#667080">${Math.round(v).toLocaleString('ko-KR')}</text>`}
  const every=Math.ceil(n/7);days.forEach((x,i)=>{if(i%every===0||i===n-1)g+=`<text x="${X(i)}" y="${H-8}" text-anchor="${i===n-1?'end':'middle'}" font-size="11" fill="#667080">${x.d.slice(5)}</text>`});
  const pts=k=>days.map((x,i)=>X(i)+','+Y(val(x,k))).join(' ');
  g+=`<polygon fill="url(#${id})" points="${X(0)},${Y(0)} ${pts(ser[0].k)} ${X(n-1)},${Y(0)}"/>`;
  ser.forEach(s=>{g+=`<polyline fill="none" stroke="${s.c}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" points="${pts(s.k)}"/>`});
  ser.forEach((s,j)=>{g+=`<circle class="pt${j}" r="4.5" fill="${s.c}" stroke="#fff" stroke-width="2" cx="${X(n-1)}" cy="${Y(val(days[n-1],s.k))}"/>`});
  el.innerHTML=`<svg viewBox="0 0 ${W} ${H}" height="${H}" role="img" aria-label="${esc(ser.map(s=>s.t).join(', '))} 날짜별 추이">${g}<line id="x" y1="${T}" y2="${H-B}" stroke="#15181d" stroke-width="1" stroke-dasharray="3 3" visibility="hidden"/><rect x="${L}" y="${T}" width="${W-L-R}" height="${H-T-B}" fill="transparent"/></svg>`;
  const svg=el.firstChild,cross=svg.querySelector('#x'),move=i=>ser.forEach((s,j)=>{const c=svg.querySelector('.pt'+j);c.setAttribute('cx',X(i));c.setAttribute('cy',Y(val(days[i],s.k)))});
  svg.onmousemove=e=>{const r=svg.getBoundingClientRect(),px=(e.clientX-r.left)*W/r.width,i=Math.max(0,Math.min(n-1,Math.round((px-L)/((W-L-R)/Math.max(1,n-1))))),x=days[i];
    cross.setAttribute('x1',X(i));cross.setAttribute('x2',X(i));cross.setAttribute('visibility','visible');move(i);
    showTip(e,`<div>${x.d}${x.est?' · 추정':''}</div>`+ser.map(s=>`<div><i style="background:${s.c}"></i>${esc(s.t)} <b>${val(x,s.k).toLocaleString('ko-KR')}</b></div>`).join(''))};
  svg.onmouseleave=()=>{cross.setAttribute('visibility','hidden');move(n-1);tip.style.display='none'}}
function barChart(el,vals,label){
  const W=Math.max(320,el.clientWidth),H=190,L=36,R=8,T=10,B=26,n=vals.length,max=Math.max(4,...vals),bw=(W-L-R)/n;
  let g=`<line x1="${L}" x2="${W-R}" y1="${H-B}" y2="${H-B}" stroke="#dfe3e8"/><text x="${L-8}" y="${T+8}" text-anchor="end" font-size="11" fill="#667080">${max.toLocaleString('ko-KR')}</text>`;
  vals.forEach((v,i)=>{const bh=(H-T-B)*v/max,w=Math.max(3,bw-6);g+=`<rect x="${L+i*bw+(bw-w)/2}" y="${H-B-bh}" width="${w}" height="${bh}" rx="${Math.min(4,w/2)}" fill="var(--visit)" opacity="${v===max?1:.55}"/><rect data-i="${i}" x="${L+i*bw}" y="${T}" width="${bw}" height="${H-T-B}" fill="transparent"/>`;
    if(i%3===0)g+=`<text x="${L+i*bw+bw/2}" y="${H-8}" text-anchor="middle" font-size="11" fill="#667080">${i}시</text>`});
  el.innerHTML=`<svg viewBox="0 0 ${W} ${H}" height="${H}" role="img" aria-label="${esc(label)}">${g}</svg>`;
  el.firstChild.onmousemove=e=>{const i=e.target.dataset.i;if(i==null){tip.style.display='none';return}showTip(e,`<div>${i}시 ~ ${+i+1}시</div><div>${esc(label)} <b>${vals[i].toLocaleString('ko-KR')}</b></div>`)};
  el.firstChild.onmouseleave=()=>tip.style.display='none'}
/* 도넛: 유입 경로 비중. 색은 경로마다 고정, 값과 비율은 옆 목록에 글자로 */
const SRCG=[['네이버 검색',['naver'],'var(--naver)'],['구글 검색',['google'],'var(--google)'],['다음·빙 검색',['daum','bing'],'var(--search)'],['네이버 블로그·플레이스·카페',['naver_blog','naver_place','naver_cafe','naver_etc'],'var(--visit)'],['직접·알 수 없음',['direct'],'#8792a2'],['그 밖(다른 사이트·SNS·카카오)',['site','sns','kakao'],'#c3cad4']];
function donut(src){const items=SRCG.map(g=>({t:g[0],v:g[1].reduce((a,k)=>a+(src[k]||0),0),c:g[2]})).filter(x=>x.v),tot=items.reduce((a,x)=>a+x.v,0);
  if(!tot)return '<p class="mute small">이 기간에 방문이 없습니다</p>';
  const R=70,r=46,cx=85,cy=85;let a0=-Math.PI/2,g='';
  items.forEach((x,i)=>{const a1=a0+x.v/tot*Math.PI*2,big=a1-a0>Math.PI?1:0,p=(a,rad)=>[cx+rad*Math.cos(a),cy+rad*Math.sin(a)].map(n=>n.toFixed(2)).join(' ');
    g+=items.length===1?`<circle cx="${cx}" cy="${cy}" r="${(R+r)/2}" fill="none" stroke="${x.c}" stroke-width="${R-r}" data-i="${i}"/>`:`<path data-i="${i}" d="M${p(a0,R)} A${R} ${R} 0 ${big} 1 ${p(a1,R)} L${p(a1,r)} A${r} ${r} 0 ${big} 0 ${p(a0,r)}Z" fill="${x.c}" stroke="#fff" stroke-width="2"/>`;a0=a1});
  return `<div class="donut" data-donut='${esc(JSON.stringify(items.map(x=>[x.t,x.v])))}'><svg viewBox="0 0 170 170" width="170" height="170" role="img" aria-label="유입 경로 비중">${g}<text x="${cx}" y="${cy-2}" text-anchor="middle" font-size="22" font-weight="700" fill="#15181d">${tot.toLocaleString('ko-KR')}</text><text x="${cx}" y="${cy+16}" text-anchor="middle" font-size="11" fill="#667080">방문</text></svg>
  <ul>${items.map(x=>`<li><i style="background:${x.c}"></i><span>${esc(x.t)}</span><b>${x.v.toLocaleString('ko-KR')}</b><span>${pct(x.v,tot)}</span></li>`).join('')}</ul></div>`}
function showTip(e,html){tip.innerHTML=html;tip.style.display='block';const w=tip.offsetWidth,x=e.clientX+14+w>innerWidth?e.clientX-w-14:e.clientX+14;tip.style.left=Math.max(6,x)+'px';tip.style.top=Math.min(innerHeight-tip.offsetHeight-8,e.clientY+14)+'px'}
const legend=ser=>`<div class="legend">${ser.map(s=>`<span><i style="background:${s.c}"></i>${esc(s.t)}</span>`).join('')}</div>`;
function hbars(items,empty,color){const max=Math.max(1,...items.map(x=>x[1]));return items.length?items.map(x=>`<div class="hb"><span class="t" title="${esc(x[0])}">${esc(x[0])}</span><span class="b"><i style="width:${x[1]/max*100}%${color?';background:'+color:''}"></i></span><span class="v">${f(x[1])}${x[2]!=null?` <span class="mute small">${esc(x[2])}</span>`:''}</span></div>`).join(''):`<p class="mute small">${empty||'자료 없음'}</p>`}
const seg=(name,opts,cur)=>`<span class="seg" data-seg="${name}">${opts.map(o=>`<button type="button" data-v="${o[0]}" class="${o[0]==cur?'on':''}">${o[1]}</button>`).join('')}</span>`;
/* 긴 표는 앞의 몇 줄만 보여 주고 버튼으로 펼친다 */
function tbl(head,rows,empty,limit=8){const cols=(head.match(/<th/g)||[]).length;
  return `<div class="fold"><div class="scroll"><table><tr>${head}</tr>${rows.map((r,i)=>r.replace('<tr','<tr'+(i>=limit?' class="more"':''))).join('')||`<tr><td class="mute l" colspan="${cols}">${empty}</td></tr>`}</table></div>${rows.length>limit?`<button type="button" class="morebtn" data-more="${rows.length}">전체 ${rows.length}줄 보기</button>`:''}</div>`}
const charts=[];function draw(){charts.forEach(c=>c())}
function dayTable(days,cols){return `<details><summary>날짜별 표로 보기</summary><div class="scroll"><table><tr><th>날짜</th>${cols.map(c=>`<th>${esc(c[0])}</th>`).join('')}</tr>${days.slice().reverse().map(x=>`<tr><td>${x.d}${x.est?'<span class="tag">추정</span>':''}</td>${cols.map(c=>`<td>${f(val(x,c[1]))}</td>`).join('')}</tr>`).join('')}</table></div></details>`}
const estNote=days=>days.some(x=>x.est)?`<p class="note">그래프의 회색 구간은 ${h('est','추정한 값')}입니다. ${D.exact_from?esc(D.exact_from)+'부터는 사이트별로 정확히 셉니다.':'아직 사이트별 기록이 없습니다.'}</p>`:'';
const VS=[{k:'visitors',t:'방문자',c:C.visit},{k:searchOf,t:'검색 유입',c:C.search}],BS=[{k:'bot_google',t:'구글 수집',c:C.google},{k:'bot_naver',t:'네이버 수집',c:C.naver}];
const MED=[['naver','네이버 검색','var(--naver)'],['google','구글 검색','var(--google)'],['search_etc','다음·빙','var(--search)'],['naver_etc','네이버 블로그·플레이스','var(--visit)'],['direct','직접·알 수 없음','#8792a2'],['other','그 밖','#c3cad4']];
const MS=[{k:'src_naver',t:'네이버 검색',c:C.naver},{k:'src_google',t:'구글 검색',c:C.google},{k:x=>(x.src_daum||0)+(x.src_bing||0),t:'다음·빙',c:C.search},{k:'src_direct',t:'직접·알 수 없음',c:'#8792a2'}];
const made=s=>s.total+s.left_pages+s.left_posts,RNG=[[14,'14일'],[30,'30일'],[45,'45일']];
const plink=(s,p)=>`<a href="https://${esc(s.host)}${esc(encodeURI(p))}" target="_blank" rel="noopener noreferrer">${esc(p)}</a>`;

const COLS=[['사이트',s=>s.name,null],['visitors',(s,c)=>sum(s.days,'visitors',c.y,c.y),'방문자 어제'],['search',(s,c)=>sum(s.days,searchOf,c.w,c.y),'검색 유입 7일'],['tel',(s,c)=>sum(s.days,'tel',c.w),'전화 7일'],['total',s=>s.total],['made',s=>made(s)],['new_pages',(s,c)=>sum(s.days,'new_pages',c.t,c.t)],['new_posts',(s,c)=>sum(s.days,'new_posts',c.t,c.t)],['bot_naver',(s,c)=>sum(s.days,'bot_naver',c.w,c.y),'네이버 수집 7일'],['bot_google',(s,c)=>sum(s.days,'bot_google',c.w,c.y),'구글 수집 7일'],['cov_naver',s=>s.total?s.crawl.naver/s.total:0],['cov_google',s=>s.total?s.crawl.google/s.total:0],['health',s=>Object.keys(s.health||{}).length]];
function spark(days){const v=series(days,14).map(x=>x.visitors||0),m=Math.max(1,...v),W=84,H=24;if(!v.some(Boolean))return '<span class="zero">-</span>';
  const pts=v.map((y,i)=>(i*W/13).toFixed(1)+','+(H-2-(H-4)*y/m).toFixed(1)).join(' ');
  return `<svg width="${W}" height="${H}" role="img" aria-label="방문자 14일 추이"><title>최근 14일 방문자 (최대 ${m})</title><polygon points="0,${H} ${pts} ${W},${H}" fill="var(--visit)" opacity=".12"/><polyline points="${pts}" fill="none" stroke="var(--visit)" stroke-width="1.6" stroke-linejoin="round"/></svg>`}
function siteRows(){const c={y:day(1),w:day(7),t:D.today},q=query.trim().toLowerCase();
  const rows=D.sites.filter(s=>!q||s.name.toLowerCase().includes(q)||s.host.includes(q)).map(s=>({s,v:COLS.map(col=>col[1](s,c))}));
  rows.sort((a,b)=>(a.s.preview-b.s.preview)||((typeof a.v[sortK]==='string'?a.v[sortK].localeCompare(b.v[sortK],'ko'):a.v[sortK]-b.v[sortK])*sortDir));
  $('#st').innerHTML=`<tr>${COLS.map((col,i)=>`<th data-sort="${i}">${i?h(col[0],col[2]):'사이트'}<span class="ar">${i===sortK?(sortDir<0?'▾':'▴'):''}</span></th>${i?'':'<th>방문자 14일</th>'}`).join('')}</tr>`+
  (rows.map(({s,v})=>`<tr class="row${s.preview?' pre':''}" data-go="#/s/${esc(s.id)}"><td>${esc(s.name)}${s.preview?'<span class="tag">미리보기</span>':''}</td><td>${spark(s.days)}</td>${v.slice(1,10).map(x=>`<td>${f(x)}</td>`).join('')}<td><span class="pb"><i style="width:${v[10]*100}%;background:var(--naver)"></i></span>${pct(s.crawl.naver,s.total)}</td><td><span class="pb"><i style="width:${v[11]*100}%;background:var(--google)"></i></span>${pct(s.crawl.google,s.total)}</td><td>${v[12]?`<span class="warn">확인 필요 ${v[12]}</span>`:'<span class="ok">정상</span>'}</td></tr>`).join('')||`<tr><td class="mute l" colspan="14">찾는 사이트가 없습니다</td></tr>`)}

/* 점검이 필요한 사이트: 자료에서 규칙으로 뽑는다. [심각도, 무엇이 문제인지, 무엇을 하면 되는지] */
function alerts(s){const a=[],d=s.days,t=D.today,y=day(1),w=day(7),T=d.find(x=>x.d===t)||{},hour=+D.updated.slice(11,13);
  const exact=d.filter(x=>!x.est).length,ex=d.filter(x=>!x.est);
  Object.entries(s.health||{}).forEach(([k,v])=>a.push(['bad',`점검 표본에서 "${k}" ${v}건`,k.includes('메인')?'사이트가 열리는지, 서버의 nginx 설정과 인증서를 확인합니다.':'배포가 끝까지 됐는지 확인하고, 사이트맵에 있는 주소가 실제로 열리는지 봅니다.']));
  if(s.preview)return a;
  if(hour>=8&&!T.deployed&&(T.plan_pages||T.plan_posts))a.push(['bad',`오늘 열릴 예정(페이지 ${T.plan_pages||0} · 글 ${T.plan_posts||0})이 있는데 배포가 안 됐습니다`,'아침 자동 배포 기록(_ops/daily.log 또는 GitHub Actions)을 확인합니다. 마지막 반영 '+(s.last_deploy||'알 수 없음')]);
  if(T.deployed&&(T.new_pages||0)<(T.plan_pages||0))a.push(['warn',`오늘 페이지가 계획 ${T.plan_pages}개 중 ${T.new_pages||0}개만 열렸습니다`,'빌드할 때 묶음(OPEN_WAVE)이 맞게 들어갔는지 확인합니다.']);
  if(T.deployed&&(T.new_posts||0)<(T.plan_posts||0))a.push(['warn',`오늘 글이 계획 ${T.plan_posts}편 중 ${T.new_posts||0}편만 발행됐습니다`,'글의 date 값과 빌드 시각을 확인합니다(오후 발행분은 오후 빌드 뒤에 열립니다).']);
  const ok=c=>c===200||c===202||c===''||c==null;
  if(T.inow&&(!ok(T.inow_naver)||!ok(T.inow_etc)))a.push(['warn',`IndexNow 전송이 거절됐습니다 (네이버 ${T.inow_naver} · 빙 쪽 ${T.inow_etc})`,'다음 수집 때 거절된 쪽만 자동으로 다시 보냅니다. 이틀 넘게 이어지면 인증 파일(사이트 주소/키.txt)이 열리는지 확인합니다.']);
  if(s.total>=200){
    if(sum(d,'bot_naver',w)===0)a.push(['warn','네이버 로봇이 7일 동안 안쪽 페이지를 하나도 가져가지 않았습니다','서치어드바이저에서 사이트맵과 RSS 가 제출돼 있는지 확인하고, "웹 페이지 수집"으로 허브 페이지를 요청합니다.']);
    if(sum(d,'bot_google',w)===0)a.push(['warn','구글 로봇이 7일 동안 페이지를 하나도 가져가지 않았습니다','서치콘솔에 사이트가 등록돼 있는지, 사이트맵이 제출됐는지 확인합니다.']);
    else if(s.crawl.google/s.total<.05&&d.length>=14)a.push(['warn',`구글 수집률이 ${pct(s.crawl.google,s.total)}로 낮습니다`,'서치콘솔 "페이지" 보고서에서 "크롤링됨 - 색인 안 됨" 비율을 봅니다. 높으면 구글이 읽은 페이지를 받아 주지 않는 것입니다.']);
    if(exact>=3&&sum(ex,'sm_naver',w)+sum(ex,'sm_google',w)===0)a.push(['warn','검색 로봇이 사이트맵을 읽어 간 기록이 없습니다','서치어드바이저와 서치콘솔에서 사이트맵을 다시 제출합니다.']);
    const rsc=sum(d,'rsc_naver',w),bn=sum(d,'bot_naver',w);if(rsc>=30&&rsc>bn*2)a.push(['info',`네이버 로봇이 페이지(${bn})보다 보조 파일(${rsc})을 더 많이 가져갑니다`,'하루 수집 한도가 낭비됩니다. robots.txt 에서 보조 파일(_rsc) 요청을 막는 것을 검토합니다.'])}
  if(exact>=14){const v1=sum(d,'visitors',w,y),v0=sum(d,'visitors',day(14),day(8));if(v0>=20&&v1<v0*.5)a.push(['warn',`방문자가 지난주 ${v0}명에서 이번 주 ${v1}명으로 줄었습니다`,'매체별 추이에서 어느 매체가 줄었는지 보고, 그 매체의 색인·노출 상태를 확인합니다.']);
    const e1=sum(d,'404',w,y),e0=sum(d,'404',day(14),day(8));if(e1>=50&&e1>e0*2)a.push(['warn',`없는 주소 요청이 ${e0}건에서 ${e1}건으로 늘었습니다`,'수집·색인 화면의 "없는 주소 요청 상위"에서 어떤 주소인지 보고, 지워진 페이지나 잘못 걸린 링크를 고칩니다.'])}
  return a}
const ALV={bad:['확인 필요','var(--bad)','#fdecea'],warn:['주의','#a4590a','#fdf0e3'],info:['참고','var(--mute)','#eceff3']};
const alertList=as=>as.map(x=>`<div class="al"><span class="lv" style="color:${ALV[x[0]][1]};background:${ALV[x[0]][2]}">${ALV[x[0]][0]}</span><div><b>${esc(x[1])}</b><div class="mute small">${esc(x[2])}</div></div></div>`).join('');
function check(){const t=D.today,y=day(1),G=(s,dd)=>s.days.find(x=>x.d===dd)||{};
  const all=D.sites.map(s=>[s,alerts(s)]),bad=all.filter(x=>x[1].length).sort((a,b)=>(b[1].filter(x=>x[0]==='bad').length-a[1].filter(x=>x[0]==='bad').length)||b[1].length-a[1].length);
  const two=(a,b)=>`<div>${a}</div><div class="mute small">어제 ${b}</div>`,n=v=>v?Number(v).toLocaleString('ko-KR'):'0';
  const dep=x=>x.deployed?`<span class="ok">했음</span>${x.deploy_at?' '+esc(x.deploy_at):''}`:(x.deployed===0?'<span class="zero">안 함</span>':'<span class="zero">기록 없음</span>');
  const open=(x,k,pk)=>`${n(x[k])}${x[pk]!=null?` <span class="${(x[k]||0)<x[pk]?'warn':'mute'} small">/ 계획 ${n(x[pk])}</span>`:''}`;
  const okc=c=>c===200||c===202,inow=(x,s,today)=>x.inow?`${n(x.inow)}개 <span class="${okc(x.inow_naver)&&(okc(x.inow_etc)||x.inow_etc==='')?'ok':'warn'} small">네이버 ${esc(x.inow_naver)} · 빙 ${esc(x.inow_etc)}</span>`:(today&&s.pending?`<span class="warn">대기 ${n(s.pending)}</span>`:'<span class="zero">보낼 것 없음</span>');
  const sm=x=>(x.sm_naver||x.sm_google)?`네이버 ${n(x.sm_naver)} · 구글 ${n(x.sm_google)}`:'<span class="zero">안 읽음</span>';
  topbar('오늘 점검',`${esc(t)} 기준 · 갱신 ${esc(D.updated)} · 오늘 값은 갱신 시각까지의 기록입니다`,'');
  main.innerHTML=`<div class="card full"><div class="chead"><h2>점검이 필요한 사이트 ${bad.length}곳</h2><span class="mute small">전체 ${D.sites.length}곳</span></div>
  ${bad.map(([s,as])=>`<div class="alsite"><a href="#/s/${esc(s.id)}"><b>${esc(s.name)}</b></a>${alertList(as)}</div>`).join('')||'<p class="ok" style="margin:0">모든 사이트가 정상입니다.</p>'}</div>
  <div class="card flush"><div class="chead" style="padding-bottom:14px"><div><h2>사이트별 오늘 한 일</h2><div class="mute small">칸마다 위는 오늘, 아래는 어제입니다. 줄을 누르면 그 사이트의 날짜별 작업 기록으로 갑니다. 색인 수는 서치콘솔을 연결하면 추가됩니다.</div></div></div><div class="scroll"><table>
  <tr><th>사이트</th><th class="l">배포</th><th class="l">${h('new_pages','열린 페이지')}</th><th class="l">${h('new_posts','발행 글')}</th><th class="l">${h('indexnow')}</th><th class="l">${h('smread')}</th><th class="l">${h('bot_naver')}</th><th class="l">${h('bot_google')}</th><th>경고</th></tr>
  ${all.map(([s,as])=>{const a=G(s,t),b=G(s,y);return `<tr class="row${s.preview?' pre':''}" data-go="#/s/${esc(s.id)}/log"><td>${esc(s.name)}${s.preview?'<span class="tag">미리보기</span>':''}</td><td class="l">${two(dep(a),dep(b))}</td><td class="l">${two(open(a,'new_pages','plan_pages'),open(b,'new_pages','plan_pages'))}</td><td class="l">${two(open(a,'new_posts','plan_posts'),open(b,'new_posts','plan_posts'))}</td><td class="l">${two(inow(a,s,1),inow(b,s,0))}</td><td class="l">${two(sm(a),sm(b))}</td><td class="l">${two(n(a.bot_naver),n(b.bot_naver))}</td><td class="l">${two(n(a.bot_google),n(b.bot_google))}</td><td>${as.length?`<span class="warn">${as.length}</span>`:'<span class="ok">없음</span>'}</td></tr>`}).join('')}</table></div></div>`}
function overview(){
  const live=D.sites.filter(s=>!s.preview),all=merge(live),y=day(1),w=day(7),t=D.today,ds=series(all,range);
  const tot=fn=>live.reduce((a,s)=>a+fn(s),0),dsum=(k,a,b)=>sum(all,k,a,b),bad=D.sites.filter(s=>alerts(s).length);
  const src={};live.forEach(s=>s.days.forEach(x=>{if(x.d>=w)for(const k in x)if(k.startsWith('src_'))src[k.slice(4)]=(src[k.slice(4)]||0)+x[k]}));
  topbar('전체 현황',`운영 사이트 ${live.length}곳${D.sites.length-live.length?` · 미리보기 ${D.sites.length-live.length}곳`:''} · 갱신 ${esc(D.updated)}`,seg('range',RNG,range));
  main.innerHTML=`${estNote(ds)}
  <div class="kpis k4">${kpi('visitors','users','c-visit',f(dsum('visitors',y,y)),delta(dsum('visitors',y,y),dsum('visitors',day(2),day(2))),'어제 방문자')}
  ${kpi('search','bot','c-search',f(dsum(searchOf,w,y)),delta(dsum(searchOf,w,y),dsum(searchOf,day(14),day(8))),'검색 유입 7일')}
  ${kpi('tel','phone','c-ink',f(dsum('tel',w)),'최근 7일','전화 클릭 7일')}
  ${kpi('total','file','c-ink',f(tot(s=>s.total)),`전체 제작 ${tot(made).toLocaleString('ko-KR')}`)}
  ${kpi('new_pages','plus','c-ink',f(dsum('new_pages',t,t)),`오늘 발행 글 ${dsum('new_posts',t,t).toLocaleString('ko-KR')}`)}
  ${kpi('bot_naver','bot','c-naver',f(dsum('bot_naver',y,y)),`7일 ${dsum('bot_naver',w,y).toLocaleString('ko-KR')}`,'어제 네이버 수집')}
  ${kpi('bot_google','bot','c-google',f(dsum('bot_google',y,y)),`7일 ${dsum('bot_google',w,y).toLocaleString('ko-KR')}`,'어제 구글 수집')}
  ${kpi('health',bad.length?'alert':'eye',bad.length?'c-bad':'c-naver',bad.length?`<span class="warn">${bad.length}곳</span>`:'정상',bad.length?'<a href="#/check">어떤 사이트인지 보기</a>':'전체 이상 없음','점검 필요')}</div>
  <div class="grid3"><div class="card"><div class="chead"><h2>방문자와 검색 유입</h2>${legend(VS)}</div><div class="chart" id="c1"></div>${dayTable(ds,[['방문자','visitors'],['방문','visits'],['검색 유입',searchOf],['전화 클릭','tel']])}</div>
  <div class="card"><div class="chead"><h2>${h('src')} <span class="mute small">최근 7일</span></h2></div>${donut(src)}</div></div>
  <div class="card full"><div class="chead"><h2>검색 로봇 수집</h2>${legend(BS)}</div><div class="chart" id="c2"></div>${dayTable(ds,[['네이버','bot_naver'],['구글','bot_google'],['수집 낭비','rsc_naver']])}</div>
  <div class="card flush"><div class="chead" style="padding-bottom:14px"><h2>사이트별</h2><div class="filters"><input id="sq" type="search" placeholder="사이트 찾기" aria-label="사이트 찾기" value="${esc(query)}"></div></div><div class="scroll"><table id="st"></table></div></div>
  <p class="mute small" style="margin-top:10px">줄을 누르면 그 사이트로 갑니다. 표 머리를 누르면 그 값으로 정렬됩니다. 점선 밑줄이 있는 이름에 마우스를 올리면 뜻이 나옵니다.</p>`;
  siteRows();$('#sq').oninput=e=>{query=e.target.value;siteRows()};
  $('#st').onclick=e=>{const th=e.target.closest('th[data-sort]');if(th){const i=+th.dataset.sort;if(i===sortK)sortDir=-sortDir;else{sortK=i;sortDir=i?-1:1}siteRows()}};
  charts.length=0;charts.push(()=>lineChart($('#c1'),ds,VS),()=>lineChart($('#c2'),ds,BS));draw()}

const TABS=[['','개요','pulse'],['visits','방문 기록','users'],['crawl','수집·색인','bot'],['publish','공개·발행','cal'],['log','작업 기록','book']];
async function site(id,tab){
  const s=cache[id]||(cache[id]=await api('site/'+id));if(!s)return;
  const d=s.days,y=day(1),w=day(7),t=D.today,W=win==7?s.w7:s.w14,bad=Object.entries(s.health||{}),ds=series(d,range);
  const age=s.created?Math.floor((new Date(t)-new Date(s.created))/864e5):null;
  topbar(s.name+(s.preview?' (미리보기)':''),TABS.find(x=>x[0]===tab)[1]+' · 갱신 '+esc(s.updated),tab==='visits'?'':seg('range',RNG,range));
  let body='';charts.length=0;
  if(!tab){
    const mt=c=>MED.reduce((a,m)=>a+(c[m[0]]||0),0),sv=c=>lsort==='all'?mt(c):(c[lsort]||0),mth=MED.map(m=>`<th data-ls="${m[0]}"><i class="sw2" style="background:${m[2]}"></i>${m[1]}<span class="ar">${lsort===m[0]?'▾':''}</span></th>`).join(''),mtd=c=>MED.map(m=>`<td>${f(c[m[0]])}</td>`).join('');
    const land=W.land.slice().sort((a,b)=>sv(b[2])-sv(a[2])).filter(p=>sv(p[2])>0),msum={};W.land.forEach(p=>MED.forEach(m=>{const n=p[2][m[0]]||0;if(n&&(!msum[m[0]]||n>msum[m[0]][1]))msum[m[0]]=[p[0],n]}));
    const mtotal=MED.map(m=>[m,m[0]==='naver'?(W.src.naver||0):m[0]==='google'?(W.src.google||0):m[0]==='search_etc'?(W.src.daum||0)+(W.src.bing||0):m[0]==='naver_etc'?['naver_blog','naver_place','naver_cafe','naver_etc'].reduce((a,k)=>a+(W.src[k]||0),0):m[0]==='direct'?(W.src.direct||0):['site','sns','kakao'].reduce((a,k)=>a+(W.src[k]||0),0)]),mall=mtotal.reduce((a,x)=>a+x[1],0);
    body=`<div class="kpis">${kpi('visitors','users','c-visit',f(sum(d,'visitors',w,y)),delta(sum(d,'visitors',w,y),sum(d,'visitors',day(14),day(8))),'방문자 7일')}
    ${kpi('search','bot','c-search',f(sum(d,searchOf,w,y)),delta(sum(d,searchOf,w,y),sum(d,searchOf,day(14),day(8))),'검색 유입 7일')}
    ${kpi('tel','phone','c-ink',f(sum(d,'tel',w)),`카톡 ${sum(d,'kakao',w).toLocaleString('ko-KR')}`,'전화 클릭 7일')}
    ${kpi('total','file','c-ink',f(s.total),`전체 제작 ${made(s).toLocaleString('ko-KR')}`)}
    ${kpi('cov_naver','bot','c-naver',pct(s.crawl.naver,s.total),`${s.crawl.naver.toLocaleString('ko-KR')} / ${s.total.toLocaleString('ko-KR')}`)}
    ${kpi('cov_google','bot','c-google',pct(s.crawl.google,s.total),`${s.crawl.google.toLocaleString('ko-KR')} / ${s.total.toLocaleString('ko-KR')}`)}</div>
    <div class="grid3"><div class="card"><div class="chead"><h2>방문자와 검색 유입</h2>${legend(VS)}</div><div class="chart" id="c1"></div>${dayTable(ds,[['방문자','visitors'],['방문','visits'],['조회','views'],['검색 유입',searchOf],['전화 클릭','tel']])}</div>
    <div class="card"><div class="chead"><h2>${h('src')}</h2>${seg('win',[[7,'7일'],[14,'14일']],win)}</div>${donut(W.src)}</div></div>
    <div class="grid3"><div class="card"><div class="chead"><h2>매체별 방문 추이</h2>${legend(MS)}</div><div class="chart" id="c3"></div>${dayTable(ds,MS.map(x=>[x.t,x.k]))}</div>
    <div class="card flush"><div class="chead"><h2>매체별 요약</h2><span class="mute small">최근 ${win}일</span></div><div class="scroll"><table><tr><th>매체</th><th>방문</th><th>비율</th><th class="l">가장 많이 들어온 페이지</th></tr>${mtotal.map(([m,n])=>`<tr><td><i class="sw2" style="background:${m[2]}"></i>${m[1]}</td><td>${f(n)}</td><td>${pct(n,mall)}</td><td class="l wrap">${msum[m[0]]?plink(s,msum[m[0]][0])+` <span class="mute small">${msum[m[0]][1]}</span>`:'<span class="zero">-</span>'}</td></tr>`).join('')}</table></div></div></div>
    <div class="card flush full"><div class="chead"><div><h2>${h('land')} · 매체별</h2><div class="mute small">최근 ${win}일 · 매체 이름을 누르면 그 매체로 많이 들어온 순서로 바뀝니다</div></div>${lsort==='all'?'':'<button type="button" class="morebtn" style="width:auto;border:1px solid var(--line);border-radius:10px;padding:6px 12px" data-ls="all">전체 순서로</button>'}</div>${tbl(`<th>페이지</th><th>유형</th><th data-ls="all">전체<span class="ar">${lsort==='all'?'▾':''}</span></th>${mth}`,land.map(p=>`<tr><td class="wrap">${plink(s,p[0])}</td><td>${TYPE[p[1]]||''}</td><td><b>${f(mt(p[2]))}</b></td>${mtd(p[2])}</tr>`),'이 기간에 방문이 없습니다',10)}</div>
    <div class="grid2"><div class="card flush"><div class="chead"><div><h2>들어온 ${h('ptype')} · 매체별</h2><div class="mute small">공개된 주소: ${Object.entries(s.types).map(([k,v])=>`${TYPE[k]||k} ${v.toLocaleString('ko-KR')}`).join(' · ')}</div></div></div><div class="scroll"><table><tr><th>유형</th><th>전체</th>${MED.map(m=>`<th><i class="sw2" style="background:${m[2]}"></i>${m[1]}</th>`).join('')}</tr>${Object.entries(W.type).sort((a,b)=>mt(b[1])-mt(a[1])).map(([k,c])=>`<tr><td>${TYPE[k]||esc(k)}</td><td><b>${f(mt(c))}</b></td>${mtd(c)}</tr>`).join('')||'<tr><td class="mute l" colspan="8">이 기간에 방문이 없습니다</td></tr>'}</table></div></div>
    <div class="card"><div class="chead"><h2>시간대별 조회</h2><span class="mute small">최근 14일</span></div><div class="chart" id="c2"></div></div></div>
    <div class="grid2"><div class="card"><div class="chead"><h2>기기</h2><span class="mute small">최근 ${win}일</span></div>${hbars(Object.entries(W.dev).sort((a,b)=>b[1]-a[1]),'이 기간에 방문이 없습니다')}</div>
    <div class="card"><div class="chead"><h2>링크를 걸어 준 곳</h2><span class="mute small">최근 ${win}일</span></div>${hbars(W.ref,'다른 사이트에서 넘어온 방문이 없습니다')}${W.kw.length?`<div class="chead" style="margin-top:18px"><h2>${h('kw')}</h2></div>${hbars(W.kw.map(k=>[k[0],k[2],(SRC[k[1]]||k[1]).replace(' 검색','')]))}`:''}</div></div>
    <div class="card flush"><div class="chead"><h2>많이 본 페이지</h2><span class="mute small">최근 14일</span></div>${tbl(`<th>페이지</th><th>유형</th><th>${h('views')}</th>`,s.top.map(p=>`<tr><td class="wrap">${plink(s,p[0])}</td><td>${TYPE[p[2]]||''}</td><td>${f(p[1])}</td></tr>`),'자료 없음')}</div>`;
    charts.push(()=>lineChart($('#c1'),ds,VS),()=>lineChart($('#c3'),ds,MS),()=>barChart($('#c2'),s.hours,'조회'));
  }else if(tab==='visits'){
    const srcs=[...new Set(s.visits.map(v=>v.src))];
    body=`<div class="card flush"><div class="chead" style="padding-bottom:14px"><div><h2>최근 방문 ${s.visits.length.toLocaleString('ko-KR')}건</h2><div class="mute small">${h('visits','방문')} 한 건은 한 사람이 이어서 본 묶음입니다. 줄을 누르면 본 순서가 펼쳐집니다. IP는 끝자리를 가렸습니다.</div></div>
    <div class="filters"><select id="fsrc" aria-label="유입 경로"><option value="">유입 경로 전체</option>${srcs.map(k=>`<option value="${esc(k)}">${esc(SRC[k]||k)}</option>`).join('')}</select>
    <select id="ftel" aria-label="전화 클릭"><option value="">전체</option><option value="1">전화·카톡 누른 방문만</option></select><input id="fq" type="search" placeholder="페이지·검색어 찾기" aria-label="찾기"></div></div><div class="scroll"><table id="vt"></table></div></div>`;
  }else if(tab==='crawl'){
    const i=s.indexnow;
    body=`<div class="kpis">${kpi('bot_naver','bot','c-naver',f(sum(d,'bot_naver',y,y)),`7일 ${sum(d,'bot_naver',w,y).toLocaleString('ko-KR')}`,'어제 네이버 수집')}${kpi('bot_google','bot','c-google',f(sum(d,'bot_google',y,y)),`7일 ${sum(d,'bot_google',w,y).toLocaleString('ko-KR')}`,'어제 구글 수집')}
    ${kpi('cov_naver','eye','c-naver',pct(s.crawl.naver,s.total),`${s.crawl.naver.toLocaleString('ko-KR')} / ${s.total.toLocaleString('ko-KR')}`)}${kpi('cov_google','eye','c-google',pct(s.crawl.google,s.total),`${s.crawl.google.toLocaleString('ko-KR')} / ${s.total.toLocaleString('ko-KR')}`)}
    ${kpi('rsc','ban','c-search',f(sum(d,'rsc_naver',w,y)),'최근 7일','수집 낭비 7일')}${kpi('e404','alert','c-bad',f(sum(d,'404',w,y)),'최근 7일','없는 주소 요청 7일')}</div>
    <div class="card full"><div class="chead"><h2>검색 로봇 수집</h2>${legend(BS)}</div><div class="chart" id="c1"></div>${dayTable(ds,[['네이버','bot_naver'],['구글','bot_google'],['빙','bot_bing'],['다음','bot_daum'],['AI 로봇','bot_ai'],['수집 낭비','rsc_naver'],['404','404']])}</div>
    <div class="grid2"><div class="card flush"><div class="chead"><h2>사이트맵 묶음별 수집률</h2></div>${tbl('<th>묶음</th><th>주소</th><th>네이버</th><th>구글</th>',s.parts.map(p=>`<tr><td>${esc(p[0])}</td><td>${f(p[1])}</td><td>${f(p[2])} <span class="mute small">${pct(p[2],p[1])}</span></td><td>${f(p[3])} <span class="mute small">${pct(p[3],p[1])}</span></td></tr>`),'묶음 없음',12)}</div>
    <div class="card"><div class="chead"><h2>${h('indexnow')}</h2></div><p style="margin:0">${i?`마지막 전송 ${esc(i.date)} · ${f(i.count)}개<br>네이버 응답 ${esc(i.naver??'-')} · 빙 쪽 응답 ${esc(i.indexnow??'-')} <span class="mute small">(200·202면 접수)</span>`:'전송 기록이 없습니다'}<br>보낼 차례를 기다리는 주소 ${f(s.pending)}개</p>
    <div class="chead" style="margin-top:18px"><h2>${h('health')}</h2></div><p style="margin:0">${bad.length?bad.map(([k,v])=>`<span class="warn">${esc(k)} ${v}건</span>`).join(' · '):'<span class="ok">이상 없음</span>'}</p>
    <div class="chead" style="margin-top:18px"><h2>${h('e404')} 상위</h2><span class="mute small">최근 14일</span></div>${hbars(s.e404,'없는 주소 요청이 없습니다','var(--bad)')}</div></div>`;
    charts.push(()=>lineChart($('#c1'),ds,BS));
  }else if(tab==='log'){
    const n=v=>v?Number(v).toLocaleString('ko-KR'):'<span class="zero">0</span>',okc=c=>c===200||c===202;
    body=`<div class="card flush"><div class="chead" style="padding-bottom:14px"><div><h2>날짜별 작업 기록</h2><div class="mute small">그날 실제로 된 일입니다. 계획은 일정 파일에 있던 수이고, 대시보드가 그 일정을 본 날부터 기록됩니다. 마지막 반영 ${esc(s.last_deploy||'알 수 없음')}</div></div></div><div class="scroll"><table>
    <tr><th>날짜</th><th class="l">배포</th><th>열린 페이지</th><th>계획</th><th>발행 글</th><th>계획</th><th class="l">${h('indexnow')}</th><th>${h('smread','사이트맵 읽어감 네이버')}</th><th>구글</th><th>${h('bot_naver')}</th><th>${h('bot_google')}</th></tr>
    ${ds.slice().reverse().map(x=>`<tr><td>${x.d}${x.est?'<span class="tag">추정</span>':''}</td><td class="l">${x.deployed?`<span class="ok">했음</span> ${esc(x.deploy_at||'')}`:(x.deployed===0?'<span class="zero">안 함</span>':'<span class="zero">-</span>')}</td><td>${n(x.new_pages)}</td><td>${x.plan_pages!=null?n(x.plan_pages):'<span class="zero">-</span>'}</td><td>${n(x.new_posts)}</td><td>${x.plan_posts!=null?n(x.plan_posts):'<span class="zero">-</span>'}</td><td class="l">${x.inow?`${n(x.inow)}개 <span class="${okc(x.inow_naver)?'ok':'warn'} small">네이버 ${esc(x.inow_naver)} · 빙 ${esc(x.inow_etc)}</span>`:'<span class="zero">-</span>'}</td><td>${n(x.sm_naver)}</td><td>${n(x.sm_google)}</td><td>${n(x.bot_naver)}</td><td>${n(x.bot_google)}</td></tr>`).join('')}</table></div></div>`;
  }else{
    const dd=ds.slice().reverse();
    body=`<div class="kpis">${kpi('made','file','c-ink',f(made(s)))}${kpi('total','eye','c-naver',f(s.total),`페이지 ${s.pages.toLocaleString('ko-KR')} · 글 ${s.posts.toLocaleString('ko-KR')}`)}${kpi('left','cal','c-search',f(s.left_pages+s.left_posts),`페이지 ${s.left_pages.toLocaleString('ko-KR')} · 글 ${s.left_posts.toLocaleString('ko-KR')}`)}
    ${kpi('new_pages','plus','c-visit',f(sum(d,'new_pages',t,t)),`7일 ${sum(d,'new_pages',w).toLocaleString('ko-KR')}`)}${kpi('new_posts','plus','c-google',f(sum(d,'new_posts',t,t)),`7일 ${sum(d,'new_posts',w).toLocaleString('ko-KR')}`)}</div>
    <div class="grid2"><div class="card flush"><div class="chead"><h2>날짜별 공개 기록</h2></div>${tbl('<th>날짜</th><th>열린 페이지</th><th>발행 글</th><th>공개 페이지 누계</th><th>공개 글 누계</th>',dd.map(x=>`<tr><td>${x.d}</td><td>${f(x.new_pages)}</td><td>${f(x.new_posts)}</td><td>${x.pages!=null?f(x.pages):'<span class="zero">-</span>'}</td><td>${x.posts!=null?f(x.posts):'<span class="zero">-</span>'}</td></tr>`),'기록 없음',10)}</div>
    <div class="card flush"><div class="chead"><h2>남은 일정</h2></div>${tbl('<th>날짜</th><th>열릴 페이지</th><th>발행될 글</th>',(s.schedule||[]).map(x=>`<tr><td>${esc(x.date)}</td><td>${f(x.pages)}</td><td>${f(x.posts)}</td></tr>`),'예약된 일정이 없습니다',10)}</div></div>
    <p class="mute small">누계는 대시보드가 이 사이트를 보기 시작한 날부터 기록됩니다.</p>`;
  }
  main.innerHTML=`<div class="sitehead"><span>${ic('globe')}</span><a href="https://${esc(s.host)}/" target="_blank" rel="noopener noreferrer">${esc(s.name)}</a><span>${h('created')} ${s.created?esc(s.created)+` · ${age.toLocaleString('ko-KR')}일째`:'확인 안 됨'}</span><span>공개 주소 ${s.total.toLocaleString('ko-KR')}</span></div>
  ${(as=>as.length?`<div class="card full" style="border-color:#f3c9c4"><div class="chead"><h2>이 사이트에서 확인할 것 ${as.length}건</h2></div>${alertList(as)}</div>`:'')(alerts(s))}
  <nav class="tabs">${TABS.map(x=>`<a href="#/s/${esc(id)}${x[0]?'/'+x[0]:''}" class="${tab===x[0]?'on':''}">${x[1]}</a>`).join('')}</nav>${tab==='visits'?'':estNote(ds)}${body}`;
  if(tab==='visits'){const paint=()=>{const fs=$('#fsrc').value,ft=$('#ftel').value,q=$('#fq').value.trim();
      const rows=s.visits.filter(v=>(!fs||v.src===fs)&&(!ft||v.tel||v.kakao)&&(!q||(v.land+' '+v.kw+' '+v.pages.join(' ')+' '+v.ref).includes(q)));
      $('#vt').innerHTML=`<tr><th class="l">시각</th><th class="l">어디서</th><th class="l">처음 본 페이지</th><th>본 쪽수</th><th class="l">기기</th><th class="l">전화·카톡</th><th class="l">IP</th></tr>`+(rows.map((v,i)=>`<tr class="row" data-v="${i}"><td class="l">${esc(v.t)}</td><td class="l">${esc(SRC[v.src]||v.src)}${v.kw?` <span class="mute">“${esc(v.kw)}”</span>`:v.ref&&!['naver','google','daum','bing'].includes(v.src)?` <span class="mute">${esc(v.ref)}</span>`:''}</td><td class="l wrap">${esc(v.land)}</td><td>${v.n}</td><td class="l">${esc(v.dev)}</td><td class="l">${v.tel?'<span class="ok">전화</span>':''}${v.tel&&v.kakao?' · ':''}${v.kakao?'<span class="ok">카톡</span>':''}</td><td class="l mute">${esc(v.ip)}</td></tr>`).join('')||'<tr><td class="mute l" colspan="7">조건에 맞는 방문이 없습니다</td></tr>');
      $('#vt').onclick=e=>{const tr=e.target.closest('tr.row');if(!tr)return;const nx=tr.nextElementSibling;if(nx&&nx.classList.contains('tr2')){nx.remove();return}
        const v=rows[tr.dataset.v],r=document.createElement('tr');r.className='tr2';r.innerHTML=`<td colspan="7" class="trail"><span>본 순서</span> ${v.pages.map(p=>esc(p)).join(' <span>→</span> ')}${v.n>v.pages.length?` <span>외 ${v.n-v.pages.length}쪽</span>`:''}</td>`;tr.after(r)}};
    ['fsrc','ftel','fq'].forEach(i=>$('#'+i).oninput=paint);paint()}
  draw()}

function help(){const groups=[['방문',['visitors','visits','views','search','src','land','kw','ptype','tel']],['공개·발행',['total','made','left','new_pages','new_posts']],['수집·색인',['bot_naver','bot_google','cov_naver','cov_google','rsc','e404','indexnow','health']],['기타',['est','created']]];
  topbar('용어 설명','화면에 나오는 숫자의 뜻과 계산 방법','');
  main.innerHTML=groups.map(g=>`<div class="card full"><div class="chead"><h2>${g[0]}</h2></div><dl class="gloss">${g[1].map(k=>`<dt>${esc(HELP[k][0])}</dt><dd>${esc(HELP[k][1])}</dd>`).join('')}</dl></div>`).join('')
  +`<div class="card full"><div class="chead"><h2>자료가 어디서 오는지</h2></div><p style="margin:0">모든 숫자는 서버의 접속 기록과 각 사이트의 사이트맵에서 계산합니다. 하루 두 번(7시 30분, 15시 30분) 갱신합니다. 검색 순위, 검색량, 백링크는 서버 기록으로 알 수 없어 넣지 않았습니다. 구글 순위와 클릭 수는 서치콘솔을 연결하면 추가할 수 있습니다.</p></div>`}
function account(){topbar('비밀번호 변경','바꾸면 다른 기기의 로그인은 모두 풀립니다','');
  main.innerHTML=`<div class="card"><form class="form" id="pf"><label>지금 비밀번호<input type="password" name="old" required autocomplete="current-password"></label><label>새 비밀번호 (8자 이상)<input type="password" name="new" required minlength="8" autocomplete="new-password"></label><button class="btn">바꾸기</button><p id="pm" class="small" role="status"></p></form></div>`;
  $('#pf').onsubmit=async e=>{e.preventDefault();const fd=new FormData(e.target),r=await fetch('/api/password',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({old:fd.get('old'),new:fd.get('new')})}),j=await r.json().catch(()=>({}));
    $('#pm').textContent=r.ok?'바꿨습니다.':(j.error||'바꾸지 못했습니다');if(r.ok)e.target.reset()}}

async function api(p){const r=await fetch('/api/'+p,{cache:'no-store'});if(r.status===401){location.href='/login';return null}if(!r.ok){main.innerHTML=`<p class="warn">자료를 불러오지 못했습니다 (${r.status}). 수집이 아직 한 번도 돌지 않았을 수 있습니다.</p>`;return null}return r.json()}
/* 위쪽 막대: 사이트 고르기(누르면 찾기 창) + 제목 + 기간 */
function topbar(title,sub,right){const cur=(location.hash||'#/').slice(2).split('/'),sid=cur[0]==='s'?cur[1]:'',now=D.sites.find(s=>s.id===sid),y=day(1);
  const item=s=>`<a href="#/s/${esc(s.id)}${cur[0]==='s'&&cur[2]?'/'+esc(cur[2]):''}" class="${s.id===sid?'on':''}" data-n="${esc((s.name+' '+s.host).toLowerCase())}"><span>${esc(s.name)}</span><span title="어제 방문자">${sum(s.days,'visitors',y,y).toLocaleString('ko-KR')}</span></a>`;
  const live=D.sites.filter(s=>!s.preview).sort((a,b)=>sum(b.days,'visitors',y,y)-sum(a.days,'visitors',y,y)),pre=D.sites.filter(s=>s.preview);
  $('#top').innerHTML=`<div class="sw"><button type="button" class="swbtn" id="swb" aria-haspopup="true" aria-expanded="false">${ic('globe')}<b>${now?esc(now.name):'전체 사이트'}</b>${ic('down')}</button>
  <div class="pop" id="pop"><input id="pq" type="search" placeholder="사이트 이름으로 찾기" aria-label="사이트 찾기"><div class="list"><a href="#/" class="${sid?'':'on'}" data-n="전체 현황 all"><span>전체 현황</span><span>${D.sites.length}곳</span></a>
  <div class="g">운영 사이트 · 어제 방문자</div>${live.map(item).join('')}${pre.length?`<div class="g">미리보기</div>${pre.map(item).join('')}`:''}</div></div></div>
  <div class="grow"><h1>${esc(title)}</h1><div class="mute small">${sub}</div></div>${right||''}`;
  const pop=$('#pop'),btn=$('#swb'),open=o=>{pop.classList.toggle('open',o);btn.setAttribute('aria-expanded',o);if(o){$('#pq').value='';filt();$('#pq').focus()}};
  const filt=()=>{const q=$('#pq').value.trim().toLowerCase();pop.querySelectorAll('a').forEach(a=>a.style.display=!q||a.dataset.n.includes(q)?'':'none');pop.querySelectorAll('.g').forEach(g=>g.style.display=q?'none':'')};
  btn.onclick=e=>{e.stopPropagation();open(!pop.classList.contains('open'))};pop.onclick=e=>{e.stopPropagation();if(e.target.closest('a'))open(false)};
  $('#pq').oninput=filt;$('#pq').onkeydown=e=>{if(e.key==='Enter'){const a=[...pop.querySelectorAll('a')].find(a=>a.style.display!=='none');if(a){location.hash=a.getAttribute('href');open(false)}}if(e.key==='Escape')open(false)}}
function nav(){const cur=(location.hash||'#/').slice(2).split('/'),sid=cur[0]==='s'?cur[1]:'',tab=cur[2]||'';
  const a=(href,icon,label,on)=>`<a href="${href}" class="${on?'on':''}">${ic(icon)}<span>${label}</span></a>`;
  $('#side').innerHTML=`<div class="brand"><i>${ic('pulse')}</i>운영 현황</div>${a('#/','grid','전체 현황',!cur[0])}${a('#/check','alert','오늘 점검'+(n=>n?` <span class="tag" style="background:var(--bad);color:#fff">${n}</span>`:'')(D.sites.filter(s=>alerts(s).length).length),cur[0]==='check')}
  ${sid?`<div class="grp">이 사이트</div>${TABS.map(x=>a(`#/s/${esc(sid)}${x[0]?'/'+x[0]:''}`,x[2],x[1],tab===x[0])).join('')}`:`<div class="grp">사이트</div><button type="button" class="nav" id="pick">${ic('globe')}<span>사이트 고르기</span></button>`}
  <div class="sp"></div>${a('#/help','book','용어 설명',cur[0]==='help')}${a('#/account','key','비밀번호 변경',cur[0]==='account')}<form method="post" action="/logout"><button class="nav">${ic('out')}<span>로그아웃</span></button></form>`;
  const p=$('#pick');if(p)p.onclick=e=>{e.stopPropagation();$('#swb').click()}}
async function route(){if(!D){D=await api('data');if(!D)return}const p=(location.hash||'#/').slice(2).split('/');tip.style.display='none';
  if(p[0]==='s'&&D.sites.some(s=>s.id===p[1]))await site(p[1],TABS.some(x=>x[0]===p[2])?p[2]:'');else if(p[0]==='check')check();else if(p[0]==='help')help();else if(p[0]==='account')account();else overview();nav()}
addEventListener('hashchange',()=>route().then(()=>scrollTo(0,0)));
let rt;addEventListener('resize',()=>{clearTimeout(rt);rt=setTimeout(draw,150)});
document.addEventListener('click',e=>{const pop=$('#pop');if(pop&&pop.classList.contains('open'))pop.classList.remove('open');
  const b=e.target.closest('[data-seg] button');if(b){const n=b.parentNode.dataset.seg;if(n==='range')range=+b.dataset.v;else win=+b.dataset.v;const y=scrollY;route().then(()=>scrollTo(0,y));return}
  const ls=e.target.closest('[data-ls]');if(ls){lsort=ls.dataset.ls;const y=scrollY;route().then(()=>scrollTo(0,y));return}
  const m=e.target.closest('.morebtn');if(m){const o=m.parentNode.classList.toggle('open');m.textContent=o?'접기':`전체 ${m.dataset.more}줄 보기`;return}
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

[ -f /var/lib/seo-dash/push_token ] || { openssl rand -hex 24 > /var/lib/seo-dash/push_token; chmod 600 /var/lib/seo-dash/push_token; }   # 다른 서버 수집기가 결과를 올릴 때 쓰는 토큰

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

# 4) 대시보드 주소 — 도메인 없이 서버 IP 의 포트 하나로 연다 (예전 도메인 설정은 이 파일로 바뀐다)
NG=/etc/nginx/sites-available/seo-dash
OTHER=$(grep -lE "server_name[^;]* seo.jd8.co.kr( |;)" /etc/nginx/sites-enabled/* 2>/dev/null | grep -v "/seo-dash$" || true)
[ -z "$OTHER" ] || { echo "!! 같은 주소(포트)를 이미 쓰는 nginx 설정이 있음: $OTHER"; exit 1; }
[ -f "$NG" ] && cp "$NG" /root/seo-dash.nginx.bak
cat > "$NG" <<'EOF'
server {
    listen 80;
    server_name seo.jd8.co.kr;
    add_header X-Robots-Tag "noindex, nofollow" always;
    location / { proxy_pass http://127.0.0.1:8791; proxy_set_header Host $http_host; proxy_set_header X-Real-IP $remote_addr; proxy_set_header X-Forwarded-Proto $scheme; }
}
EOF
ln -sf "$NG" /etc/nginx/sites-enabled/seo-dash
if nginx -t; then systemctl reload nginx
else
  [ -f /root/seo-dash.nginx.bak ] && cp /root/seo-dash.nginx.bak "$NG" || rm -f /etc/nginx/sites-enabled/seo-dash
  rm -f /etc/nginx/conf.d/vhostlog.conf; echo "!! nginx 설정 오류 — 추가한 설정을 되돌림"; exit 1
fi
grep -q "ssl" "$NG" || certbot --nginx -d seo.jd8.co.kr --agree-tos --register-unsafely-without-email --redirect -n || echo "(HTTPS 발급 실패 — http 로 사용)"
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
echo "대시보드: $(grep -q ssl "$NG" && echo https || echo http)://seo.jd8.co.kr/"
echo "아이디 admin / 처음 비밀번호는 /root/seo-dash-password.txt (화면에서 바꾸면 그 파일은 옛 값이 된다)"
