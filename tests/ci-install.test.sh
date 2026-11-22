#!/usr/bin/env bash
# Run only in disposable CI containers/VMs: installs real software packages.
# Uses an isolated local CA, never a public ACME account or a user's VPS.
# shellcheck disable=SC2030,SC2031
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODE=${1:?Specify container or systemd}
[[ "$MODE" == container || "$MODE" == systemd ]]
[[ $EUID == 0 ]]
WORK=$(mktemp -d /tmp/reality-site-ci.XXXXXXXX)
RUNTIME_PID=''
source "$ROOT/reality-site.sh"

finish() {
    local result=$?
    trap - EXIT
    set +e
    if (( result != 0 )); then
        printf '\nFAIL: %s / %s / %s\n' "${PRETTY_NAME:-unknown}" "$(uname -m)" "$MODE"
        [[ ! -f "$WORK/caddy.log" ]] || tail -n 100 "$WORK/caddy.log"
        if [[ "$MODE" == systemd ]]; then journalctl -u caddy -n 100 --no-pager; fi
    fi
    if [[ -n "$RUNTIME_PID" ]]; then kill "$RUNTIME_PID" 2>/dev/null; wait "$RUNTIME_PID" 2>/dev/null; fi
    if [[ "$MODE" == systemd ]]; then systemctl stop caddy; fi
    cleanup_deploy
    rm -rf -- "$WORK"
    exit "$result"
}
trap finish EXIT

check_system_compatibility
printf 'Actual OS: %s; architecture: %s; mode: %s\n' "$PRETTY_NAME" "$(uname -m)" "$MODE"
if [[ -n ${EXPECTED_ID:-} ]]; then
    [[ "$ID" == "$EXPECTED_ID" ]]
    case "$ID" in
        ubuntu|debian|fedora) [[ "$VERSION_ID" == "$EXPECTED_VERSION" ]] ;;
        *) [[ "${VERSION_ID%%.*}" == "$EXPECTED_VERSION" ]] ;;
    esac
fi

# Official base containers are smaller than VPS images. Install the documented
# prerequisite tools, not Caddy; its packages come from the production function.
if [[ "$FAMILY" == apt ]]; then
    if [[ "$ID" == debian && "$VERSION_ID" == 11 ]]; then
        # Debian 11 has reached the archive. This is explicit CI preparation,
        # not a source migration performed by the public deployment script.
        printf '%s\n' \
            'deb [check-valid-until=no] http://archive.debian.org/debian bullseye main' \
            'deb [check-valid-until=no] http://archive.debian.org/debian-security bullseye-security main' \
            > /etc/apt/sources.list
        rm -f /etc/apt/sources.list.d/debian.sources
        printf 'CI prerequisite: Debian 11 uses signed Debian archive repositories; production script does not switch sources.\n'
    fi
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        systemd iproute2 util-linux gawk coreutils libc-bin openssl python3 ca-certificates
else
    packages=(systemd iproute util-linux gawk glibc-common openssl python3 ca-certificates diffutils)
    # EL minimal images provide these commands through coreutils-single. Do not
    # replace that working package merely to prepare a test environment.
    for tool in sha256sum install timeout; do
        if ! has "$tool"; then packages+=(coreutils); break; fi
    done
    "$(dnf_command)" install -y "${packages[@]}"
fi
DOMAIN=ci.example.test
LOCAL_PORT=18443
STAGE=$(mktemp -d /tmp/reality-site-ci-stage.XXXXXXXX)
CA=/var/lib/caddy/ci-storage/pki/authorities/local/root.crt

if [[ "$MODE" == systemd ]]; then
    check_platform
    check_ownership
    check_available
fi
install_caddy
caddy version
id caddy
getent group caddy
unit=''
for candidate in /usr/lib/systemd/system/caddy.service /lib/systemd/system/caddy.service; do
    if [[ -f "$candidate" ]]; then unit="$candidate"; break; fi
done
[[ -n "$unit" ]]
grep -Eq '^ExecStart=.*--config(=|[[:space:]]+)/etc/caddy/Caddyfile([[:space:]]|$)' "$unit"
printf 'PASS: production install_caddy installed Caddy, service account and expected unit file\n'

