# templates

Full content of every file the enrollment writes. `render_template`
(`scripts/render.sh`) renders a template to its destination with
`envsubst` and an explicit variable list; anything else carrying a `$`
(runtime shell code in generated scripts) passes through untouched.
Templates without placeholders copy byte-identical.

Map (template -> destination, renderer):

- `krb5.conf` -> `/etc/krb5.conf` (main script)
- `ldap.conf` -> `/usr/local/etc/openldap/ldap.conf` (main script)
- `ipa-default.conf` -> `/usr/local/etc/ipa/default.conf` (main script)
- `sssd.conf` -> `/usr/local/etc/sssd/sssd.conf` (main script, mode 600)
- `kdeglobals` -> `$SKEL_DIR/.config/kdeglobals` (plugin skel-kde)
- `firefox-policies.json` -> `$FIREFOX_DIR/distribution/policies.json`
  (plugin firefox-sso)
- `ipa-netgroup-sync.sh` -> `$SYNC_SCRIPT` (plugin netgroup-yp, mode 755)
- `ipa-netgroups.cron` -> `$CRON_FILE` (plugin netgroup-yp)
- `securenets` -> `$YP_SECURNETS` (plugin netgroup-yp)

Surgical edits of pre-existing OS files (`nsswitch.conf` entries, PAM
stack lines, `sshd_config` flags, `/etc/hosts`, `sssd.conf` service
lists) stay procedural in the scripts: those files vary per host, so
no template can hold them. Every such edit is guarded to run once.
