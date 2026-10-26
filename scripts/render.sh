#!/bin/sh
# render.sh -- template rendering for freebsd-ipa-client.sh and its plugins.
#
# The main script sources this file at startup after exporting TEMPLATE_DIR
# (resolved from its own SCRIPT_DIR); a plugin sources it only when run
# standalone, that is when the main script did not already define
# render_template.
#
# Resolution order: an exported TEMPLATE_DIR always wins; otherwise assume
# ./templates (running from the repo root); otherwise resolve relative to
# the invoking script, which covers standalone plugin runs from elsewhere
# (scripts/ -> ../templates).
#
# Convention: templates/<name> holds the full content of one generated
# file. Placeholders use shell syntax ($VAR or ${VAR}) and render with an
# explicit variable list, so any other $ in the template (runtime shell
# code in generated scripts) passes through untouched. Templates without
# placeholders copy byte-identical.

if [ -z "${TEMPLATE_DIR:-}" ]; then
    TEMPLATE_DIR=./templates
    if [ ! -d "$TEMPLATE_DIR" ]; then
        TEMPLATE_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/../templates" && pwd -P)"
    fi
fi

# Abort unless TEMPLATE_DIR holds OUR templates. A stale copy, a half-copied
# tree, or a stray TEMPLATE_DIR override can otherwise render foreign
# content (even a package's sample config) straight into system files --
# every render below would "succeed" on the wrong input. Markers are fixed
# strings taken from the shipped templates.
verify_template_tree() {
    _vtt_ok=yes
    _vtt_need krb5.conf 'from templates/krb5.conf'
    _vtt_need ldap.conf 'from templates/ldap.conf'
    _vtt_need ipa-default.conf 'from templates/ipa-default.conf'
    _vtt_need sssd.conf 'from templates/sssd.conf'
    _vtt_need firefox-policies.json '"Authentication"'
    _vtt_need kdeglobals 'plugin skel-kde'
    _vtt_need ipa-netgroup-sync.sh 'plugin netgroup-yp'
    _vtt_need ipa-netgroups.cron 'plugin netgroup-yp'
    _vtt_need securenets '255.255.255.255'
    [ "$_vtt_ok" = yes ] || die "template tree $TEMPLATE_DIR is incomplete or foreign; git pull / re-copy the tree (script + scripts/ + templates/) and unset any stray TEMPLATE_DIR override"
}

_vtt_need() { # $1=file $2=fixed marker text
    if grep -qF -- "$2" "$TEMPLATE_DIR/$1" 2>/dev/null; then
        return 0
    fi
    log "template problem: $TEMPLATE_DIR/$1 is missing or not ours (want marker: $2)"
    _vtt_ok=no
    return 1
}

render_template() { # $1=template name $2=dest [$3='$A $B...'] [$4=mode]
    _rt_tpl="$TEMPLATE_DIR/$1"
    [ -f "$_rt_tpl" ] || die "template missing: $_rt_tpl"
    if [ "${DRY_RUN:-no}" = "yes" ]; then
        log "[dry-run] render $1 -> $2"
        return 0
    fi
    command -v envsubst >/dev/null 2>&1 \
        || die "envsubst not found (pkg install devel/gettext-tools)"
    # Render to a staging file and verify BEFORE touching the destination:
    # a bad render must never clobber a working config (a previous version
    # wrote first and checked second, trashing sssd.conf with a sample).
    # The staging file is left behind on failure for inspection.
    _rt_tmp="$(mktemp "${TMPDIR:-/tmp}/render.XXXXXX")" || die "mktemp failed for $1"
    if [ -n "${3:-}" ]; then
        # envsubst only sees exported variables: export exactly the
        # listed names first, so a typo fails here instead of silently
        # rendering an empty value into a config file.
        # shellcheck disable=SC2086
        for _rt_v in $3; do
            _rt_n="${_rt_v#\$}"
            case "$_rt_n" in
                ''|*[!A-Za-z0-9_]*|[0-9]*) die "bad template variable: $_rt_v" ;;
            esac
            eval "_rt_has=\${$_rt_n:+set}"
            [ -n "$_rt_has" ] || die "template variable unset: $_rt_n (template $1)"
            eval "export $_rt_n"
        done
        # shellcheck disable=SC2086
        envsubst "$3" < "$_rt_tpl" > "$_rt_tmp"
    else
        cp -p "$_rt_tpl" "$_rt_tmp"
    fi
    verify_rendered "$1" "$_rt_tmp"
    backup_file "$2" || true
    mkdir -p "$(dirname "$2")"
    cat "$_rt_tmp" > "$2" # truncate+write keeps the live inode/owner
    rm -f "$_rt_tmp"
    chmod "${4:-644}" "$2"
    # Prove the bytes stuck: re-verify the LIVE file, so a silent write
    # failure can never report success. The byte count in the log is
    # ground truth for every run's output.
    verify_rendered "$1" "$2"
    log "installed $2 ($(wc -c < "$2") bytes)"
}

