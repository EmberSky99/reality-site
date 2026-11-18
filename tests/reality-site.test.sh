#!/usr/bin/env bash
# 本地测试：不安装软件、不修改 systemd 或防火墙、不连接 VPS。
# 用法：bash tests/reality-site.test.sh /path/to/caddy /path/to/shellcheck
# Each subshell deliberately sets its own deployment globals for independent cases.
# shellcheck disable=SC2030,SC2031
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CADDY_BIN=${1:?请提供 Caddy 二进制路径}
SHELLCHECK_BIN=${2:?请提供 ShellCheck 二进制路径}
WORK=$(mktemp -d /tmp/reality-site-test.XXXXXXXX)
CADDY_PID=''
cleanup_test() {
    if [[ -n "$CADDY_PID" ]]; then kill "$CADDY_PID" 2>/dev/null || true; wait "$CADDY_PID" 2>/dev/null || true; fi
    rm -rf -- "$WORK"
}
trap cleanup_test EXIT
bash -n "$ROOT/reality-site.sh"
"$SHELLCHECK_BIN" --external-sources --source-path="$ROOT" "$ROOT/reality-site.sh" "$0"
source "$ROOT/reality-site.sh"

# Test platform selection without emulating an installed RPM/DEB system.
for entry in 'ubuntu|22.04|Ubuntu 22.04 LTS|apt' 'ubuntu|24.04|Ubuntu 24.04 LTS|apt' 'ubuntu|26.04|Ubuntu 26.04 LTS|apt' \
    'debian|12|Debian GNU/Linux 12|apt' 'debian|13|Debian GNU/Linux 13|apt' \
    'centos|9|CentOS Stream 9|dnf' 'centos|10|CentOS Stream 10|dnf' \
    'rocky|8.10|Rocky Linux 8.10|dnf' 'almalinux|8.10|AlmaLinux 8.10|dnf' 'rhel|8.10|RHEL 8.10|dnf' \
    'rocky|9.6|Rocky Linux 9.6|dnf' 'almalinux|10.0|AlmaLinux 10|dnf' 'rhel|9.5|RHEL 9.5|dnf'; do
    IFS='|' read -r os_id os_version os_name expected <<< "$entry"
    [[ $(platform_family "$os_id" "$os_version" "$os_name") == "$expected" ]]
done
for entry in 'centos|7|CentOS Linux 7' 'centos|8|CentOS Linux 8' \
    'centos|8|CentOS Stream 8' 'ubuntu|18.04|Ubuntu 18.04' 'alpine|3.22|Alpine Linux'; do
    IFS='|' read -r os_id os_version os_name <<< "$entry"
    if platform_family "$os_id" "$os_version" "$os_name" >/dev/null; then
        printf '错误：接受了未适配系统 %s %s\n' "$os_id" "$os_version"; exit 1
    fi
done
supported_arch x86_64
supported_arch aarch64
if supported_arch i686 || supported_arch riscv64; then printf '错误：接受了未适配架构\n'; exit 1; fi
printf 'PASS 发行版/版本及架构分支（不代表各系统完整安装已验证）\n'

(
    load_system_info() { ID=centos; VERSION_ID=7; PRETTY_NAME='CentOS Linux 7'; }
    # Exercise real deployment checks without requiring root/systemd locally.
    check_platform() { check_system_compatibility; }
    check_ownership() { printf reached > "$WORK/action-reached"; }
    for option in --deploy ''; do
        if output=$(main "$option" 2>&1); then printf '错误：未适配系统未被启动检查阻止\n'; exit 1; fi
        [[ "$output" == *版本不兼容* && "$output" == *'CentOS Linux 7'* ]]
        [[ ! -e "$WORK/action-reached" ]]
    done
    main --help >/dev/null
)
(
    load_system_info() { ID=debian; VERSION_ID=13; PRETTY_NAME='Debian GNU/Linux 13 (trixie)'; }
    uname() { if [[ ${1:-} == -m ]]; then printf i686; else printf Linux; fi; }
    check_platform() { check_system_compatibility; }
    if output=$(main --deploy 2>&1); then printf '错误：未适配架构未被启动检查阻止\n'; exit 1; fi
    [[ "$output" == *架构不兼容* && "$output" == *i686* ]]
)
(
    load_system_info() { ID=debian; VERSION_ID=13; PRETTY_NAME='Debian GNU/Linux 13 (trixie)'; }
    uname() { if [[ ${1:-} == -m ]]; then printf x86_64; else printf Linux; fi; }
    check_platform() { check_system_compatibility; }
    check_ownership() { printf 'supported-entry-reached'; exit 0; }
    [[ $(main --deploy) == supported-entry-reached ]]
)
printf 'PASS 启动检查：未适配版本/架构立即退出，支持系统可继续，帮助仍可查看\n'

