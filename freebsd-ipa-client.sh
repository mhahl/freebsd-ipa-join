#!/bin/sh
# freebsd-ipa-client.sh - FreeIPA client enrollment for FreeBSD
#
# Mimics Linux `ipa-client-install` for FreeBSD using SSSD + Kerberos + LDAP:
#  - installs packages (sssd2, sudo-sssd flavor, SASL/GSSAPI, LDAP,
#    mkhomedir, and the official net/freeipa-client tools)
#  - fetches IPA CA certificate
#  - enrolls automatically: adds the host server-side (ipa host-add) and pulls
#    the host keytab (ipa-getkeytab) using the admin credentials asked for
#    during setup -- no manual server-side steps needed
#  - writes krb5.conf, ldap.conf, sssd.conf (ipa provider: users/groups, HBAC, sudo)
#  - wires up nsswitch.conf, PAM (system/sshd/sudo), SSH (GSSAPI), sudoers via SSSD
#  - enables sssd, verifies with getent/id
#
# Interactive setup uses plain stdin prompts (no dialog/TUI dependency).
#
# Usage:
#   ./freebsd-ipa-client.sh [--uninstall] [--unattended ...] [--help]
#
# Tested against: FreeBSD 13/14/15, FreeIPA 4.9 - 4.13 (RHEL IdM compatible).
# FreeBSD 16: no version gate, warns only when uname differs from 13-16.
#
# Manual enrollment modes (--keytab-file/--keytab-url/--otp) remain as fallback
# when the official client tools cannot be installed.

set -eu

PROG="$(basename "$0")"
BACKUP_DIR="/var/backups/ipa-client"
CA_CRT="/usr/local/etc/ipa/ca.crt"
# NOTE: the FreeBSD port reads ipalib config AND CA from LOCALBASE
# (/usr/local/etc/ipa/), never from /etc/ipa -- see ipaplatform/freebsd.
IPA_CONF="/usr/local/etc/ipa/default.conf"
HOST_KEYTAB="/usr/local/etc/ipa/krb5.keytab"
SSSD_CONF="/usr/local/etc/sssd/sssd.conf"
LDAP_CONF="/usr/local/etc/openldap/ldap.conf"
KRB5_CONF="/etc/krb5.conf"
NSSWITCH_CONF="/etc/nsswitch.conf"
HOSTS_FILE="/etc/hosts"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
PLUGIN_DIR="${PLUGIN_DIR:-$SCRIPT_DIR/scripts}"

# Collected inputs (defaults filled in main)
IPA_SERVER=""
IPA_DOMAIN=""
IPA_REALM=""
CLIENT_FQDN=""
IPA_USER="admin"
IPA_PASSWORD=""
ENROLL_MODE="auto"          # auto | keytab-file | keytab-url | otp
HOST_IP=""                  # this host's IP for /etc/hosts (empty = auto-detect)
KEYTAB_SRC=""               # path or URL for keytab
OTP=""
ENABLE_MKHOMEDIR="yes"
ENABLE_SUDO="yes"
ENABLE_HBAC="yes"
ENUMERATE="no"
DRY_RUN="no"
UNATTENDED="no"
YES="no"
PLUGINS=""               # comma-separated names from scripts/, via --plugins

# ---------------------------------------------------------------- helpers ---

log() { printf '%s\n' "$*"; }
err() { printf '%s: error: %s\n' "$PROG" "$*" >&2; }
die() { err "$*"; exit 1; }

need_root() {
    if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" = "no" ]; then
        die "must run as root (use su / sudo). Try: sudo sh $PROG"
    fi
}

# All prompts below are plain stdin reads: no bsddialog/dialog dependency,
# so there is no TUI layer that can swallow input or abort the script.

t_msg() { # $1=text $2=title
    printf '\n=== %s ===\n%s\n' "${2:-Info}" "$1"
}

t_yesno() { # $1=text $2=title -> 0=yes
    printf '%s (y/n) [y]: ' "$1" >&2
    ans=""; read -r ans || return 1
    case "$ans" in y|Y|yes|YES|"") return 0 ;; *) return 1 ;; esac
}

t_input() { # $1=prompt $2=default -> stdout value
    printf '%s [%s]: ' "$1" "$2" >&2
    ans=""; read -r ans || return 1
    [ -z "$ans" ] && ans="$2"
    printf '%s' "$ans"
}

t_password() { # $1=prompt -> stdout value
    printf '%s: ' "$1" >&2
    stty -echo 2>/dev/null || true
    ans=""; read -r ans || { stty echo 2>/dev/null || true; return 1; }
    stty echo 2>/dev/null || true
    printf '\n' >&2
    printf '%s' "$ans"
}

upper() { printf '%s' "$1" | tr 'a-z' 'A-Z'; }
lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

default_fqdn() { # $1=raw hostname $2=domain -> qualified FQDN
    # short names qualify with the (lowercased) IPA domain instead of a
    # hardcoded suffix; already-qualified names pass through untouched.
    case "$1" in
        *.*) printf '%s' "$1" ;;
        *)   [ -n "${2:-}" ] && printf '%s.%s' "$1" "$(lower "$2")" || printf '%s' "$1" ;;
    esac
}

backup_file() { # $1=file
    [ -e "$1" ] || return 0
    mkdir -p "$BACKUP_DIR"
    cp -p "$1" "$BACKUP_DIR/$(echo "$1" | tr '/' '_').bak"
    log "backup: $1 -> $BACKUP_DIR/"
}

