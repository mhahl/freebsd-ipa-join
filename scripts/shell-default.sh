#!/bin/sh
# plugin: shell-default -- default login shell for IPA users.
#
# Sets override_shell in sssd.conf so IPA users land in /usr/local/bin/bash
# instead of /bin/sh. Refuses to run when the shell is not installed.
#
# Sourced by freebsd-ipa-client.sh (on by default; disable with --no-plugins).
# Also runs directly:
#   sudo sh scripts/shell-default.sh
#   sudo SHELL_DEFAULT=/usr/local/bin/zsh sh scripts/shell-default.sh
# Env: SHELL_DEFAULT (default /usr/local/bin/bash, full path to an installed
#      shell), SSSD_CONF (default /usr/local/etc/sssd/sssd.conf).
# Takes effect after sssd restart:  service sssd restart

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

SHELL_DEFAULT="${SHELL_DEFAULT:-/usr/local/bin/bash}"
SSSD_CONF="${SSSD_CONF:-/usr/local/etc/sssd/sssd.conf}"

[ -n "$SHELL_DEFAULT" ] || { log "plugin shell-default: error: set SHELL_DEFAULT=/path/to/shell (e.g. SHELL_DEFAULT=/usr/local/bin/bash)"; exit 1; }
if [ "${DRY_RUN:-no}" = "yes" ]; then
    log "[dry-run] plugin shell-default: override_shell = $SHELL_DEFAULT in $SSSD_CONF"
    exit 0
fi
[ -x "$SHELL_DEFAULT" ] || { log "plugin shell-default: error: $SHELL_DEFAULT not installed (pkg install shells/bash?)"; exit 1; }
[ -f "$SSSD_CONF" ] || { log "plugin shell-default: error: $SSSD_CONF missing (enroll this host first?)"; exit 1; }
backup_file "$SSSD_CONF" || true
if grep -q "^override_shell" "$SSSD_CONF"; then
    sed -i '' -E "s|^override_shell.*|override_shell = $SHELL_DEFAULT|" "$SSSD_CONF"
else
    _tmp="$(mktemp)" || exit 1
    awk -v line="override_shell = $SHELL_DEFAULT" '
        /^\[domain\// && !inserted { print; print line; inserted=1; next }
        { print }' "$SSSD_CONF" > "$_tmp"
    cat "$_tmp" > "$SSSD_CONF"
    rm -f "$_tmp"
fi
log "plugin shell-default: override_shell = $SHELL_DEFAULT (restart sssd to apply)"