(
    load_system_info() { ID=debian; VERSION_ID=13; PRETTY_NAME='Debian GNU/Linux 13 (trixie)'; }
    uname() { if [[ ${1:-} == -m ]]; then printf x86_64; else printf Linux; fi; }
    check_platform() {
        check_system_compatibility
        printf 'platform\n' >> "$WORK/startup-order"
    }
    check_ownership() { printf 'ownership\n' >> "$WORK/startup-order"; }
    ask_settings() {
        printf 'settings\n' >> "$WORK/startup-order"
        printf '网站域名（只填域名）：'
        exit 0
    }
    output=$(main)
    [[ $(cat "$WORK/startup-order") == $'platform\nownership\nsettings' ]]
    [[ "$output" == '网站域名（只填域名）：' ]]
)
printf 'PASS 默认运行：直接部署，系统与归属检查自动执行，无检查菜单或启动报告\n'

for name in example.com sub.example.com xn--example-9d0b.com; do
    valid_domain "$name" || { printf '域名被错误拒绝：%s\n' "$name"; exit 1; }
done
for name in localhost 127.0.0.1 'https://example.com' 'a..com' '-a.com' 'a-.com' 'a.com.' 'a.com;id' 'a.com{'; do
    if valid_domain "$name"; then printf '非法域名被接受：%s\n' "$name"; exit 1; fi
done
for port in 1024 8443 65535; do valid_port "$port"; done
for port in 80 443 2019 65536 '8443;id' 0000 08443 01024; do
    if valid_port "$port"; then printf '非法端口被接受：%s\n' "$port"; exit 1; fi
done
printf 'PASS 输入校验\n'

(
    MANAGED=0
    LOCAL_PORT=8443
    port_lines() {
        if [[ "$1" == 8443 ]]; then printf 'LISTEN 0 128 *:8443 *:* users:(("other",pid=24,fd=3))'; fi
    }
    [[ $(suggest_local_port 8443) == 9443 ]]
    ask_local_port <<< '' > "$WORK/port-recommendation.txt"
    [[ "$LOCAL_PORT" == 9443 ]]
    LOCAL_PORT=8443
    ask_local_port <<< 25443 > /dev/null
    [[ "$LOCAL_PORT" == 25443 ]]
    LOCAL_PORT=8443
    ask_local_port <<< $'8443\n9443' > /dev/null
    [[ "$LOCAL_PORT" == 9443 ]]
    MANAGED=1
    LOCAL_PORT=8443
    ask_local_port < /dev/null > /dev/null
    [[ "$LOCAL_PORT" == 8443 ]]
)
(
    port_lines() { return 1; }
    if output=$(suggest_local_port 8443 2>&1); then printf '错误：把端口检查失败当作空闲\n'; exit 1; fi
    [[ "$output" == *无法检查* ]]
)
printf 'PASS 内部端口：占用时推荐替代端口、允许自选、复用已有端口、检查失败停止\n'