run_or_dry() { # command...
    if [ "$DRY_RUN" = "yes" ]; then
        log "[dry-run] $*"
    else
        "$@"
    fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------ steps ---

prechecks() {
    need_root
    rel="$(uname -r 2>/dev/null || echo unknown)"
    case "$rel" in
        13.*|14.*|15.*|16.*) log "FreeBSD release: $rel" ;;
        *) log "warning: unexpected FreeBSD release '$rel'; continuing anyway" ;;
    esac
    if ! have_cmd pkg; then
        if [ "$DRY_RUN" = "yes" ]; then
            log "warning: pkg(8) not found (non-FreeBSD test host?); continuing dry-run"
        else
            die "pkg(8) not found; this script needs pkg for package installs"
        fi
    fi
    # KDE/desktop-installer coexistence: nothing IPA touches conflicts with KDE.
    # LightDM logins go through /usr/local/etc/pam.d/lightdm (covered by
    # the otp plugin); console/SSH go through /etc/pam.d/system.
    if [ ! -d /usr/local/etc/pam.d ] && [ ! -d /etc/pam.d ]; then
        die "/etc/pam.d missing; not a FreeBSD system?"
    fi
}

have_required_inputs() {
    # 0 when every mandatory input is present (server, domain, hostname,
    # plus OTP for otp mode); used to decide between prompting and failing.
    [ -n "$IPA_SERVER" ] && [ -n "$IPA_DOMAIN" ] && [ -n "$CLIENT_FQDN" ] \
        && { [ "$ENROLL_MODE" != "otp" ] || [ -n "$OTP" ]; }
}

gather_inputs() {
    _raw_host="$(hostname 2>/dev/null || echo client)"

    IPA_DOMAIN="$(t_input "IPA domain (DNS domain, e.g. example.com):" "${IPA_DOMAIN:-}" "IPA domain")" || return 1
    [ -n "$IPA_DOMAIN" ] || { err "IPA domain is required"; return 1; }

    if [ -z "$IPA_SERVER" ]; then
        IPA_SERVER="$(discover_ipa_server "$IPA_DOMAIN")" || true
        if [ -n "$IPA_SERVER" ]; then
            log "discovered IPA server $IPA_SERVER via DNS SRV (_ldap._tcp.$IPA_DOMAIN)"
        fi
    fi
    IPA_SERVER="$(t_input "FreeIPA server FQDN or IP:" "${IPA_SERVER:-}" "IPA server")" || return 1
    [ -n "$IPA_SERVER" ] || { err "IPA server is required"; return 1; }

    IPA_REALM="$(t_input "Kerberos realm (usually UPPER of domain):" "$(upper "$IPA_DOMAIN")" "Realm")" || return 1
    [ -n "$IPA_REALM" ] || IPA_REALM="$(upper "$IPA_DOMAIN")"

    def_fqdn="$(default_fqdn "$_raw_host" "$IPA_DOMAIN")"
    CLIENT_FQDN="$(t_input "This client's FQDN (auto mode adds it to IPA):" "$def_fqdn" "Hostname")" || return 1

    HOST_IP="$(t_input "This host's IP for /etc/hosts (blank to auto-detect):" "$(detect_ip)" "Host IP")" || return 1

    IPA_USER="$(t_input "Privileged IPA user (host management + verify, e.g. admin):" "${IPA_USER:-admin}" "IPA user")" || return 1

    # Enrollment mode menu (numbered, plain stdin)
    printf 'How will this host join IPA?\n' >&2
    printf '  1) auto (recommended): host-add + keytab pull with %s credentials\n' "$IPA_USER" >&2
    printf '  2) keytab-file: copy .keytab file from disk (scp/sneakernet)\n' >&2
    printf '  3) keytab-url: fetch .keytab over http(s) from IPA server\n' >&2
    printf '  4) otp: one-time host password (host pre-created with OTP)\n' >&2
    printf 'Choice [1]: ' >&2
    ans=""; read -r ans || return 1
    case "${ans:-1}" in
        1|auto) ENROLL_MODE="auto" ;;
        2|keytab-file) ENROLL_MODE="keytab-file" ;;
        3|keytab-url) ENROLL_MODE="keytab-url" ;;
        4|otp) ENROLL_MODE="otp" ;;
        *) err "unknown enrollment choice: $ans"; return 1 ;;
    esac

    case "$ENROLL_MODE" in
        auto) ;;
        keytab-file)
            KEYTAB_SRC="$(t_input "Path to exported keytab file:" "/root/$(hostname).keytab" "Keytab")" || return 1 ;;
        keytab-url)
            KEYTAB_SRC="$(t_input "Keytab URL (admin must publish it, then REMOVE it):" "http://$IPA_SERVER/ipa/config/$CLIENT_FQDN.keytab" "Keytab URL")" || return 1 ;;
        otp)
            OTP="$(t_password "One-time password for host $CLIENT_FQDN:" "OTP")" || return 1 ;;
        *) die "unknown enrollment mode: $ENROLL_MODE" ;;
    esac

    IPA_PASSWORD="$(t_password "Password for $IPA_USER (2FA admins: append OTP, single line; never stored):" "IPA password")" || return 1

    t_yesno "Create home dirs on first login (pam_mkhomedir)?" "Homedirs" \
        && ENABLE_MKHOMEDIR="yes" || ENABLE_MKHOMEDIR="no"
    t_yesno "Enable IPA sudo rules (sudo_provider=ipa, sudoers: sss)?" "Sudo" \
        && ENABLE_SUDO="yes" || ENABLE_SUDO="no"
    t_yesno "Enforce HBAC rules (access_provider=ipa)? Say NO only to debug (allow_all)." "HBAC" \
        && ENABLE_HBAC="yes" || ENABLE_HBAC="no"
    return 0
}

confirm_summary() {
    case "$ENROLL_MODE" in
        auto) _enroll="auto (host-add + keytab pull as $IPA_USER)" ;;
        *)    _enroll="$ENROLL_MODE ($KEYTAB_SRC$OTP)" ;;
    esac
    sum="Ready to enroll this host in FreeIPA.

  IPA server : $IPA_SERVER
  Domain     : $IPA_DOMAIN
  Realm      : $IPA_REALM
  Client FQDN: $CLIENT_FQDN
  Host IP    : ${HOST_IP:-(auto-detect)}
  IPA user   : $IPA_USER
  Enroll     : $_enroll
  mkhomedir  : $ENABLE_MKHOMEDIR
  sudo (IPA) : $ENABLE_SUDO
  HBAC       : $ENABLE_HBAC
  Plugins    : ${PLUGINS:-(none)}

