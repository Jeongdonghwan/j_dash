"""대시보드 서버 설치 스크립트 생성 — dash.py·dash.html 을 heredoc 으로 묶은 bash 파일 하나를 만든다.

  python -I make_install.py <출력 .sh 경로> [대시보드 호스트=ops.172.237.20.244.sslip.io]

서버에서: bash install-seo-dash.sh  (여러 번 돌려도 된다 — 비밀번호는 처음 한 번만 만든다)
"""
import os, sys

here = os.path.dirname(os.path.abspath(__file__))
rd = lambda p: open(os.path.join(here, p), encoding='utf-8').read().replace('\r\n', '\n')
host = sys.argv[2] if len(sys.argv) > 2 else 'ops.172.237.20.244.sslip.io'
sh = r'''#!/usr/bin/env bash
# SEO 대시보드 설치 (nginx 정적 사이트 서버). 다시 돌리면 스크립트·화면만 새로 깔린다.
set -euo pipefail
mkdir -p /opt/seo-dash /var/www/seo-dash /var/lib/seo-dash

cat > /opt/seo-dash/dash.py <<'DASH_PY_EOF'
__DASH_PY__
DASH_PY_EOF

cat > /var/www/seo-dash/index.html <<'DASH_HTML_EOF'
__DASH_HTML__
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
    server_name __HOST__;
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
grep -q "ssl" /etc/nginx/sites-available/seo-dash || certbot --nginx -d __HOST__ --agree-tos --register-unsafely-without-email --redirect -n || echo "(HTTPS 발급 실패 — http 로 사용)"

# 4) 하루 두 번 갱신 (서버가 deploy 브랜치를 받은 뒤)
echo '30 7,15 * * * root /usr/bin/python3 /opt/seo-dash/dash.py --indexnow >> /var/log/seo-dash.log 2>&1' > /etc/cron.d/seo-dash

# 5) deploy 브랜치를 자동으로 받지 않는 사이트 확인
echo "== 자동 받기(cron)가 없는 사이트 폴더"
for d in /var/www/*/; do d=${d%/}; [ -d "$d/.git" ] && [ -f "$d/sitemap.xml" ] && ! crontab -l 2>/dev/null | grep -q "cd $d " && echo "  $d"; done; true

# 6) 첫 실행 (열려 있는 주소를 IndexNow 로 한 번 보낸다)
echo "== 첫 실행"
python3 /opt/seo-dash/dash.py --indexnow | tee -a /var/log/seo-dash.log
echo
echo "대시보드: http://__HOST__/  (https 발급됐으면 https)"
echo "아이디 admin / 비밀번호 $(cat /root/seo-dash-password.txt)"
'''
out = sh.replace('__DASH_PY__', rd('dash.py').rstrip('\n')).replace('__DASH_HTML__', rd('../assets/dash.html').rstrip('\n')).replace('__HOST__', host)
open(sys.argv[1], 'w', encoding='utf-8', newline='\n').write(out)
print(sys.argv[1], len(out.splitlines()), 'lines')
