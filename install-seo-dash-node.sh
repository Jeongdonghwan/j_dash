#!/usr/bin/env bash
# SEO 대시보드 — 다른 서버용 수집기 설치. 결과는 https://seo.jd8.co.kr 로 올린다. 다시 돌려도 된다.
set -euo pipefail
: "${DASH_PUSH_TOKEN:?DASH_PUSH_TOKEN=<토큰> 을 앞에 붙여 실행}"
mkdir -p /opt/seo-dash /var/lib/seo-dash/out /root/seo-dash-node-bak
chmod 700 /var/lib/seo-dash
printf '%s' "$DASH_PUSH_TOKEN" > /var/lib/seo-dash/push_token_node; chmod 600 /var/lib/seo-dash/push_token_node

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

# 1) 접속 기록에 사이트 이름을 남기는 파일 추가 (기존 기록은 그대로)
if grep -q "conf.d/\*.conf" /etc/nginx/nginx.conf; then
cat > /etc/nginx/conf.d/vhostlog.conf <<'EOF'
log_format vhost '$host $remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent"';
access_log /var/log/nginx/vhost.log vhost;
EOF
else echo "!! nginx.conf 가 conf.d 를 읽지 않음 — 중단"; exit 1; fi

# 2) 자기 access_log 를 따로 둔 정적 사이트 블록에는 vhost 기록을 한 줄 더한다 (그렇지 않으면 그 사이트만 빠진다)
python3 - <<'EOF'
import glob, os, re, shutil
for f in sorted(glob.glob('/etc/nginx/sites-enabled/*')):
    real = os.path.realpath(f); t = open(real, encoding='utf-8', errors='ignore').read(); out, pos, changed = '', 0, False
    for m in re.finditer(r'(^|\n)([ \t]*)server\s*\{', t):
        i, depth = m.end(), 1
        while i < len(t) and depth: depth += {'{': 1, '}': -1}.get(t[i], 0); i += 1
        blk = t[m.end():i]
        root = re.search(r'^[ \t]*root\s+([^;]+);', blk, re.M)
        own = re.search(r'^[ \t]*access_log\s+(?!off)', blk, re.M)
        if root and own and 'vhost.log' not in blk and os.path.isfile(root.group(1).strip().rstrip('/') + '/sitemap.xml'):
            at = m.end() + root.end()
            out += t[pos:at] + '\n' + re.match(r'[ \t]*', root.group(0)).group(0) + 'access_log /var/log/nginx/vhost.log vhost;'; pos = at; changed = True
    if changed:
        shutil.copy(real, '/root/seo-dash-node-bak/' + os.path.basename(real))
        open(real, 'w', encoding='utf-8').write(out + t[pos:]); print('vhost 기록 줄 추가:', real)
EOF
if nginx -t; then systemctl reload nginx
else
  echo "!! nginx 설정 오류 — 바꾼 파일을 되돌림"
  for b in /root/seo-dash-node-bak/*; do [ -f "$b" ] && cp "$b" "$(readlink -f /etc/nginx/sites-enabled/$(basename "$b") || echo /etc/nginx/sites-available/$(basename "$b"))"; done
  rm -f /etc/nginx/conf.d/vhostlog.conf; nginx -t && systemctl reload nginx; exit 1
fi

# 3) 하루 두 번 수집해서 대시보드로 올린다 (대시보드 서버가 7:30·15:30 에 합치므로 그보다 10분 먼저)
# DASH_ONLY="a.kr b.kr" 를 앞에 붙여 실행하면 그 호스트의 사이트만 잡는다(다시 설치할 때 안 주면 지난번 값을 그대로 쓴다)
[ -n "${DASH_ONLY:-}" ] && printf '%s' "$DASH_ONLY" > /var/lib/seo-dash/only
ONLY=$(cat /var/lib/seo-dash/only 2>/dev/null || true)
echo "20 7,15 * * * root DASH_ONLY=\"$ONLY\" /usr/bin/python3 /opt/seo-dash/dash.py --push https://seo.jd8.co.kr >> /var/log/seo-dash.log 2>&1" > /etc/cron.d/seo-dash

# 4) 첫 실행
echo "== 수집 실행 (대상: ${ONLY:-파일로 내주는 사이트 전부})"
DASH_ONLY="$ONLY" python3 /opt/seo-dash/dash.py --push https://seo.jd8.co.kr | tee -a /var/log/seo-dash.log
echo
echo "'대시보드로 올림' 줄에 {200: N} 이 나오면 연결된 것. 403 이면 토큰이 다름."
echo "대시보드 서버에서 한 번 더 수집을 돌리면 바로 보인다:  python3 /opt/seo-dash/dash.py"