Packages will be installed, configs rewritten (backups in $BACKUP_DIR).
Graphical (LightDM) and SSH logins keep working (see --plugins otp for 2FA)."
    t_yesno "$sum" "Confirm"
}

sudo_pkg() {
    # preferred sudo flavor for the current config: only the sssd flavor can
    # read sudoers rules from SSSD (plain security/sudo cannot).
    if [ "$ENABLE_SUDO" = "yes" ]; then
        printf 'security/sudo-sssd'
    else
        printf 'security/sudo'
    fi
}

install_pkg_candidates() {
    # install the first available of the given pkg names (newest name first,
    # older fallbacks after); repo snapshots vary in what they carry.
    for _p in "$@"; do
        if run_or_dry pkg install -y "$_p"; then
            return 0
        fi
        log "warning: package $_p not in repos; trying alternative"
    done
    return 1
}

sudo_supports_sss() {
    # true when the installed sudo can read sudoers from SSSD.
    if command -v sudo >/dev/null 2>&1 \
        && sudo -V 2>/dev/null | grep -qiE 'sss'; then
        return 0
    fi
    if command -v ldd >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1 \
        && ldd "$(command -v sudo)" 2>/dev/null | grep -qi 'sss'; then
        return 0
    fi
    return 1
}

ensure_sudo_sss() {
    # sudoers: sss only works with SSSD-capable sudo; (re)install from pkg,
    # otherwise fail with rebuild instructions instead of silent sudo denial.
    log "== checking sudo SSSD support =="
    if [ "$DRY_RUN" = "yes" ]; then
        log "[dry-run] verify sudo supports sudoers: sss"
        return 0
    fi
    if sudo_supports_sss; then
        log "sudo supports SSSD (sudoers: sss will work)"
        return 0
    fi
    log "sudo lacks SSSD support; reinstalling from pkg ..."
    install_pkg_candidates security/sudo-sssd security/sudo || true
    if sudo_supports_sss; then
        log "sudo now supports SSSD"
        return 0
    fi
    die "sudo still lacks SSSD support. Rebuild the sssd flavor via ports:
  # cd /usr/ports/security/sudo && make config   # FLAVOR=sssd
  # make build deinstall install clean"
}

install_packages() {
    log "== installing packages =="
    # sssd2 carries the IPA provider (sssd-1.x is gone from ports);
    # sudo comes in default/sssd flavors, and only the sssd flavor reads
    # sudoers from SSSD (verified after install by ensure_sudo_sss).
    run_or_dry pkg update
    # shellcheck disable=SC2086
    run_or_dry pkg install -y \
        security/sssd2 \
        net/openldap26-client \
        security/pam_mkhomedir \
        security/krb5 \
        security/ca_root_nss \
        net/freeipa-client \
        bind-tools
    # names below vary across repo snapshots (flavors, renames); take the
    # first candidate that installs, fail clearly when none does.
    if [ "$ENABLE_SUDO" = "yes" ]; then
        install_pkg_candidates security/sudo-sssd security/sudo \
            || die "no sudo package installable (tried sudo-sssd, sudo); check pkg repos"
    else
        run_or_dry pkg install -y security/sudo
    fi
    install_pkg_candidates security/cyrus-sasl2-gssapi security/cyrus-sasl-gssapi \
        || die "no SASL GSSAPI package installable; check pkg repos"
    if ! pkg info -x '^sssd' >/dev/null 2>&1 && [ "$DRY_RUN" = "no" ]; then
        die "sssd2 failed to install; check pkg output above"
    fi
    # net/freeipa-client provides ipa + ipa-getkeytab for auto enrollment
    if ! have_cmd ipa-getkeytab && [ "$DRY_RUN" = "no" ]; then
        log "warning: ipa-getkeytab not found after pkg install;"
        log "warning: auto enrollment needs 'pkg install net/freeipa-client'."
        log "warning: continuing; fall back to a manual mode if auto fails."
    fi
    check_sssd_modules
}

check_sssd_modules() {
    # warn about missing SSSD NSS/PAM modules; the NSS module carries a
    # version suffix (nss_sss.so.1), so match it with a glob.
    _moddir="${SSSD_MODDIR:-/usr/local/lib}"
    if [ ! -e "$_moddir/pam_sss.so" ] && [ "$DRY_RUN" = "no" ]; then
        log "warning: $_moddir/pam_sss.so missing (sssd port without PAM support?)"
    fi
    if ! ls "$_moddir"/nss_sss.so* >/dev/null 2>&1 && [ "$DRY_RUN" = "no" ]; then
        log "warning: nss_sss module missing from $_moddir (sssd port without NSS support?)"
    fi
}

sync_time() {
    log "== time sync (Kerberos needs <5min skew) =="
    # enable first: asking status of a disabled service is unreliable.
    run_or_dry sysrc ntpd_enable=YES
    if [ "$DRY_RUN" = "yes" ]; then
        log "[dry-run] service ntpd start (if not already running)"
        return 0
    fi
    if service ntpd status >/dev/null 2>&1; then
        log "ntpd already running"
    else
        service ntpd start || ntpdate -b "$IPA_SERVER" || true
    fi
}

detect_ip() {
    # IPv4 address of the default-route interface; empty when undetectable.
    _gw_if="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
    if [ -n "$_gw_if" ]; then
        ifconfig "$_gw_if" 2>/dev/null | awk '/^[[:space:]]*inet /{print $2; exit}'
    fi
}

