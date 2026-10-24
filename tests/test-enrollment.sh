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

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
