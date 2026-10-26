#!/bin/sh
# render.sh -- template rendering for freebsd-ipa-client.sh and its plugins.
#
# The main script sources this file at startup after exporting TEMPLATE_DIR
# (resolved from its own SCRIPT_DIR); a plugin sources it only when run
# standalone and render_template is not already defined.

TEMPLATE_DIR="${TEMPLATE_DIR:-$(
    if [ -d ./templates ]; then printf './templates'
    else CDPATH='' cd -- "$(dirname -- "$0")/../templates" && pwd -P
    fi
)}"

render_template() { # $1=template name $2=dest [$3='$A $B...'] [$4=mode]
    _rt_tpl="$TEMPLATE_DIR/$1"
    [ -f "$_rt_tpl" ] || die "template missing: $_rt_tpl"
    if [ "${DRY_RUN:-no}" = "yes" ]; then
        log "[dry-run] render $1 -> $2"
        return 0
    fi
    command -v envsubst >/dev/null 2>&1 \
        || die "envsubst not found (pkg install devel/gettext-tools)"
    backup_file "$2" || true
    mkdir -p "$(dirname "$2")"
    if [ -n "${3:-}" ]; then
        # envsubst only sees exported variables: export exactly the
        # listed names first, so a typo fails here instead of rendering
        # an empty value into a config file.
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
        envsubst "$3" < "$_rt_tpl" > "$2"
    else
        cp -p "$_rt_tpl" "$2"
    fi
    chmod "${4:-644}" "$2"
}