discover_ipa_server() { # $1=domain -> stdout IPA server hostname
    # FreeIPA publishes _ldap._tcp.<domain> SRV records; use the lowest
    # priority target (first listed wins ties). Quiet; fails when none found.
    _srv=""
    if command -v drill >/dev/null 2>&1; then
        _srv="$(drill SRV "_ldap._tcp.$1" 2>/dev/null | awk '$4 == "SRV" {print $5, $7, $8}')"
    elif command -v dig >/dev/null 2>&1; then
        _srv="$(dig +short SRV "_ldap._tcp.$1" 2>/dev/null | awk '{print $1, $3, $4}')"
    else
        return 1
    fi
    [ -n "$_srv" ] || return 1
    _best="$(printf '%s\n' "$_srv" | awk 'NF == 3' | sort -n | head -1 | awk '{print $3}' | sed 's/\.$//')"
    [ -n "$_best" ] || return 1
    printf '%s' "$_best"
}

update_hosts_file() { # $1=hosts file $2=ip $3=fqdn $4=short name; idempotent
    [ -n "$2" ] || return 0
    _esc="$(printf '%s' "$3" | sed 's/\./\\./g')"
    if grep -Eq "[[:space:]]$_esc([[:space:]]|\$)" "$1" 2>/dev/null; then
        sed -i '' -E "/[[:space:]]$_esc([[:space:]]|\$)/s|.*|$2	$3 $4|" "$1"
    else
        printf '%s\t%s %s\n' "$2" "$3" "$4" >> "$1"
    fi
}

configure_hostname_hosts() {
    # Kerberos and SSSD are sensitive to forward resolution of the host FQDN,
    # so pin the system hostname and a hosts entry to the enrolled name.
    log "== hostname + hosts =="
    if [ "$DRY_RUN" = "yes" ]; then
        log "[dry-run] sysrc hostname=$CLIENT_FQDN && hostname $CLIENT_FQDN"
        log "[dry-run] ensure $HOSTS_FILE entry for $CLIENT_FQDN"
        return 0
    fi
    if [ "$(hostname)" != "$CLIENT_FQDN" ]; then
        sysrc hostname="$CLIENT_FQDN"
        hostname "$CLIENT_FQDN"
        log "hostname set to $CLIENT_FQDN"
    else
        log "hostname already $CLIENT_FQDN"
    fi
    _short="${CLIENT_FQDN%%.*}"
    if [ -z "$HOST_IP" ]; then
        HOST_IP="$(detect_ip)"
    fi
    if [ -z "$HOST_IP" ]; then
        log "warning: could not determine host IP; skipping $HOSTS_FILE entry (re-run with --ip <addr>)"
        return 0
    fi
    backup_file "$HOSTS_FILE"
    update_hosts_file "$HOSTS_FILE" "$HOST_IP" "$CLIENT_FQDN" "$_short"
    log "hosts: $HOST_IP $CLIENT_FQDN $_short"
}

fetch_ca() {
    log "== fetching IPA CA certificate =="
    run_or_dry mkdir -p "$(dirname "$CA_CRT")"
    url="https://$IPA_SERVER/ipa/config/ca.crt"
    if [ "$DRY_RUN" = "yes" ]; then
        log "[dry-run] fetch -o $CA_CRT $url"
        return 0
    fi
    backup_file "$CA_CRT" || true
    if fetch -o "$CA_CRT" "$url" 2>/dev/null; then
        :
    elif fetch -o "$CA_CRT" "http://$IPA_SERVER/ipa/config/ca.crt" 2>/dev/null; then
        log "warning: CA fetched over plain http; verify fingerprint server-side"
    else
        die "could not fetch CA from $url (is httpd up? try scp: scp root@$IPA_SERVER:/etc/ipa/ca.crt $CA_CRT)"
    fi
    chmod 644 "$CA_CRT"
    # sanity: must be PEM
    head -1 "$CA_CRT" | grep -q "BEGIN CERTIFICATE" \
        || die "fetched CA is not a PEM certificate; check $CA_CRT"
    log "CA stored at $CA_CRT (also where the ipa tools verify TLS)"
}

_auto_cleanup() { # $1=ccache file $2=previous KRB5CCNAME value (may be empty)
    kdestroy >/dev/null 2>&1 || true
    if [ -n "$2" ]; then KRB5CCNAME="$2"; export KRB5CCNAME; else unset KRB5CCNAME; fi
    rm -f "$1"
}

enroll_auto() {
    # Automatic enrollment with the credentials asked during setup:
    # kinit as the privileged user, add the host server-side (ipa host-add),
    # then pull the host keytab (ipa-getkeytab). Needs net/freeipa-client.
    # Requires krb5.conf + /etc/ipa/default.conf + CA to already be in place.
    for t in ipa ipa-getkeytab kinit kdestroy; do
        if ! command -v "$t" >/dev/null 2>&1; then
            die "auto enrollment needs '$t'. Install the official client tools (pkg install net/freeipa-client), or re-run with --keytab-file/--keytab-url."
        fi
    done
    if [ -z "$IPA_PASSWORD" ]; then
        die "auto enrollment needs the password for $IPA_USER (--password or interactive prompt)"
    fi
    _old_cc="${KRB5CCNAME:-}"
    _cc="$(mktemp "${TMPDIR:-/tmp}/krb5cc_ipa_XXXXXX")" || die "mktemp for Kerberos ccache failed"
    KRB5CCNAME="FILE:$_cc"
    export KRB5CCNAME
    _rc=0
    printf '%s' "$IPA_PASSWORD" | kinit "$IPA_USER@$IPA_REALM" >/dev/null 2>&1 || _rc=$?
    if [ "$_rc" -ne 0 ]; then
        _auto_cleanup "$_cc" "$_old_cc"
        die "kinit as $IPA_USER@$IPA_REALM failed (wrong password? 2FA admins append the OTP to the password, single line. KDC at $IPA_SERVER reachable? clock in sync?)"
    fi
    log "authenticated to IPA as $IPA_USER"
    if REQUESTS_CA_BUNDLE="$CA_CRT" ipa host-show "$CLIENT_FQDN" </dev/null >/dev/null 2>&1; then
        log "host $CLIENT_FQDN already exists in IPA; reusing entry (keytab will be rotated)"
    else
        log "adding host $CLIENT_FQDN to IPA ..."
        if ! REQUESTS_CA_BUNDLE="$CA_CRT" ipa host-add "$CLIENT_FQDN" --force </dev/null; then
            _auto_cleanup "$_cc" "$_old_cc"
            die "ipa host-add failed (does $IPA_USER have permission to manage hosts?)"
        fi
    fi
    mkdir -p "$(dirname "$HOST_KEYTAB")"
    if ! ipa-getkeytab -s "$IPA_SERVER" \
            -p "host/$CLIENT_FQDN@$IPA_REALM" -k "$HOST_KEYTAB"; then
        _auto_cleanup "$_cc" "$_old_cc"
        die "ipa-getkeytab failed to pull the host keytab from $IPA_SERVER"
    fi
    chmod 0600 "$HOST_KEYTAB"
    if command -v klist >/dev/null 2>&1; then
        klist -k "$HOST_KEYTAB" | head -5 || log "warning: klist -k failed"
    fi
    _auto_cleanup "$_cc" "$_old_cc"
    log "host keytab pulled automatically to $HOST_KEYTAB"
}