(
    port_lines() { printf '%s' "${MOCK_LISTEN:-}"; }
    systemctl() { printf '%s\n' "${MOCK_MAIN_PID:-23}"; }
    MOCK_LISTEN='LISTEN 0 4096 *:80 *:* users:(("nginx",pid=22,fd=3))'
    MANAGED=0
    if (check_available) 2>/dev/null; then printf '错误：允许覆盖 nginx\n'; exit 1; fi
    MOCK_LISTEN='LISTEN 0 4096 *:80 *:* users:(("caddy",pid=23,fd=3))'
    if (check_available) 2>/dev/null; then printf '错误：允许接管其他 Caddy\n'; exit 1; fi
    MANAGED=1
    check_available
    MOCK_MAIN_PID=42
    if (check_available) 2>/dev/null; then printf '错误：仅凭同名Caddy复用了其他进程\n'; exit 1; fi
    MOCK_MAIN_PID=0
    if (check_available) 2>/dev/null; then printf '错误：主进程不存在仍复用监听\n'; exit 1; fi
    MOCK_MAIN_PID=23
    MOCK_LISTEN='LISTEN 0 4096 *:80 *:* users:(("caddy",pid=23,fd=3),("nginx",pid=24,fd=4))'
    if (check_available) 2>/dev/null; then printf '错误：漏掉同一监听上的其他PID\n'; exit 1; fi
    MOCK_LISTEN=$'LISTEN 0 4096 *:80 *:* users:(("caddy",pid=23,fd=3))\nLISTEN 0 4096 127.0.0.1:80 *:* users:(("nginx",pid=22,fd=3))'
    if (check_available) 2>/dev/null; then printf '错误：漏掉同端口其他进程\n'; exit 1; fi
    MOCK_LISTEN=''
    MANAGED=0
    check_available
)
printf 'PASS 端口占用：未知进程阻止，本脚本管理的 Caddy 允许\n'

(
    CONFIG="$WORK/owned-Caddyfile"
    STATE="$WORK/owned-state"
    WEBROOT="$WORK/webroot"
    printf 'test config\n' > "$CONFIG"
    printf 'domain=example.com\nlocal_port=8443\nemail=\nconfig_sha256=%s\n' "$(sha256sum "$CONFIG" | awk '{print $1}')" > "$STATE"
    check_ownership
    [[ $MANAGED == 1 && $DOMAIN == example.com && $LOCAL_PORT == 8443 ]]
    # An upgrade must reuse our Caddy and keep HTTP-01 without reinstalling.
    port_lines() { printf 'LISTEN 0 4096 *:%s *:* users:(("caddy",pid=23,fd=3))' "$1"; }
    systemctl() { printf '23\n'; }
    check_available
    systemctl() { printf '错误：重复安装触及systemd\n' >&2; return 1; }
    install_caddy
    printf 'manual change\n' >> "$CONFIG"
    if (check_ownership) 2>/dev/null; then printf '错误：覆盖了人工修改\n'; exit 1; fi
)
printf 'PASS 已有HTTP站点升级：复用Caddy占用的端口、不重复安装、保护人工改动\n'

(
    # Reject foreign Caddy before prompts, downloads or file modifications.
    check_platform() { :; }
    ask_settings() { printf reached > "$WORK/foreign-prompt-reached"; }
    install_caddy() { printf reached > "$WORK/foreign-install-reached"; }
    for scenario in binary service config webroot clean; do
        base="$WORK/foreign-$scenario"
        mkdir -p "$base"
        CONFIG="$base/Caddyfile"
        STATE="$base/state"
        WEBROOT="$base/www"
        case "$scenario" in
            config) printf 'existing website\n' > "$CONFIG" ;;
            webroot) mkdir -p "$WEBROOT"; printf 'existing page\n' > "$WEBROOT/index.html" ;;
        esac
        has() { [[ "$1" == caddy && "$scenario" == binary ]]; }
        systemctl() {
            [[ "$1" == show ]] || return 1
            if [[ "$scenario" == service ]]; then printf loaded; else printf not-found; fi
        }
        if [[ "$scenario" == clean ]]; then
            check_ownership
            [[ $MANAGED == 0 ]]
            continue
        fi
        if output=$(deploy 2>&1); then printf '错误：接管了其他来源的Caddy\n'; exit 1; fi
        [[ "$output" == *没有本脚本的部署记录* ]]
        [[ ! -e "$WORK/foreign-prompt-reached" && ! -e "$WORK/foreign-install-reached" ]]
        case "$scenario" in
            config) [[ $(cat "$CONFIG") == 'existing website' ]] ;;
            webroot) [[ $(cat "$WEBROOT/index.html") == 'existing page' ]] ;;
        esac
    done
)
(
    CONFIG="$WORK/legacy-dns-config"
    STATE="$WORK/legacy-dns-state"
    WEBROOT="$WORK/legacy-dns-www"
    printf 'legacy configuration\n' > "$CONFIG"
    printf 'domain=example.com\nlocal_port=8443\ncert_mode=dns\nconfig_sha256=%s\n' \
        "$(sha256sum "$CONFIG" | awk '{print $1}')" > "$STATE"
    if output=$(check_ownership 2>&1); then printf '错误：静默迁移了旧的其他验证方式\n'; exit 1; fi
    [[ "$output" == *只支持*HTTP-01* ]]
    [[ $(cat "$CONFIG") == 'legacy configuration' ]]
)
(
    port_lines() {
        if [[ "$1" == 443 ]]; then printf 'LISTEN 0 4096 *:443 *:* users:(("xray",pid=42,fd=3))'; fi
    }
    MANAGED=0
    check_available
)
printf 'PASS 部署边界：预装Caddy/服务/网站文件均停止且保留原文件，保护旧验证方式，允许Xray占443\n'

