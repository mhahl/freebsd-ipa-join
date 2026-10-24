#!/bin/sh
# test-enrollment.sh - focused test for automatic FreeIPA enrollment.
#
# Covers the new behavior: the setup credentials (IPA user + password) are
# used to add the host server-side (ipa host-show/host-add) and pull the
# host keytab (ipa-getkeytab), instead of requiring manual server-side steps.
#
# Uses stub ipa/kinit/ipa-getkeytab binaries, so it runs anywhere with a
# POSIX sh + mktemp + ls. Run from the repo root:
#   sh tests/test-enrollment.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ipa-test_XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# --- load script functions without running main() ---------------------------
sed -e '$d' "$ROOT/freebsd-ipa-client.sh" > "$TMP/funcs.sh"
# shellcheck disable=SC1090
. "$TMP/funcs.sh"
set +e # allow expected-failure subshells below

# --- redirect all system paths into $TMP ------------------------------------
BACKUP_DIR="$TMP/backups"
HOST_KEYTAB="$TMP/krb5.keytab"
KRB5_CONF="$TMP/krb5.conf"
LDAP_CONF="$TMP/ldap.conf"
SSSD_CONF="$TMP/sssd.conf"
NSSWITCH_CONF="$TMP/nsswitch.conf"
IPA_CONF="$TMP/ipa-default.conf"
CA_CRT="$TMP/ca.crt"
: > "$CA_CRT" # enroll_auto only passes its path via REQUESTS_CA_BUNDLE

IPA_SERVER="idm.example.com"
IPA_DOMAIN="example.com"
IPA_REALM="EXAMPLE.COM"
CLIENT_FQDN="client.example.com"
IPA_USER="admin"
IPA_PASSWORD="secret"
ENROLL_MODE="auto"
DRY_RUN="no"

# --- stub client tools -------------------------------------------------------
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
export STUB_LOG="$TMP/stub.log" STUB_ADDED="$TMP/added" STUB_KEYTABS="$TMP/keytabs"
export STUB_EXISTING_HOST="" KINIT_EXIT=0 HOSTADD_EXIT=0 GETKEYTAB_EXIT=1

cat > "$FAKEBIN/kinit" <<'EOF'
#!/bin/sh
cat > /dev/null # consume password from stdin
echo "kinit $* [cc=${KRB5CCNAME:-unset}]" >> "$STUB_LOG"
exit "${KINIT_EXIT:-0}"
EOF
cat > "$FAKEBIN/ipa" <<'EOF'
#!/bin/sh
echo "ipa $* [cc=${KRB5CCNAME:-unset}] [cabundle=${REQUESTS_CA_BUNDLE:-unset}]" >> "$STUB_LOG"
if [ "$1" = "host-show" ]; then
    if [ "$2" = "$STUB_EXISTING_HOST" ]; then exit 0; else exit 1; fi
elif [ "$1" = "host-add" ]; then
    echo "$2" >> "$STUB_ADDED"
    exit "${HOSTADD_EXIT:-0}"
fi
exit 2
EOF
cat > "$FAKEBIN/ipa-getkeytab" <<'EOF'
#!/bin/sh
echo "ipa-getkeytab $*" >> "$STUB_LOG"
if [ "${GETKEYTAB_EXIT:-0}" != "0" ]; then exit "$GETKEYTAB_EXIT"; fi
prev=""
for a in "$@"; do
    if [ "$prev" = "-k" ]; then : > "$a"; echo "$a" >> "$STUB_KEYTABS"; fi
    prev="$a"
done
exit 0
EOF
for t in klist kdestroy; do
    printf '#!/bin/sh\necho "%s $*" >> "$STUB_LOG"\nexit 0\n' "$t" > "$FAKEBIN/$t"