install_keytab() {
    log "== installing host keytab ($ENROLL_MODE) =="
    if [ "$DRY_RUN" = "yes" ]; then log "[dry-run] install keytab -> $HOST_KEYTAB"; return 0; fi
    mkdir -p "$(dirname "$HOST_KEYTAB")"
    backup_file "$HOST_KEYTAB" || true
    case "$ENROLL_MODE" in
        auto)
            enroll_auto ;;
        keytab-file)
            [ -f "$KEYTAB_SRC" ] || die "keytab file not found: $KEYTAB_SRC
Create it on the IPA server first:
  [root@ipa]# ipa host-add $CLIENT_FQDN --force
  [root@ipa]# ipa-getkeytab -s $IPA_SERVER -p host/$CLIENT_FQDN@$IPA_REALM -k /root/$CLIENT_FQDN.keytab
  then copy it here (scp) and re-run."
            install -m 0600 -o root -g wheel "$KEYTAB_SRC" "$HOST_KEYTAB" ;;
        keytab-url)
            fetch -o "$HOST_KEYTAB" "$KEYTAB_SRC" \
                || die "keytab fetch failed. Publish it server-side first:
  [root@ipa]# cp /root/$CLIENT_FQDN.keytab /usr/share/ipa/html/ && chmod 644 ...
  then REMOVE it after enrollment."
            chmod 0600 "$HOST_KEYTAB"
            log "REMINDER: delete the published keytab from the IPA web root now." ;;
        otp)
            if ! have_cmd ipa-getkeytab; then
                die "ipa-getkeytab not found. Install it (pkg install net/freeipa-client) or use keytab-file mode instead:
  [root@ipa]# ipa host-add $CLIENT_FQDN --password='<otp>' --force
  [root@ipa]# ipa-getkeytab -s $IPA_SERVER -p host/$CLIENT_FQDN@$IPA_REALM -k /root/$CLIENT_FQDN.keytab"
            fi
            echo "$OTP" | ipa-getkeytab -s "$IPA_SERVER" \
                -p "host/$CLIENT_FQDN@$IPA_REALM" -k "$HOST_KEYTAB" -P \
                || die "ipa-getkeytab with OTP failed"
            chmod 0600 "$HOST_KEYTAB" ;;
        *) die "unknown enrollment mode: $ENROLL_MODE" ;;
    esac
    # validate
    if have_cmd klist; then
        klist -k "$HOST_KEYTAB" | head -5 || log "warning: klist -k failed"
    fi
    # wipe OTP from memory-ish
    OTP=""
}

write_krb5_conf() {
    log "== writing $KRB5_CONF =="
    [ "$DRY_RUN" = "yes" ] && { log "[dry-run] write $KRB5_CONF"; return 0; }
    backup_file "$KRB5_CONF"
    cat > "$KRB5_CONF" <<EOF
# Generated by $PROG on $(date -u +%FT%TZ) - backup in $BACKUP_DIR
[libdefaults]
  default_realm = $IPA_REALM
  default_keytab_name = FILE:$HOST_KEYTAB
  dns_lookup_realm = false
  dns_lookup_kdc = false
  rdns = false
  ticket_lifetime = 24h
  forwardable = yes

[realms]
  $IPA_REALM = {
    kdc = $IPA_SERVER:88
    master_kdc = $IPA_SERVER:88
    admin_server = $IPA_SERVER:749
    default_domain = $IPA_DOMAIN
    pkinit_anchors = FILE:$CA_CRT
  }

[domain_realm]
  .$IPA_DOMAIN = $IPA_REALM
  $IPA_DOMAIN = $IPA_REALM
EOF
    chmod 644 "$KRB5_CONF"
}

write_ldap_conf() {
    log "== writing $LDAP_CONF =="
    [ "$DRY_RUN" = "yes" ] && { log "[dry-run] write $LDAP_CONF"; return 0; }
    backup_file "$LDAP_CONF"
    mkdir -p "$(dirname "$LDAP_CONF")"
    dc="$(printf '%s' "$IPA_DOMAIN" | awk -F. '{for(i=1;i<=NF;i++) printf "%sdc=%s", (i>1?",":""), $i}')"
    cat > "$LDAP_CONF" <<EOF
# Generated by $PROG - backup in $BACKUP_DIR
BASE        $dc
URI         ldap://$IPA_SERVER/
SASL_MECH   GSSAPI
SASL_REALM  $IPA_REALM
ssl         start_tls
TLS_CACERT  $CA_CRT
TLS_REQCERT demand
EOF
    chmod 644 "$LDAP_CONF"
}