install -d -m 755 "$WEBROOT"
write_page > "$WEBROOT/index.html"
write_caddyfile "$DOMAIN" "$LOCAL_PORT" '' "$WEBROOT" > "$WORK/production.Caddyfile"
install -m 644 "$WORK/production.Caddyfile" /etc/caddy/ci-production.Caddyfile
runuser -u caddy -- caddy validate --config /etc/caddy/ci-production.Caddyfile --adapter caddyfile
install -d -m 755 -o caddy -g caddy /var/lib/caddy/ci-storage
cat > "$WORK/use-local-ca.py" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
old = 'cert_issuer acme {\n        disable_tlsalpn_challenge\n    }'
assert text.count(old) == 1
text = text.replace(old, 'cert_issuer internal')
text = text.replace('auto_https disable_redirects', '''skip_install_trust
    storage file_system /var/lib/caddy/ci-storage
    auto_https disable_redirects''', 1)
pathlib.Path(sys.argv[2]).write_text(text)
PY
python3 "$WORK/use-local-ca.py" "$WORK/production.Caddyfile" "$WORK/runtime.Caddyfile"
install -m 644 "$WORK/runtime.Caddyfile" /etc/caddy/ci-runtime.Caddyfile

if [[ "$MODE" == systemd ]]; then
    # Only the CA is replaced for this test. apply_site and verify_site are the
    # actual production functions; no service operations are mocked.
    # shellcheck disable=SC2329
    caddy() {
        if [[ "$1" == fmt && "$2" == --overwrite ]]; then
            python3 "$WORK/use-local-ca.py" "$3" "$3" || return
        fi
        command caddy "$@"
    }
    apply_site
    CURL_CA_BUNDLE="$CA" verify_site
else
    # mask/unmask work on unit files without PID 1; do not fake a running systemd.
    systemctl unmask caddy.service
    CADDY_INSTALL_MASKED=0
    runuser -u caddy -- caddy run --config /etc/caddy/ci-runtime.Caddyfile --adapter caddyfile > "$WORK/caddy.log" 2>&1 &
    RUNTIME_PID=$!
fi

ready=0
for (( attempt=1; attempt<=60; attempt++ )); do
    if curl --noproxy '*' --silent --show-error --max-time 2 --fail \
        --cacert "$CA" --resolve "$DOMAIN:$LOCAL_PORT:127.0.0.1" \
        "https://$DOMAIN:$LOCAL_PORT/" -o "$WORK/response.html" 2>/dev/null; then
        ready=1
        break
    fi
    sleep 1
done
[[ "$ready" == 1 ]]
cmp "$WEBROOT/index.html" "$WORK/response.html"
timeout 15 openssl s_client -connect "127.0.0.1:$LOCAL_PORT" -servername "$DOMAIN" \
    -tls1_3 -alpn h2 -CAfile "$CA" -verify_hostname "$DOMAIN" -verify_return_error \
    </dev/null > "$WORK/tls.txt" 2>&1
grep -q 'ALPN protocol: h2' "$WORK/tls.txt"
[[ -z $(ss -H -lnt 'sport = :80') ]]
printf 'PASS: trusted local-CA HTTPS, matching domain/page, TLS1.3, ALPN=h2, no permanent HTTP listener\n'