done
chmod +x "$FAKEBIN"/*
PATH="$FAKEBIN:/usr/bin:/bin"

mode_of() { ls -l "$1" | awk '{print substr($1, 1, 10)}'; }
reset_stubs() {
    rm -f "$STUB_LOG" "$STUB_ADDED" "$STUB_KEYTABS" "$HOST_KEYTAB"
    rm -f "$TMP"/krb5cc_ipa_*
    STUB_EXISTING_HOST=""; KINIT_EXIT=0; HOSTADD_EXIT=0; GETKEYTAB_EXIT=0
    IPA_PASSWORD="secret"; unset KRB5CCNAME || true
    export TMPDIR="$TMP" # enroll_auto's temp ccache lands here, gets cleaned
}

# --- 1. ipa client config points the official tools at our server ----------
reset_stubs
write_ipa_conf
if grep -q "^server = idm.example.com$" "$IPA_CONF" \
    && grep -q "^realm = EXAMPLE.COM$" "$IPA_CONF" \
    && grep -q "^domain = example.com$" "$IPA_CONF" \
    && grep -q "^host = client.example.com$" "$IPA_CONF" \
    && grep -q "^xmlrpc_uri = https://idm.example.com/ipa/xml$" "$IPA_CONF"; then
    pass "write_ipa_conf writes server/realm/domain/host/xmlrpc_uri"
else
    fail "write_ipa_conf writes server/realm/domain/host/xmlrpc_uri"
fi

# --- 2. auto: missing host is added, keytab pulled with setup creds ---------
reset_stubs
STUB_EXISTING_HOST="other.example.com"
( install_keytab ); rc=$?
if [ "$rc" -eq 0 ] \
    && [ -f "$HOST_KEYTAB" ] \
    && [ "$(mode_of "$HOST_KEYTAB")" = "-rw-------" ] \
    && grep -q "^client.example.com$" "$STUB_ADDED" \
    && grep -q "kinit admin@EXAMPLE.COM" "$STUB_LOG" \
    && grep -q "ipa-getkeytab -s idm.example.com -p host/client.example.com@EXAMPLE.COM" "$STUB_LOG"; then
    pass "auto enrolls missing host (host-add) and pulls keytab (0600)"
else
    fail "auto enrolls missing host (host-add) and pulls keytab (0600) [rc=$rc]"
fi
# credentials are scoped to a temp ccache that is destroyed afterwards
if grep -q "cc=FILE:$TMP/krb5cc_ipa_" "$STUB_LOG" \
    && [ -z "$(ls "$TMP"/krb5cc_ipa_* 2>/dev/null)" ] \
    && [ -z "${KRB5CCNAME:-}" ]; then
    pass "auto uses a temp ccache and destroys it (KRB5CCNAME restored)"
else
    fail "auto uses a temp ccache and destroys it (KRB5CCNAME restored)"
fi

# --- 3. auto: existing host is reused, not re-added --------------------------
reset_stubs
STUB_EXISTING_HOST="client.example.com"
( install_keytab ); rc=$?
if [ "$rc" -eq 0 ] && [ -f "$HOST_KEYTAB" ] && [ ! -f "$STUB_ADDED" ]; then
    pass "auto reuses existing host without host-add"
else
    fail "auto reuses existing host without host-add [rc=$rc]"
fi

# --- 4. auto: keytab failure aborts enrollment -------------------------------
reset_stubs
GETKEYTAB_EXIT=1
( install_keytab ) 2>/dev/null; rc=$?
if [ "$rc" -ne 0 ]; then
    pass "auto aborts when ipa-getkeytab fails"
else
    fail "auto aborts when ipa-getkeytab fails"
fi

# --- 5. auto: missing client tools point at the FreeBSD package --------------
reset_stubs
out="$( ( PATH="/usr/bin:/bin" install_keytab ) 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "net/freeipa-client"; then
    pass "auto without client tools hints at pkg install net/freeipa-client"
else
    fail "auto without client tools hints at pkg install net/freeipa-client"
fi

# --- 6. auto: missing password is an explicit error --------------------------
reset_stubs
IPA_PASSWORD=""
( install_keytab ) 2>/dev/null; rc=$?
if [ "$rc" -ne 0 ]; then
    pass "auto without a password fails explicitly"
else
    fail "auto without a password fails explicitly"
fi

# --- 7. hosts file: append once, replace on IP change -------------------------
reset_stubs
printf '127.0.0.1 localhost\n' > "$TMP/hosts"
update_hosts_file "$TMP/hosts" "10.0.0.50" "client.example.com" "client"
update_hosts_file "$TMP/hosts" "10.0.0.50" "client.example.com" "client"
if [ "$(grep -c "client.example.com" "$TMP/hosts")" -eq 1 ] \
    && grep -q "^10.0.0.50[[:space:]][[:space:]]*client.example.com client$" "$TMP/hosts"; then
    pass "hosts entry appended once (idempotent)"
else
    fail "hosts entry appended once (idempotent)"
fi
update_hosts_file "$TMP/hosts" "10.0.0.99" "client.example.com" "client"
if [ "$(grep -c "client.example.com" "$TMP/hosts")" -eq 1 ] \
    && grep -q "^10.0.0.99[[:space:]][[:space:]]*client.example.com client$" "$TMP/hosts"; then
    pass "hosts entry replaced on IP change"
else
    fail "hosts entry replaced on IP change"
fi

# --- 8. IP auto-detection from the default route ------------------------------
reset_stubs
cat > "$FAKEBIN/route" <<'EOF'
#!/bin/sh
printf 'route to: default\ndestination: default\nmask: default\ngateway: 10.0.0.1\nfib: 0\ninterface: em0\n'
EOF
cat > "$FAKEBIN/ifconfig" <<'EOF'
#!/bin/sh
printf 'em0: flags=8863<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500\n\tinet 10.0.0.50 netmask 0xffffff00 broadcast 10.0.0.255\n\tinet6 fe80::1%%em0 prefixlen 64 scopeid 0x1\n'
EOF
chmod +x "$FAKEBIN/route" "$FAKEBIN/ifconfig"
if [ "$(detect_ip)" = "10.0.0.50" ]; then
    pass "detect_ip uses default-route interface IPv4"
else
    fail "detect_ip uses default-route interface IPv4 [got '$(detect_ip)']"
fi

# --- 9. required-input check for unattended mode ------------------------------
reset_stubs
IPA_SERVER=""; IPA_DOMAIN="example.com"; CLIENT_FQDN="client.example.com"; ENROLL_MODE="auto"
if have_required_inputs; then
    fail "required-input check fails when server missing"
else
    pass "required-input check fails when server missing"
fi
IPA_SERVER="idm.example.com"
if have_required_inputs; then
    pass "required-input check passes when complete"
else
    fail "required-input check passes when complete"
fi
ENROLL_MODE="otp"; OTP=""
if have_required_inputs; then
    fail "required-input check fails for otp without OTP"
else
    pass "required-input check fails for otp without OTP"
fi
OTP="secret-otp"
if have_required_inputs; then
    pass "required-input check passes for otp with OTP"
else
    fail "required-input check passes for otp with OTP"
fi
ENROLL_MODE="auto"; OTP=""; IPA_SERVER="idm.example.com"

# --- 10. time sync enables ntpd and starts it when stopped --------------------
reset_stubs
cat > "$FAKEBIN/sysrc" <<'EOF'
#!/bin/sh
echo "sysrc $*" >> "$STUB_LOG"
exit 0
EOF
cat > "$FAKEBIN/service" <<'EOF'
#!/bin/sh
echo "service $*" >> "$STUB_LOG"
if [ "$2" = "status" ]; then exit "${SERVICE_STATUS_EXIT:-0}"; fi
exit 0
EOF
cat > "$FAKEBIN/ntpdate" <<'EOF'
#!/bin/sh
echo "ntpdate $*" >> "$STUB_LOG"
exit 0
EOF
cat > "$FAKEBIN/pkg" <<'EOF'
#!/bin/sh
echo "pkg $*" >> "$STUB_LOG"
exit 0
EOF
chmod +x "$FAKEBIN/sysrc" "$FAKEBIN/service" "$FAKEBIN/ntpdate" "$FAKEBIN/pkg"
export SERVICE_STATUS_EXIT=1
DRY_RUN="no"
sync_time
if grep -q "sysrc ntpd_enable=YES" "$STUB_LOG" \
    && grep -q "service ntpd start" "$STUB_LOG"; then
    pass "sync_time enables ntpd and starts it when stopped"
else
    fail "sync_time enables ntpd and starts it when stopped"
fi
rm -f "$STUB_LOG"
export SERVICE_STATUS_EXIT=0
sync_time
if grep -q "service ntpd start" "$STUB_LOG"; then
    fail "sync_time leaves a running ntpd alone"
else
    pass "sync_time leaves a running ntpd alone"
fi

# --- 11. sudo SSSD support detection -------------------------------------------
reset_stubs
cat > "$FAKEBIN/sudo" <<'EOF'
#!/bin/sh
echo "sudo $*" >> "$STUB_LOG"
if [ "$1" = "-V" ]; then cat "$SUDO_V_FILE"; fi
exit 0
EOF
cat > "$FAKEBIN/ldd" <<'EOF'
#!/bin/sh
echo "ldd $*" >> "$STUB_LOG"
cat "$LDD_FILE"
exit 0
EOF
chmod +x "$FAKEBIN/sudo" "$FAKEBIN/ldd"
export SUDO_V_FILE="$TMP/sudo-v.txt" LDD_FILE="$TMP/ldd.txt"
printf 'Sudo version 1.9.17p2\nSudoers path: /usr/local/etc/sudoers\nPlugins: sudoers_policy sudoers_audit sudoers_io sssd\n' > "$SUDO_V_FILE"
printf '\tlibthr.so.3 => /lib/libthr.so.3\n' > "$LDD_FILE"
if sudo_supports_sss; then
    pass "sudo detection passes when sudo -V names sss"
else
    fail "sudo detection passes when sudo -V names sss"
fi
printf 'Sudo version 1.9.17p2\nSudoers path: /usr/local/etc/sudoers\n' > "$SUDO_V_FILE"
printf '\tlibsss_nss_idmap.so.0 => /usr/local/lib/libsss_nss_idmap.so.0\n' > "$LDD_FILE"
if sudo_supports_sss; then
    pass "sudo detection passes when linked against libsss"
else
    fail "sudo detection passes when linked against libsss"
fi
printf '\tlibthr.so.3 => /lib/libthr.so.3\n' > "$LDD_FILE"
if sudo_supports_sss; then
    fail "sudo detection fails without any sss trace"
else
    pass "sudo detection fails without any sss trace"
fi

# --- 12. sudo package selection + ensure ---------------------------------------
reset_stubs
ENABLE_SUDO="yes"
if [ "$(sudo_pkg)" = "security/sudo-sssd" ]; then
    pass "sudo package is the sssd flavor when IPA sudo enabled"
else
    fail "sudo package is the sssd flavor when IPA sudo enabled"
fi
ENABLE_SUDO="no"
if [ "$(sudo_pkg)" = "security/sudo" ]; then
    pass "sudo package is plain sudo when IPA sudo disabled"
else
    fail "sudo package is plain sudo when IPA sudo disabled"
fi
ENABLE_SUDO="yes"
DRY_RUN="yes"
if install_packages 2>&1 | grep -q "security/sudo-sssd"; then
    pass "package install pulls the sssd sudo flavor"
else
    fail "package install pulls the sssd sudo flavor"
fi
DRY_RUN="no"
printf 'sss\n' > "$SUDO_V_FILE"
rm -f "$STUB_LOG"
( ensure_sudo_sss ); rc=$?
if [ "$rc" -eq 0 ] && ! grep -q "^pkg " "$STUB_LOG" 2>/dev/null; then
    pass "ensure keeps a capable sudo without reinstall"
else
    fail "ensure keeps a capable sudo without reinstall [rc=$rc]"
fi
printf 'plain\n' > "$SUDO_V_FILE"
rm -f "$STUB_LOG"
( ensure_sudo_sss ) 2>/dev/null; rc=$?
if [ "$rc" -ne 0 ] && grep -q "pkg install.*security/sudo-sssd" "$STUB_LOG"; then
    pass "ensure reinstalls from pkg then fails clearly when still incapable"
else
    fail "ensure reinstalls from pkg then fails clearly when still incapable [rc=$rc]"
fi

# --- 13. plain prompts read from stdin -----------------------------------------
reset_stubs
if [ "$(printf 'typed\n' | t_input "P" "def" "T" 2>/dev/null)" = "typed" ]; then
    pass "t_input returns typed value"
else
    fail "t_input returns typed value"
fi
if [ "$(printf '\n' | t_input "P" "def" "T" 2>/dev/null)" = "def" ]; then
    pass "t_input falls back to default on empty input"
else
    fail "t_input falls back to default on empty input"
fi
if printf 'y\n' | t_yesno "Proceed?" "T" 2>/dev/null; then
    pass "t_yesno accepts y"
else
    fail "t_yesno accepts y"
fi
if printf 'n\n' | t_yesno "Proceed?" "T" 2>/dev/null; then
    fail "t_yesno rejects n"
else
    pass "t_yesno rejects n"
fi
if [ "$(printf 's3cret\n' | t_password "P" "T" 2>/dev/null)" = "s3cret" ]; then
    pass "t_password returns typed value"
else
    fail "t_password returns typed value"
fi

# --- 14. DNS SRV discovery picks lowest-priority LDAP server ------------------
reset_stubs
cat > "$FAKEBIN/drill" <<'EOF'
#!/bin/sh
echo "drill $*" >> "$STUB_LOG"
cat "$DRILL_FILE"
exit 0
EOF
chmod +x "$FAKEBIN/drill"
export DRILL_FILE="$TMP/drill.txt"
printf '_ldap._tcp.example.com.\t3600\tIN\tSRV\t10 100 389 idm2.example.com.\n_ldap._tcp.example.com.\t3600\tIN\tSRV\t0 100 389 idm.example.com.\n;; ADDITIONAL SECTION:\nidm.example.com.\t3600\tIN\tA\t10.0.0.40\n' > "$DRILL_FILE"
if [ "$(discover_ipa_server "example.com")" = "idm.example.com" ]; then
    pass "discovery picks lowest-priority SRV target without trailing dot"
else
    fail "discovery picks lowest-priority SRV target without trailing dot [got '$(discover_ipa_server "example.com")']"
fi
if grep -q "drill SRV _ldap._tcp.example.com" "$STUB_LOG"; then
    pass "discovery queries _ldap._tcp SRV records"
else
    fail "discovery queries _ldap._tcp SRV records"
fi
: > "$DRILL_FILE"
if discover_ipa_server "example.com" 2>/dev/null; then
    fail "discovery fails cleanly with no SRV records"
else
    pass "discovery fails cleanly with no SRV records"
fi

# --- 15. package fallback when repo lacks a flavor/renamed package ------------
reset_stubs
cat > "$FAKEBIN/pkg" <<'EOF'
#!/bin/sh
echo "pkg $*" >> "$STUB_LOG"
case "$*" in *"${PKG_FAIL_MATCH:-__none__}"*) exit 1;; *) exit 0;; esac
EOF
chmod +x "$FAKEBIN/pkg"
export PKG_FAIL_MATCH="sudo-sssd"
DRY_RUN="no"
( install_pkg_candidates security/sudo-sssd security/sudo ); rc=$?
if [ "$rc" -eq 0 ] \
    && grep -q "pkg install -y security/sudo-sssd" "$STUB_LOG" \
    && grep -q "pkg install -y security/sudo$" "$STUB_LOG"; then
    pass "install tries flavor first, falls back to plain sudo"
else
    fail "install tries flavor first, falls back to plain sudo [rc=$rc]"
fi
export PKG_FAIL_MATCH="security/sudo"
( install_pkg_candidates security/sudo-sssd security/sudo ) 2>/dev/null; rc=$?
if [ "$rc" -ne 0 ]; then
    pass "install fails clearly when no candidate exists"
else
    fail "install fails clearly when no candidate exists"
fi
export PKG_FAIL_MATCH="__none__"
DRY_RUN="yes"
if install_packages 2>&1 | grep -q "security/cyrus-sasl2-gssapi"; then
    pass "package install uses the renamed sasl gssapi package"
else
    fail "package install uses the renamed sasl gssapi package"
fi
DRY_RUN="no"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