write_ipa_conf() {
    # Minimal client config so the official tools (ipa CLI) know which
    # server/realm to talk to before this host is enrolled. Must live at
    # /usr/local/etc/ipa/default.conf: that is the path the FreeBSD port
    # actually reads (ipaplatform/freebsd), /etc/ipa is never consulted.
    log "== writing $IPA_CONF =="
    [ "$DRY_RUN" = "yes" ] && { log "[dry-run] write $IPA_CONF"; return 0; }
    backup_file "$IPA_CONF"
    mkdir -p "$(dirname "$IPA_CONF")"
    cat > "$IPA_CONF" <<EOF
# Generated by $PROG on $(date -u +%FT%TZ) - backup in $BACKUP_DIR
[global]
host = $CLIENT_FQDN
server = $IPA_SERVER
realm = $IPA_REALM
domain = $IPA_DOMAIN
xmlrpc_uri = https://$IPA_SERVER/ipa/xml
EOF
    chmod 644 "$IPA_CONF"
}

write_sssd_conf() {
    log "== writing $SSSD_CONF (users/groups + HBAC + sudo) =="
    [ "$DRY_RUN" = "yes" ] && { log "[dry-run] write $SSSD_CONF"; return 0; }
    backup_file "$SSSD_CONF"
    mkdir -p "$(dirname "$SSSD_CONF")"
    mkdir -p /var/log/sssd /var/db/sss 2>/dev/null || true
    if [ "$ENABLE_HBAC" = "yes" ]; then access="ipa"; else access="permit"; fi
    if [ "$ENABLE_SUDO" = "yes" ]; then
        services="nss, pam, ssh, sudo"; sudoprov="ipa"
    else
        services="nss, pam, ssh"; sudoprov="# disabled"
    fi
    cat > "$SSSD_CONF" <<EOF
# Generated by $PROG on $(date -u +%FT%TZ) - backup in $BACKUP_DIR
[domain/$IPA_DOMAIN]
cache_credentials = True
krb5_store_password_if_offline = True
krb5_realm = $IPA_REALM
ipa_domain = $IPA_DOMAIN
id_provider = ipa
auth_provider = ipa
access_provider = $access
chpass_provider = ipa
sudo_provider = $sudoprov
ipa_hostname = $CLIENT_FQDN
ipa_server = $IPA_SERVER
ldap_tls_cacert = $CA_CRT
krb5_keytab = $HOST_KEYTAB
enumerate = $ENUMERATE
subdomains_provider = ipa

[sssd]
services = $services
config_file_version = 2
domains = $IPA_DOMAIN

[nss]
filter_users = root,toor
homedir_substring = /home
# all IPA users/groups resolve via NSS (getent passwd / id);
# enumerate=False keeps lookups on-demand (fast). getent without
# args lists only local users unless enumerate=True.

[pam]

[sudo]

[ssh]
EOF
    chown root:wheel "$SSSD_CONF" 2>/dev/null \
        || log "warning: chown root:wheel failed (continuing; ensure root owns $SSSD_CONF)"
    chmod 600 "$SSSD_CONF"
}

configure_nsswitch() {
    log "== configuring $NSSWITCH_CONF =="
    [ "$DRY_RUN" = "yes" ] && { log "[dry-run] update $NSSWITCH_CONF"; return 0; }
    backup_file "$NSSWITCH_CONF"
    # Idempotent: ensure sss entries exist with files first (break-glass local users win)
    set_entry() { # $1=db $2=value
        if grep -q "^$1:" "$NSSWITCH_CONF"; then
            sed -i '' "s|^$1:.*|$1:      $2|" "$NSSWITCH_CONF"
        else
            printf '%s:      %s\n' "$1" "$2" >> "$NSSWITCH_CONF"
        fi
    }
    set_entry passwd "files sss"
    set_entry group "files sss"
    if [ "$ENABLE_SUDO" = "yes" ]; then set_entry sudoers "files sss"; fi
    log "nsswitch: $(grep -E '^(passwd|group|sudoers):' "$NSSWITCH_CONF" | tr '\n' ';')"
}

patch_pam_file() { # $1=pam file
    f="$1"
    [ -f "$f" ] || { log "skip missing $f"; return 0; }
    backup_file "$f"
    # OTP/2FA prompting lives in the otp plugin (--plugins otp), not here:
    # the base install stays single-prompt (use_first_pass).
    if grep -q "pam_sss.so" "$f"; then
        log "$f already has pam_sss"
    else
        tmp="$(mktemp)"
        awk '
          /^auth.*pam_unix\.so/ && !a_done { print "auth\t\tsufficient\t/usr/local/lib/pam_sss.so\t\tuse_first_pass"; a_done=1 }
          /^account.*pam_unix\.so/ && !c_done { print "account\t\trequired\t/usr/local/lib/pam_sss.so\t\tignore_unknown_user ignore_authinfo_unavail"; c_done=1 }
          /^password.*pam_unix\.so/ && !p_done { print "password\tsufficient\t/usr/local/lib/pam_sss.so\t\tuse_authtok"; p_done=1 }
          { print }
        ' "$f" > "$tmp"
        cat "$tmp" > "$f"
        rm -f "$tmp"
        log "patched $f"
    fi
    # session mkhomedir appended once (runs on every path)
    if [ "$ENABLE_MKHOMEDIR" = "yes" ] && ! grep -q "pam_mkhomedir" "$f"; then
        printf 'session\t\trequired\t/usr/local/lib/pam_mkhomedir.so\t\tmode=0700\n' >> "$f"
    fi
}