(
    CONFIG="$WORK/race-Caddyfile"
    STATE="$WORK/race-state"
    WEBROOT="$WORK/race-www"
    LOCK_FILE="$WORK/race-lock"
    DOMAIN=example.com
    LOCAL_PORT=8443
    EMAIL=''
    check_platform() { :; }
    install_caddy() { printf reached > "$WORK/race-install-reached"; }
    apply_site() { printf reached > "$WORK/race-apply-reached"; }
    verify_site() { :; }
    port_lines() { :; }
    for race_case in manual_edit new_deployment changed_state; do
        if [[ "$race_case" == new_deployment ]]; then
            rm -f -- "$CONFIG" "$STATE"
            has() { return 1; }
            systemctl() { printf not-found; }
        else
            printf 'original configuration\n' > "$CONFIG"
            write_state active > "$STATE"
        fi
        ask_settings() {
            case "$race_case" in
                manual_edit) printf '# EDIT_DURING_CONFIRMATION\n' >> "$CONFIG" ;;
                new_deployment) printf 'concurrent configuration\n' > "$CONFIG"; write_state active > "$STATE" ;;
                changed_state) printf 'concurrent_status=updated\n' >> "$STATE" ;;
            esac
        }
        if output=$(deploy 2>&1); then printf '错误：确认期间变化未阻止部署\n'; exit 1; fi
        [[ ! -e "$WORK/race-install-reached" && ! -e "$WORK/race-apply-reached" ]]
        case "$race_case" in
            manual_edit) grep -q EDIT_DURING_CONFIRMATION "$CONFIG" ;;
            new_deployment) [[ $(cat "$CONFIG") == 'concurrent configuration' ]] ;;
            changed_state) grep -q concurrent_status=updated "$STATE" ;;
        esac
    done
)
printf 'PASS 确认期间变化：手工编辑、并发新部署和部署记录变化均在写入前停止\n'

write_caddyfile example.com 8443 '' > "$WORK/production.Caddyfile"
"$CADDY_BIN" fmt --overwrite "$WORK/production.Caddyfile"
"$CADDY_BIN" adapt --config "$WORK/production.Caddyfile" --adapter caddyfile > "$WORK/config.json"
python3 - "$WORK/config.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
servers = list(c['apps']['http']['servers'].values())
listeners = {a for s in servers for a in s['listen']}
assert listeners == {'127.0.0.1:8443'}, listeners
assert all(s['automatic_https']['disable_redirects'] for s in servers)
assert all(not s['automatic_https'].get('disable') and not s['automatic_https'].get('disable_certificates') for s in servers)
assert all('h3' not in s['protocols'] for s in servers)
assert any('example.com' in p['subjects'] for p in c['apps']['tls']['automation']['policies'])
assert any(i.get('challenges',{}).get('tls-alpn',{}).get('disabled') for p in c['apps']['tls']['automation']['policies'] for i in p['issuers'])
assert 'example.com' in json.dumps(c['apps']['http'])
print('PASS HTTP-01生产配置：只常驻本机8443、保留自动证书管理、禁用跳转/QUIC/TLS-ALPN验证')
PY
"$CADDY_BIN" validate --config "$WORK/production.Caddyfile" --adapter caddyfile >/dev/null

