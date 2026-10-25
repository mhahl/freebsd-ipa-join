#!/bin/sh
# plugin: ssh-publish -- publish host SSH keys to its IPA entry.
#
# Reads $SSH_HOST_KEY_DIR/ssh_host_*_key.pub and sets the full key set on
# the host object (one ipa host-mod call with all keys: idempotent).
# Authenticates with the host keytab (kinit -k); the temp ccache is
# destroyed afterwards. When the host principal lacks self-modify rights,
# publish server-side instead:
#   ipa host-mod HOST --sshpubkey="$(cat /etc/ssh/ssh_host_ed25519_key.pub)" ...
#
# Sourced by freebsd-ipa-client.sh:  --plugins ssh-publish
# Also runs directly (CLIENT_FQDN/IPA_REALM must be exported when the main
# script did not set them):
#   sudo CLIENT_FQDN=h.example.com IPA_REALM=EXAMPLE.COM sh scripts/ssh-publish.sh
# Env: SSH_HOST_KEY_DIR (default /etc/ssh),
#      HOST_KEYTAB (default /usr/local/etc/ipa/krb5.keytab).

# command -v is not enough: macOS ships /usr/bin/log, so require a shell
# function before assuming the main script's helpers are present.
if ! command -V log 2>/dev/null | grep -q 'function'; then
    log() { printf '%s\n' "$*"; }
fi
if ! command -V backup_file 2>/dev/null | grep -q 'function'; then
    backup_file() { # $1=file
        [ -e "$1" ] || return 0
        _bd="${BACKUP_DIR:-/var/backups/ipa-client}"
        mkdir -p "$_bd"
        cp -p "$1" "$_bd/$(echo "$1" | tr '/' '_').bak"
        log "backup: $1 -> $_bd/"
    }
fi

SSH_HOST_KEY_DIR="${SSH_HOST_KEY_DIR:-/etc/ssh}"
HOST_KEYTAB="${HOST_KEYTAB:-/usr/local/etc/ipa/krb5.keytab}"
CLIENT_FQDN="${CLIENT_FQDN:-}"
IPA_REALM="${IPA_REALM:-}"

for _t in ipa kinit kdestroy; do
    if ! command -v "$_t" >/dev/null 2>&1; then
        log "plugin ssh-publish: error: '$_t' not found (pkg install net/freeipa-client?)"
        exit 1
    fi
done
[ -n "$CLIENT_FQDN" ] || { log "plugin ssh-publish: error: CLIENT_FQDN unset (run via --plugins or export it)"; exit 1; }
[ -n "$IPA_REALM" ] || { log "plugin ssh-publish: error: IPA_REALM unset (run via --plugins or export it)"; exit 1; }
[ -f "$HOST_KEYTAB" ] || { log "plugin ssh-publish: error: host keytab $HOST_KEYTAB missing (enroll this host first?)"; exit 1; }

# Collect keys as real argv (--sshpubkey=value form keeps the key's spaces
# intact). set -- is contained: sourced runs execute in a subshell.
set --
for _k in "$SSH_HOST_KEY_DIR"/ssh_host_*_key.pub; do
    [ -e "$_k" ] || continue
    read -r _key < "$_k" || continue
    [ -n "$_key" ] || continue
    set -- "$@" "--sshpubkey=$_key"
done
if [ $# -eq 0 ]; then
    log "plugin ssh-publish: warning: no host keys in $SSH_HOST_KEY_DIR; nothing to publish"
    exit 0
fi
_n=$#
if [ "${DRY_RUN:-no}" = "yes" ]; then
    log "[dry-run] plugin ssh-publish: ipa host-mod $CLIENT_FQDN ($_n keys)"
    exit 0
fi
_old_cc="${KRB5CCNAME:-}"
_cc="$(mktemp "${TMPDIR:-/tmp}/krb5cc_sshpub_XXXXXX")" || exit 1
KRB5CCNAME="FILE:$_cc"
export KRB5CCNAME
_cleanup() {
    kdestroy >/dev/null 2>&1 || true
    if [ -n "$_old_cc" ]; then KRB5CCNAME="$_old_cc"; export KRB5CCNAME; else unset KRB5CCNAME || true; fi
    rm -f "$_cc"
}
if ! kinit -k -t "$HOST_KEYTAB" "host/$CLIENT_FQDN@$IPA_REALM" >/dev/null 2>&1; then
    _cleanup
    log "plugin ssh-publish: error: host kinit failed (keytab valid? clock in sync?)"
    exit 1
fi
log "plugin ssh-publish: authenticated as host/$CLIENT_FQDN"
if ! ipa host-mod "$CLIENT_FQDN" "$@"; then
    _cleanup
    log "plugin ssh-publish: error: ipa host-mod failed (host self-modify allowed? else publish server-side)"
    exit 1
fi
_cleanup
log "plugin ssh-publish: published $_n host keys on $CLIENT_FQDN"
