#!/bin/sh
# plugin: netgroup-yp -- serve this host's IPA hostgroups as NIS netgroups.
#
# sudo matches `+group` sudoHost entries via NSS netgroups, but the SSSD
# ipa provider has no netgroup support, so `+hostgroup` rules can never
# match (getent netgroup <group> comes back empty). This plugin works
# around that with a loopback-only NIS server: a cron job exports the
# hostgroups containing this host into the local NIS netgroup map, which
# ypserv answers on 127.0.0.1 only and ypbind queries pinned to it.
# Triples are written (host,,nisdomain): sudo passes getdomainname() as
# the innetgr domain and FreeBSD libc exact-matches every non-empty
# query field, so a domain-less (host,,) triple stops matching as soon
# as nisdomainname is set. Keep nisdomainname and the triples in sync.
#
# Sourced by freebsd-ipa-client.sh after the base configuration when
# requested:  sh freebsd-ipa-client.sh --plugins netgroup-yp
# Also runs directly:  sudo sh scripts/netgroup-yp.sh
# Uses the main script's log()/backup_file() when sourced, minimal
# built-ins below when run standalone. Honors DRY_RUN.
# Env (all overridable, e.g. to redirect paths for dry runs):
#   NIS_DOMAIN   NIS domain (default: IPA_DOMAIN, must be set one way).
#   HOST_FQDN    this host (default: CLIENT_FQDN from enrollment).
#   IPA_SERVER, IPA_REALM, IPA_DOMAIN (from enrollment; needed to bake the
#                sync script).
#   NETGROUP_FILE netgroup source path (default /etc/netgroup). The sync
#                script owns this file: it doubles as the NSS files
#                fallback (NIS answers first while running). It must NOT
#                live in /var/yp: the stock Makefile deletes a source file
#                named netgroup there after building.
#   SYNC_SCRIPT  sync script path (default /usr/local/sbin/ipa-netgroup-sync).
#   CRON_FILE    cron file path (default /etc/cron.d/ipa-netgroups).
#   YP_SECURNETS ypserv ACL path (default /var/yp/securenets). Created
#                loopback-only; an existing file with other content is a
#                hard error (it would silently expose NIS to the LAN),
#                never clobbered.
# Takes effect after ypinit -m once, starting ypserv/ypbind
# (service ypserv start && service ypbind start) and one sync run.

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

NIS_DOMAIN="${NIS_DOMAIN:-${IPA_DOMAIN:-}}"
HOST_FQDN="${HOST_FQDN:-${CLIENT_FQDN:-}}"
NETGROUP_FILE="${NETGROUP_FILE:-/etc/netgroup}"
SYNC_SCRIPT="${SYNC_SCRIPT:-/usr/local/sbin/ipa-netgroup-sync}"
CRON_FILE="${CRON_FILE:-/etc/cron.d/ipa-netgroups}"
YP_SECURNETS="${YP_SECURNETS:-/var/yp/securenets}"

[ -n "$NIS_DOMAIN" ] || { log "plugin netgroup-yp: error: NIS domain unknown (set NIS_DOMAIN or enroll with --domain first)"; exit 1; }
[ -n "$HOST_FQDN" ] || { log "plugin netgroup-yp: error: host FQDN unknown (set HOST_FQDN or enroll with --hostname first)"; exit 1; }
[ -n "${IPA_SERVER:-}" ] || { log "plugin netgroup-yp: error: IPA server unknown (set IPA_SERVER or enroll first)"; exit 1; }
[ -n "${IPA_REALM:-}" ] || { log "plugin netgroup-yp: error: Kerberos realm unknown (set IPA_REALM or enroll first)"; exit 1; }
[ -n "${IPA_DOMAIN:-}" ] || { log "plugin netgroup-yp: error: IPA domain unknown (set IPA_DOMAIN or enroll first)"; exit 1; }

if ! command -V render_template 2>/dev/null | grep -q 'function'; then
    _rd="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
    # shellcheck source=render.sh
    . "$_rd/render.sh"
fi

# shellcheck disable=SC2034  # reached via the render_template var list below
HOST_SHORT="${HOST_FQDN%%.*}"
# shellcheck disable=SC2034  # reached via the render_template var list below
BASE_DN="$(printf '%s' "$IPA_DOMAIN" | awk -F. '{for(i=1;i<=NF;i++) printf "%sdc=%s", (i>1?",":""), $i}')"
# shellcheck disable=SC2034  # reached via the render_template var list below
YP_DIR="$(dirname "$YP_SECURNETS")"

if [ -f "$YP_SECURNETS" ] && ! cmp -s "$YP_SECURNETS" "$TEMPLATE_DIR/securenets"; then
    log "plugin netgroup-yp: error: $YP_SECURNETS exists with non-loopback content (NIS would be exposed to the LAN); fix it manually to loopback-only first"
    exit 1
fi

if [ "${DRY_RUN:-no}" = "yes" ]; then
    log "[dry-run] plugin netgroup-yp: write $SYNC_SCRIPT (memberOf export for $HOST_FQDN)"
    log "[dry-run] plugin netgroup-yp: write $CRON_FILE (hourly + @reboot)"
    log "[dry-run] plugin netgroup-yp: loopback-only $YP_SECURNETS"
    log "[dry-run] plugin netgroup-yp: sysrc nisdomainname=$NIS_DOMAIN nis_server_enable/nis_client_enable + ypbind pinned to 127.0.0.1"
    exit 0
fi

render_template ipa-netgroup-sync.sh "$SYNC_SCRIPT" '$HOST_FQDN $HOST_SHORT $NIS_DOMAIN $IPA_SERVER $IPA_REALM $BASE_DN $NETGROUP_FILE $YP_DIR' 755
log "plugin netgroup-yp: wrote $SYNC_SCRIPT"

render_template ipa-netgroups.cron "$CRON_FILE" '$SYNC_SCRIPT'
log "plugin netgroup-yp: wrote $CRON_FILE"

if [ -f "$YP_SECURNETS" ]; then
    log "plugin netgroup-yp: $YP_SECURNETS already loopback-only"
else
    render_template securenets "$YP_SECURNETS"
    log "plugin netgroup-yp: wrote loopback-only $YP_SECURNETS"
fi

if command -v sysrc >/dev/null 2>&1; then
    sysrc nisdomainname="$NIS_DOMAIN" || { log "plugin netgroup-yp: error: sysrc nisdomainname failed"; exit 1; }
    sysrc nis_server_enable=YES || { log "plugin netgroup-yp: error: sysrc nis_server_enable failed"; exit 1; }
    sysrc nis_client_enable=YES || { log "plugin netgroup-yp: error: sysrc nis_client_enable failed"; exit 1; }
    sysrc nis_client_flags="-S $NIS_DOMAIN,127.0.0.1" || { log "plugin netgroup-yp: error: sysrc nis_client_flags failed"; exit 1; }
else
    log "plugin netgroup-yp: warning: sysrc not found; enable nisdomainname/nis_server/nis_client manually"
fi
log "plugin netgroup-yp: done (ypinit -m once, then: service ypserv start && service ypbind start && $SYNC_SCRIPT)"