# Use an isolated local CA and random high ports. Never request a public certificate.
read -r HTTP_PORT TLS_PORT ADMIN_PORT < <(python3 - <<'PY'
import socket
ports = [socket.socket() for _ in range(3)]
for s in ports: s.bind(('127.0.0.1',0))
print(*(s.getsockname()[1] for s in ports))
PY
)
mkdir -p "$WORK/www"
write_page > "$WORK/www/index.html"
write_caddyfile example.com "$TLS_PORT" '' "$WORK/www" > "$WORK/runtime.Caddyfile"
python3 - "$WORK/runtime.Caddyfile" "$WORK" "$HTTP_PORT" "$ADMIN_PORT" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace('auto_https disable_redirects', f'admin 127.0.0.1:{sys.argv[4]}\n    skip_install_trust\n    storage file_system {sys.argv[2]}/storage\n    auto_https disable_redirects')
s = s.replace('issuer acme {\n            disable_tlsalpn_challenge\n        }', 'issuer internal')
p.write_text(s)
legacy = s + f'\nhttp://example.com:{sys.argv[3]} {{\n    bind 127.0.0.1\n    root * {sys.argv[2]}/www\n    file_server\n}}\n'
(p.parent/'legacy.Caddyfile').write_text(legacy)
PY
"$CADDY_BIN" run --config "$WORK/legacy.Caddyfile" --adapter caddyfile > "$WORK/caddy.log" 2>&1 &
CADDY_PID=$!
if ! python3 - "$WORK" "$HTTP_PORT" "$TLS_PORT" "$ADMIN_PORT" "$CADDY_BIN" <<'PY'
import http.client, pathlib, socket, ssl, subprocess, sys, time
root, hp, tp, ap = pathlib.Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
ca = root/'storage/pki/authorities/local/root.crt'
for _ in range(40):
    if ca.exists():
        try:
            ctx = ssl.create_default_context(cafile=str(ca))
            ctx.minimum_version = ssl.TLSVersion.TLSv1_3
            ctx.set_alpn_protocols(['h2'])
            with ctx.wrap_socket(socket.create_connection(('127.0.0.1',tp),timeout=1),server_hostname='example.com') as conn:
                assert conn.version() == 'TLSv1.3'
                assert conn.selected_alpn_protocol() == 'h2'
                original_cert = conn.getpeercert(binary_form=True)
            break
        except (OSError, ssl.SSLError): pass
    time.sleep(.25)
else: raise AssertionError('Caddy TLS startup timed out')
print('PASS 本地真实握手：域名匹配、受本地测试CA信任、TLS1.3、ALPN=h2')
ctx.set_alpn_protocols(['http/1.1'])
ctx.check_hostname = False
with ctx.wrap_socket(socket.create_connection(('127.0.0.1',tp),timeout=3)) as conn:
    conn.sendall(b'GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n')
    data = b''
    while True:
        block = conn.recv(8192)
        if not block: break
        data += block
assert b'200 OK' in data.split(b'\r\n')[0]
assert '山间来信'.encode() in data
print('PASS 无SNI/Host为IP的HTTPS访问：返回默认域名证书及同一网页')
c = http.client.HTTPConnection('127.0.0.1',hp,timeout=3)
c.request('GET','/',headers={'Host':'example.com', 'Connection':'close'})
r = c.getresponse()
assert r.status == 200 and '山间来信'.encode() in r.read()
c.close()
subprocess.run([sys.argv[5], 'reload', '--config', str(root/'runtime.Caddyfile'),
                '--adapter', 'caddyfile', '--address', f'127.0.0.1:{ap}'], check=True, capture_output=True)
for _ in range(40):
    try:
        with socket.create_connection(('127.0.0.1',hp),timeout=.2): pass
    except ConnectionRefusedError: break
    time.sleep(.1)
else: raise AssertionError('Legacy HTTP listener was not released')
with socket.socket() as free_port:
    free_port.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    free_port.bind(('127.0.0.1',hp))
ctx.set_alpn_protocols(['h2'])
with ctx.wrap_socket(socket.create_connection(('127.0.0.1',tp),timeout=3),server_hostname='example.com') as conn:
    assert conn.getpeercert(binary_form=True) == original_cert
    assert conn.selected_alpn_protocol() == 'h2'
print('PASS 旧版HTTP站点升级：真实Caddy重载释放HTTP端口、保留同一证书及HTTPS/H2服务')
PY
then
    cat "$WORK/caddy.log"
    exit 1