configure_pam_ssh() {
    log "== configuring PAM + SSH =="
    [ "$DRY_RUN" = "yes" ] && { log "[dry-run] patch PAM/SSH"; return 0; }
    patch_pam_file /etc/pam.d/system
    patch_pam_file /etc/pam.d/sshd
    if [ -f /etc/pam.d/sudo ] && ! grep -q pam_sss /etc/pam.d/sudo; then
        backup_file /etc/pam.d/sudo
        cp -p /etc/pam.d/system /etc/pam.d/sudo
        log "linked sudo PAM to system PAM (with sss)"
    fi
    # SSH GSSAPI for SSO + UsePAM so HBAC/sudo/session rules apply
    for f in /etc/ssh/sshd_config; do
        grep -q "^GSSAPIAuthentication" "$f" \
            || printf '\nGSSAPIAuthentication yes\n' >> "$f"
        grep -q "^UsePAM" "$f" || printf 'UsePAM yes\n' >> "$f"
    done
    grep -q "GSSAPIAuthentication" /etc/ssh/ssh_config 2>/dev/null \
        || printf '\nGSSAPIAuthentication yes\n' >> /etc/ssh/ssh_config
    # /home -> /usr/home compat (FreeBSD home root)
    [ -e /home ] || ln -s /usr/home /home
}

enable_services() {
    log "== enabling services =="
    run_or_dry sysrc sssd_enable=YES
    if [ "$DRY_RUN" = "no" ]; then
        rm -rf /var/db/sss/db/* 2>/dev/null || true
        service sssd restart || service sssd start
        sleep 2
        service sssd status || log "warning: sssd not running; see /var/log/sssd/"
    fi
}

run_plugins() {
    # Optional post-config steps from scripts/ (e.g. --plugins otp).
    # Each plugin is sourced in a subshell: it sees the main script's helpers
    # (log, backup_file) and variables (DRY_RUN, BACKUP_DIR, IPA_*, ...), but
    # cannot leak assignments back. A failing plugin aborts the run so
    # half-applied extras never go unnoticed. PLUGIN_DIR is overridable
    # (the test suite points it at fixtures).
    [ -z "${PLUGINS:-}" ] && return 0
    log "== running plugins: $PLUGINS =="
    _rest="$PLUGINS"
    while [ -n "$_rest" ]; do
        case "$_rest" in
            *,*) _p="${_rest%%,*}"; _rest="${_rest#*,}" ;;
            *)   _p="$_rest"; _rest="" ;;
        esac
        case "$_p" in
            ""|*/*|*".."*|*[!A-Za-z0-9_-]*)
                die "bad plugin name '$_p' (comma-separated names from $PLUGIN_DIR)" ;;
        esac
        _f="$PLUGIN_DIR/$_p.sh"
        [ -f "$_f" ] || die "plugin not found: $_f (ships in scripts/; see scripts/README.md)"
        log "--- plugin: $_p ---"
        ( . "$_f" ) || die "plugin '$_p' failed"
    done
}

verify() {
    log "== verifying =="
    if [ "$DRY_RUN" = "yes" ]; then log "[dry-run] verify (skipped)"; return 0; fi
    fails=0
    echo "--- kinit as $IPA_USER (checks realm/KDC/CA) ---"
    if printf '%s' "$IPA_PASSWORD" | kinit "$IPA_USER@$IPA_REALM"; then
        klist | head -4
        kdestroy || true
    else
        log "kinit failed: check realm/server/password, DNS, time skew"; fails=$((fails+1))
    fi
    # wipe password ASAP
    IPA_PASSWORD=""
    echo "--- NSS: IPA user lookup ---"
    if getent passwd "$IPA_USER" || id "$IPA_USER"; then
        log "NSS OK: $IPA_USER resolves"
    else
        log "NSS FAIL: $IPA_USER not found; check sssd.conf, keytab, HBAC, 'getent passwd'"; fails=$((fails+1))
    fi
    echo "--- sudo rules ---"
    if [ "$ENABLE_SUDO" = "yes" ]; then
        if sudo -U "$IPA_USER" -l 2>&1 | head -10; then
            log "(exit $?) sudo lookup ran; 'not allowed' is fine, errors are not"
        else
            log "note: sudo -U returned nonzero (often normal when no rule matches)"
        fi
    fi
    echo "--- HBAC ---"
    if [ "$ENABLE_HBAC" = "yes" ]; then
        log "HBAC enforced via access_provider=ipa."
        log "Allow this host in IPA: hbacrule-add --hosts=$CLIENT_FQDN (or add to allow_all)."
    else
        log "HBAC DISABLED (permit): for debugging only; re-enable for production."
    fi
    if [ "$fails" -gt 0 ]; then
        return 1
    fi
    return 0
}

do_uninstall() {
    need_root
    t_yesno "Remove IPA enrollment (restore backups, disable sssd)?" "Uninstall" || exit 0
    service sssd stop 2>/dev/null || true
    sysrc -x sssd_enable 2>/dev/null || true
    for f in "$KRB5_CONF" "$SSSD_CONF" "$LDAP_CONF" "$NSSWITCH_CONF" \
             "$IPA_CONF" "$HOSTS_FILE" \
             /etc/pam.d/system /etc/pam.d/sshd /etc/pam.d/sudo; do
        b="$BACKUP_DIR/$(echo "$f" | tr '/' '_').bak"
        if [ -f "$b" ]; then cp -p "$b" "$f"; log "restored $f"; fi
    done
    rm -f "$HOST_KEYTAB"
    log "unenrolled. Backups kept in $BACKUP_DIR."
}

