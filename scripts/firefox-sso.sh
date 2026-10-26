#!/bin/sh
# plugin: firefox-sso -- Kerberos SSO in Firefox for the IPA domain.
#
# Writes $FIREFOX_DIR/distribution/policies.json with Authentication
# SPNEGO+Delegated for the IPA domain(s), so Negotiate auth works against
# IPA-hosted web apps. An existing policies.json WITH an Authentication
# section is left alone; one WITHOUT is refused (merge it manually rather
# than clobber unrelated policy).
#
# Sourced by freebsd-ipa-client.sh:  --plugins firefox-sso
# Also runs directly:  sudo sh scripts/firefox-sso.sh
# Env: IPA_SSO_DOMAINS (default $IPA_DOMAIN; comma/space separated),
#      FIREFOX_DIR (default /usr/local/lib/firefox).
# No restart needed: policies apply at next Firefox start.

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

IPA_SSO_DOMAINS="${IPA_SSO_DOMAINS:-${IPA_DOMAIN:-}}"
FIREFOX_DIR="${FIREFOX_DIR:-/usr/local/lib/firefox}"

[ -n "$IPA_SSO_DOMAINS" ] || { log "plugin firefox-sso: error: set IPA_SSO_DOMAINS (e.g. IPA_SSO_DOMAINS=example.com)"; exit 1; }
if [ ! -d "$FIREFOX_DIR" ]; then
    log "plugin firefox-sso: warning: $FIREFOX_DIR missing (firefox not installed?); nothing to do"
    exit 0
fi
# Domains are validated to [A-Za-z0-9.-] so they embed in JSON unescaped.
_list=""
for _d in $(printf '%s' "$IPA_SSO_DOMAINS" | tr ',' ' '); do
    [ -n "$_d" ] || continue
    case "$_d" in
        *[!A-Za-z0-9.-]*) log "plugin firefox-sso: error: bad domain '$_d'"; exit 1 ;;
    esac
    _list="$_list\"$_d\", "
done
_list="${_list%, }"
[ -n "$_list" ] || { log "plugin firefox-sso: error: no usable domains in '$IPA_SSO_DOMAINS'"; exit 1; }
_pol="$FIREFOX_DIR/distribution/policies.json"
if [ -f "$_pol" ]; then
    if grep -q '"Authentication"' "$_pol"; then
        log "plugin firefox-sso: $_pol already manages Authentication; leaving alone"
        exit 0
    fi
    log "plugin firefox-sso: error: $_pol exists without Authentication; merge manually (refusing to clobber)"
    exit 1
fi
if [ "${DRY_RUN:-no}" = "yes" ]; then
    log "[dry-run] plugin firefox-sso: write $_pol (SPNEGO+Delegated: $IPA_SSO_DOMAINS)"
    exit 0
fi
# shellcheck disable=SC2034  # reached via the render_template var list below
POLICY_DOMAINS="$_list"
render_template firefox-policies.json "$_pol" '$POLICY_DOMAINS'
log "plugin firefox-sso: wrote $_pol"