fi

# Validate real files and backups while mocking systemd actions.
(
    CONFIG="$WORK/applied-config/Caddyfile"
    STATE="$WORK/applied-state"
    WEBROOT="$WORK/applied-www"
    BACKUP_ROOT="$WORK/backups"
    STAGE="$WORK/stage"
    DOMAIN=example.com
    LOCAL_PORT=8443
    EMAIL=''
    action_log="$WORK/apply-actions"
    mask_file="$WORK/mock-mask"
    failure_file="$WORK/fail-next-reload"
    mkdir -p "$(dirname "$CONFIG")" "$WEBROOT" "$STAGE"
    printf 'previous configuration\n' > "$CONFIG"
    printf 'user-edited page\n' > "$WEBROOT/index.html"
    touch "$mask_file"
    CADDY_INSTALL_MASKED=1
    CADDY_INSTALLED_NEW=1
    CADDY_CONFIG_APPLIED=0
    mock_active=0
    mock_exec_start='{ path=/usr/bin/caddy ; argv[]=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile ; ignore_errors=no ; }'
    caddy() { "$CADDY_BIN" "$@"; }
    id() { if [[ ${1:-} == caddy ]]; then return 0; else command id "$@"; fi; }
    runuser() { [[ "$1" == -u && "$2" == caddy && "$3" == -- ]]; shift 3; "$@"; }
    restorecon() { :; }
    systemctl() {
        printf 'systemctl %s\n' "$*" >> "$action_log"
        case "$1" in
            unmask) rm -f -- "$mask_file" ;;
            show) [[ -f "$mask_file" ]] || printf '%s\n' "$mock_exec_start" ;;
            is-active) [[ "$mock_active" == 1 ]] ;;
            start|reload)
                [[ -s "$CONFIG" && -f "$WEBROOT/index.html" ]]
                if [[ "$1" == reload && -f "$failure_file" ]]; then
                    rm -f -- "$failure_file"
                    return 1
                fi ;;
            enable|daemon-reload) return 0 ;;
            *) return 1 ;;
        esac
    }
    apply_site > /dev/null
    [[ ! -e "$mask_file" && $CADDY_CONFIG_APPLIED == 1 && $CADDY_INSTALL_MASKED == 0 ]]
    [[ $(state_value cert_mode) == http && $(state_value status) == active ]]
    [[ $(state_value config_sha256) == "$(sha256sum "$CONFIG" | awk '{print $1}')" ]]
    [[ $(cat "$WEBROOT/index.html") == 'user-edited page' ]]
    grep -q 'systemctl start caddy' "$action_log"
    [[ -f "$BACKUP/Caddyfile" && -f "$BACKUP/index.html" ]]
    CADDY_INSTALLED_NEW=0
    mock_active=1
    apply_site > /dev/null
    grep -q 'systemctl reload caddy' "$action_log"
    [[ $(cat "$WEBROOT/index.html") == 'user-edited page' ]]
    if grep -Eq 'x-ui|restart|stop' "$action_log"; then printf '错误：触及了无关服务或重启\n'; exit 1; fi
    printf '# preserve this on failed reload\n' >> "$CONFIG"
    write_state active > "$STATE"
    original_hash=$(sha256sum "$CONFIG" | awk '{print $1}')
    touch "$failure_file"
    if output=$(apply_site 2>&1); then printf '错误：重载失败被忽略\n'; exit 1; fi
    [[ "$output" == *旧配置已恢复* ]]
    [[ $(sha256sum "$CONFIG" | awk '{print $1}') == "$original_hash" ]]
    [[ $(state_value config_sha256) == "$original_hash" ]]
    mock_exec_start='/usr/bin/caddy run --config /etc/caddy/Caddyfile.backup'
    if output=$(apply_site 2>&1); then printf '错误：允许使用同前缀的其他配置路径\n'; exit 1; fi
    [[ "$output" == *不同的配置路径* ]]
    [[ $(sha256sum "$CONFIG" | awk '{print $1}') == "$original_hash" ]]
)
printf 'PASS 配置应用：先解除屏蔽再启动、保存HTTP部署记录、保留网页、重复运行重载、失败恢复旧配置\n'
printf '全部本地测试通过。未在 VPS 执行安装或申请公网证书。\n'