# Die unless the just-rendered file looks right for its template. This is
# the last line of defense: source mix-ups that slip past
# verify_template_tree (or a template edited into nonsense) fail here,
# before sssd/krb5/ldap ever read the file. Rendered files carry no
# secrets beyond paths and names, so echoing fragments is safe.
verify_rendered() { # $1=template name $2=rendered file
    case "$1" in
        krb5.conf)
            _vr_need "$2" "default_realm = ${IPA_REALM}"
            _vr_need "$2" '[realms]'
            _vr_nodollar "$2"
            ;;
        ldap.conf)
            _vr_need "$2" "BASE        ${LDAP_BASE}"
            _vr_need "$2" "URI         ldap://${IPA_SERVER}/"
            _vr_nodollar "$2"
            ;;
        ipa-default.conf)
            _vr_need "$2" '[global]'
            _vr_need "$2" "host = ${CLIENT_FQDN}"
            _vr_nodollar "$2"
            ;;
        sssd.conf)
            # A missing/empty domain section makes sssd exit with
            # "No domains configured".
            _vr_need "$2" "[domain/${IPA_DOMAIN}]"
            _vr_need_re "$2" '^domains *= *[^ #]'
            _vr_nodollar "$2"
            ;;
        firefox-policies.json)
            _vr_need "$2" '"SPNEGO"'
            _vr_need "$2" "${POLICY_DOMAINS}"
            _vr_nodollar "$2"
            ;;
        ipa-netgroups.cron)
            _vr_need "$2" "${SYNC_SCRIPT}"
            _vr_nodollar "$2"
            ;;
        ipa-netgroup-sync.sh)
            _vr_need "$2" '#!/bin/sh'
            _vr_need "$2" "SYNC_HOST_FQDN=\"${HOST_FQDN}\""
            # No dollar check: runtime shell code legitimately holds $.
            ;;
        kdeglobals|securenets)
            # No placeholders: the copy must be byte-identical.
            cmp -s "$TEMPLATE_DIR/$1" "$2" \
                || die "rendered $2 differs from template $1; refusing to continue"
            ;;
    esac
}

_vr_need() { # $1=file $2=fixed text that must be present
    grep -qF -- "$2" "$1" 2>/dev/null \
        || die "rendered $1 failed check (missing: $2); refusing to continue"
}

_vr_need_re() { # $1=file $2=regex that must match
    grep -q "$2" "$1" 2>/dev/null \
        || die "rendered $1 failed check (no match: $2); refusing to continue"
}

_vr_nodollar() { # $1=file -- no '$' may survive (every $ is a placeholder)
    _vr_left="$(grep -n '\$' "$1" || true)"
    [ -z "$_vr_left" ] \
        || die "rendered $1 has unsubstituted template variables; refusing to continue: ${_vr_left}"
}