usage() {
    cat <<EOF
$PROG - enroll FreeBSD in FreeIPA (like ipa-client-install)

Interactive (curses) when run without flags:
  sudo sh $PROG

Unattended (auto mode needs only server/domain/hostname/user/password):
  sudo sh $PROG --unattended --server IDM.EXAMPLE.COM --domain example.com \\
    --hostname client.example.com --user admin --password '...'

Options:
  --server FQDN        IPA server (default: DNS SRV discovery)
  --domain DOMAIN      IPA DNS domain
  --realm REALM        Kerberos realm (default: upper(domain))
  --hostname FQDN      this client's FQDN
  --ip ADDR            this host's IP for the /etc/hosts entry (default: auto-detect)
  --user NAME          IPA user with host-management rights (default: admin)
  --password PW        (else prompted securely; never stored)
  --auto               automatic host-add + keytab pull (default)
  --keytab-file PATH  manual: keytab exported on IPA server
  --keytab-url URL     manual: keytab fetched over http(s)
  --otp OTP            manual: one-time host password (needs ipa-getkeytab)
  --no-mkhomedir       do not auto-create home dirs
  --no-sudo            skip IPA sudo provider
  --permit             disable HBAC enforcement (access=permit, debug only)
  --enumerate          set enumerate=True (lists ALL users in getent; slow)
  --plugins LIST       comma-separated extras from scripts/ (e.g. otp,netgroup-yp)
  --dry-run            print actions without changing the system
  --unattended         never prompt: fail if required inputs are missing
  --yes                skip the final confirmation
  --uninstall          restore backups and disable sssd
  --help               this text
EOF
}

# ------------------------------------------------------------------- main ---

main() {
    # non-interactive flag parsing (all optional; missing -> prompted)
    while [ $# -gt 0 ]; do
        case "$1" in
            --server) IPA_SERVER="$2"; shift 2 ;;
            --domain) IPA_DOMAIN="$2"; shift 2 ;;
            --realm) IPA_REALM="$2"; shift 2 ;;
            --hostname) CLIENT_FQDN="$2"; shift 2 ;;
            --ip) HOST_IP="$2"; shift 2 ;;
            --user) IPA_USER="$2"; shift 2 ;;
            --password) IPA_PASSWORD="$2"; shift 2 ;;
            --plugins) PLUGINS="$2"; shift 2 ;;
            --auto) ENROLL_MODE="auto"; shift ;;
            --keytab-file) ENROLL_MODE="keytab-file"; KEYTAB_SRC="$2"; shift 2 ;;
            --keytab-url) ENROLL_MODE="keytab-url"; KEYTAB_SRC="$2"; shift 2 ;;
            --otp) ENROLL_MODE="otp"; OTP="$2"; shift 2 ;;
            --no-mkhomedir) ENABLE_MKHOMEDIR="no"; shift ;;
            --no-sudo) ENABLE_SUDO="no"; shift ;;
            --permit) ENABLE_HBAC="no"; shift ;;
            --enumerate) ENUMERATE="True"; shift ;;
            --dry-run) DRY_RUN="yes"; shift ;;
            --uninstall) do_uninstall; exit 0 ;;
            --yes) YES="yes"; shift ;;
            --unattended) UNATTENDED="yes"; YES="yes"; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown option: $1 (see --help)" ;;
        esac
    done

    prechecks
    t_msg "This wizard enrolls FreeBSD in FreeIPA (users/groups via SSSD-IPA, HBAC access control, sudo rules).\n\nAutomatic mode adds this host server-side and pulls its keytab using the admin credentials you enter -- no manual steps on the IPA server.\n\nExisting desktop (LightDM/KDE): untouched except compatible PAM additions." "FreeIPA client for FreeBSD"

    # unattended discovery: --domain alone suffices when DNS SRV exists
    if [ "$UNATTENDED" = "yes" ] && [ -z "$IPA_SERVER" ] && [ -n "$IPA_DOMAIN" ]; then
        IPA_SERVER="$(discover_ipa_server "$IPA_DOMAIN")" || true
        if [ -n "$IPA_SERVER" ]; then
            log "discovered IPA server $IPA_SERVER via DNS SRV (_ldap._tcp.$IPA_DOMAIN)"
        fi
    fi

    # prompt for anything still missing (interactive or fail in unattended)
    if ! have_required_inputs; then
        if [ "$UNATTENDED" = "yes" ]; then
            die "unattended mode needs --server, --domain and --hostname (plus --otp for otp mode)"
        fi
        gather_inputs || exit 1
    else
        [ -z "$IPA_REALM" ] && IPA_REALM="$(upper "$IPA_DOMAIN")"
        if [ -z "$IPA_PASSWORD" ] && [ "$DRY_RUN" = "no" ]; then
            if [ "$UNATTENDED" = "yes" ] && [ ! -t 0 ]; then
                die "unattended mode needs --password (no terminal to prompt on)"
            fi
            IPA_PASSWORD="$(t_password "Password for $IPA_USER (2FA admins: append OTP, single line; never stored):" "IPA password")" || exit 1
        fi
    fi

    if [ "$YES" = "no" ]; then
        confirm_summary || { log "cancelled."; exit 0; }
    else
        log "proceeding without confirmation (--yes)"
    fi

    install_packages
    if [ "$ENABLE_SUDO" = "yes" ]; then
        ensure_sudo_sss
    fi
    sync_time
    configure_hostname_hosts
    fetch_ca
    # krb5 + ipa client config must precede auto enrollment (kinit/ipa CLI)
    write_krb5_conf
    write_ldap_conf
    write_ipa_conf
    install_keytab
    write_sssd_conf
    configure_nsswitch
    configure_pam_ssh
    enable_services
    run_plugins

    if verify; then
        t_msg "Enrolled OK.\n\nTest: ssh '$IPA_USER@$(hostname)' / id $IPA_USER / sudo -U $IPA_USER -l\nHBAC: grant this host access server-side or logins are denied (by design).\nSudo rules come from IPA (sudoers: sss). Logs: /var/log/sssd/." "Done"
    else
        t_msg "Enrollment finished WITH WARNINGS (see output).\nCheck: kinit, /var/log/sssd/*, 'getent passwd $IPA_USER', clock skew, HBAC rule." "Attention"
        exit 1
    fi
}

main "$@"
