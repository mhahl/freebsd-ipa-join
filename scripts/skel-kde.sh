#!/bin/sh
# plugin: skel-kde -- KDE starter files for auto-created homedirs.
#
# Seeds SKEL_DIR (default /etc/skel) with minimal Plasma defaults
# (.config/kdeglobals: Breeze) and pins pam_mkhomedir to that dir
# (skeldir=) on SKEL_PAM_FILES, so first logins are themed instead of
# stock. Extend by adding files under $SKEL_DIR: they are copied verbatim
# into new homedirs with the mode from the pam_mkhomedir line.
#
# Sourced by freebsd-ipa-client.sh:  --plugins skel-kde
# Also runs directly:  sudo sh scripts/skel-kde.sh
# Env: SKEL_DIR (default /etc/skel),
#      SKEL_PAM_FILES (default /etc/pam.d/system /etc/pam.d/sshd /etc/pam.d/sudo).

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

if ! command -V render_template 2>/dev/null | grep -q 'function'; then
    _rd="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
    # shellcheck source=render.sh
    . "$_rd/render.sh"
    verify_template_tree
fi

SKEL_DIR="${SKEL_DIR:-/etc/skel}"
SKEL_PAM_FILES="${SKEL_PAM_FILES:-/etc/pam.d/system /etc/pam.d/sshd /etc/pam.d/sudo}"

if [ "${DRY_RUN:-no}" = "yes" ]; then
    log "[dry-run] plugin skel-kde: seed $SKEL_DIR/.config/kdeglobals; pin skeldir=$SKEL_DIR on pam_mkhomedir"
    exit 0
fi
render_template kdeglobals "$SKEL_DIR/.config/kdeglobals"
log "plugin skel-kde: seeded $SKEL_DIR/.config/kdeglobals"
for _pam in $SKEL_PAM_FILES; do
    if [ ! -f "$_pam" ]; then
        log "plugin skel-kde: skip missing $_pam"
        continue
    fi
    if ! grep -q "pam_mkhomedir" "$_pam"; then
        log "plugin skel-kde: warning: no pam_mkhomedir in $_pam (mkhomedir disabled?)"
        continue
    fi
    if grep "pam_mkhomedir" "$_pam" | grep -q "skeldir="; then
        log "plugin skel-kde: $_pam already pins skeldir"
        continue
    fi
    backup_file "$_pam" || true
    sed -i '' -E "s|(.*pam_mkhomedir\.so.*)|\1 skeldir=$SKEL_DIR|" "$_pam"
    log "plugin skel-kde: $_pam pins skeldir=$SKEL_DIR"
done