if [[ "$MODE" == systemd ]]; then
    systemctl is-active --quiet caddy
    MANAGED=1
    check_available
    before=$(openssl x509 -in "$WORK/tls.txt" -noout -fingerprint -sha256)
    printf '<!doctype html><title>Custom CI page</title>keep my page\n' > "$WEBROOT/index.html"
    check_ownership
    [[ "$MANAGED" == 1 ]]
    install_caddy
    apply_site
    CURL_CA_BUNDLE="$CA" verify_site
    grep -q 'keep my page' "$WEBROOT/index.html"
    timeout 15 openssl s_client -connect "127.0.0.1:$LOCAL_PORT" -servername "$DOMAIN" \
        -CAfile "$CA" -verify_hostname "$DOMAIN" -verify_return_error \
        </dev/null > "$WORK/tls-after-reload.txt" 2>&1
    [[ $(openssl x509 -in "$WORK/tls-after-reload.txt" -noout -fingerprint -sha256) == "$before" ]]
    systemctl is-active --quiet caddy
    printf 'PASS: actual systemd service/reload, managed rerun preserves custom page and leaf certificate\n'

    # Exercise the public deploy entry point against a legacy state file. Only
    # resolution of our reserved .test names is faked; Caddy and HTTPS are real.
    old_domain=$DOMAIN
    new_domain=changed.example.test
    failed_domain=unverified.example.test
    original_pid=$(systemctl show caddy -p MainPID --value)
    # shellcheck disable=SC2329
    getent() {
        if [[ "$1" == ahosts && ( "$2" == "$old_domain" || "$2" == "$new_domain" || "$2" == "$failed_domain" ) ]]; then
            printf '127.0.0.1\n'
        else
            command getent "$@"
        fi
    }
    export CURL_CA_BUNDLE="$CA"
    (deploy < <(printf '%s\n\nDEPLOY\n' "$new_domain"))
    check_ownership
    [[ "$DOMAIN" == "$new_domain" && "$LOCAL_PORT" == 18443 ]]
    [[ ${#SITE_DOMAINS[@]} == 1 && "${SITE_DOMAINS[0]}" == "$new_domain" ]]
    [[ $(<"$CONFIG") != *"$old_domain"* ]]
    check_domain_page() {
        local host="$1"
        curl --noproxy '*' --fail --silent --show-error --max-time 5 \
            --resolve "$host:$LOCAL_PORT:127.0.0.1" "https://$host:$LOCAL_PORT/" -o "$WORK/domain-page"
        cmp "$WEBROOT/index.html" "$WORK/domain-page"
    }
    check_domain_page "$new_domain"
    if curl --noproxy '*' --fail --silent --max-time 5 --resolve "$old_domain:$LOCAL_PORT:127.0.0.1" \
        "https://$old_domain:$LOCAL_PORT/" -o /dev/null; then
        printf 'FAIL: retired domain still serves trusted HTTPS\n' >&2
        exit 1
    fi
    grep -q 'keep my page' "$WEBROOT/index.html"
    timeout 15 openssl s_client -connect "127.0.0.1:$LOCAL_PORT" -noservername \
        -CAfile "$CA" -verify_hostname "$new_domain" -verify_return_error \
        </dev/null > "$WORK/tls-new-default.txt" 2>&1
    # Retiring a name is independent of deleting its stored certificate.
    find /var/lib/caddy/ci-storage -name "$old_domain.crt" -type f -print -quit | grep -q .

    (deploy < <(printf '\n\nDEPLOY\n'))
    check_ownership
    [[ "$DOMAIN" == "$new_domain" && ${#SITE_DOMAINS[@]} == 1 ]]
    [[ $(<"$CONFIG") != *"$old_domain"* ]]
    cp "$CONFIG" "$WORK/before-failed-switch.config"
    cp "$STATE" "$WORK/before-failed-switch.state"
    set +e
    (
        set -e
        # Force a verification failure, without using public DNS or waiting
        # 90 seconds. Record proof that the current site is still served.
        # shellcheck disable=SC2329
        curl() {
            if [[ "${*: -1}" == "https://$failed_domain:$LOCAL_PORT/" ]]; then
                cmp "$CONFIG" "$WORK/before-failed-switch.config" || exit 99
                command curl --noproxy '*' --fail --silent --show-error --max-time 5 \
                    --resolve "$new_domain:$LOCAL_PORT:127.0.0.1" "https://$new_domain:$LOCAL_PORT/" -o /dev/null || exit 99
                touch "$WORK/current-domain-served-in-preview"
                return 60
            fi
            command curl "$@"
        }
        # shellcheck disable=SC2329
        sleep() { :; }
        deploy < <(printf '%s\n\nDEPLOY\n' "$failed_domain")
    )
    result=$?
    set -e
    [[ "$result" == 2 ]]
    [[ -f "$WORK/current-domain-served-in-preview" ]]
    cmp "$CONFIG" "$WORK/before-failed-switch.config"
    cmp "$STATE" "$WORK/before-failed-switch.state"
    [[ $(systemctl show caddy -p MainPID --value) == "$original_pid" ]]
    check_domain_page "$new_domain"
    printf 'PASS: domain change replaces old HTTPS and default SNI, preserves page/port/PID and restores the site on a failed change\n'
fi
python3 "$ROOT/tests/acme-http01.test.py" "$(command -v caddy)" "$ROOT/reality-site.sh"
printf 'PASS: %s / %s / %s\n' "$PRETTY_NAME" "$(uname -m)" "$MODE"
