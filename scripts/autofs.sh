#!/bin/sh
# plugin: autofs -- IPA automount maps via SSSD.
#
# Adds autofs to the sssd services, sets autofs_provider=ipa on the domain,
# ensures an [autofs] section, and enables automountd/autofs. Automount maps
# (auto.home etc.) then come from IPA.
#
# Sourced by freebsd-ipa-client.sh:  --plugins autofs
# Also runs directly:  sudo sh scripts/autofs.sh
# Env: SSSD_CONF (default /usr/local/etc/sssd/sssd.conf).
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

SSSD_CONF="${SSSD_CONF:-/usr/local/etc/sssd/sssd.conf}"

[ -f "$SSSD_CONF" ] || { log "plugin autofs: error: $SSSD_CONF missing (enroll this host first?)"; exit 1; }
if [ "${DRY_RUN:-no}" = "yes" ]; then
    log "[dry-run] plugin autofs: services+=autofs, autofs_provider=ipa in $SSSD_CONF; sysrc automountd_enable/autofs_enable"
    exit 0
fi
backup_file "$SSSD_CONF" || true
if grep "^services" "$SSSD_CONF" | grep -q "autofs"; then
    log "plugin autofs: services already include autofs"
else
    grep -q "^services" "$SSSD_CONF" || { log "plugin autofs: error: no services line in $SSSD_CONF"; exit 1; }
    sed -i '' -E "s|^(services *=.*)|\1, autofs|" "$SSSD_CONF"
    log "plugin autofs: added autofs to sssd services"
fi
if grep -q "^autofs_provider" "$SSSD_CONF"; then
    sed -i '' -E "s|^autofs_provider.*|autofs_provider = ipa|" "$SSSD_CONF"
else
    _tmp="$(mktemp)" || exit 1
    awk -v line="autofs_provider = ipa" '
        /^\[domain\// && !inserted { print; print line; inserted=1; next }
        { print }' "$SSSD_CONF" > "$_tmp"
    cat "$_tmp" > "$SSSD_CONF"
    rm -f "$_tmp"
fi
if grep -q "^\[autofs\]" "$SSSD_CONF"; then
    log "plugin autofs: [autofs] section present"
else
    printf '\n[autofs]\n' >> "$SSSD_CONF"
    log "plugin autofs: added [autofs] section"
fi
if command -v sysrc >/dev/null 2>&1; then
    sysrc automountd_enable=YES || log "plugin autofs: warning: sysrc automountd_enable failed"
    sysrc autofs_enable=YES || log "plugin autofs: warning: sysrc autofs_enable failed"
else
    log "plugin autofs: warning: sysrc not found; enable automountd/autofs manually"
fi
log "plugin autofs: done (restart sssd to apply)"
