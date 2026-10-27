# PLUGINS(7) - post-enrollment extras for freebsd-ipa-client.sh

## NAME

plugins - optional post-enrollment steps for FreeBSD FreeIPA clients

## SYNOPSIS

```sh
sudo sh freebsd-ipa-client.sh                  # otp + shell-default run by default
sudo sh freebsd-ipa-client.sh --no-plugins     # no plugins at all
sudo sh freebsd-ipa-client.sh --plugins autofs # defaults + extras
sudo sh scripts/otp.sh                          # standalone run
OTP_PAM_FILES=/tmp/test.pam DRY_RUN=yes sh scripts/otp.sh
```

## DESCRIPTION

Each plugin runs after the base configuration is up (before the sssd
restart, so config edits such as `override_shell` apply immediately).
The main script
sources a plugin in a subshell: the plugin sees the helpers (`log`,
`backup_file`, `render_template`) and the variables (`DRY_RUN`,
`BACKUP_DIR`, `IPA_*`, `CLIENT_FQDN`) but cannot leak assignments
back. A nonzero exit aborts the whole run, so a failing plugin never
leaves a half-applied extra. Every file a plugin writes comes from
`templates/`, rendered with `envsubst`; see `templates/README.md`.

`otp` and `shell-default` are enabled by default. `--plugins LIST`
appends extras to the defaults; `--no-plugins` disables every plugin.

## PLUGINS

### otp

Second-factor logins. Enabled by default on new enrollments (disable
with `--no-plugins`). The plugin rewrites `use_first_pass` to
`forward_pass` on the system, sshd, sudo, and LightDM PAM stacks.
`use_first_pass` never prompts, so when the KDC answers with an OTP
challenge SSSD has nothing to reply with and the login dies with
`Preauthentication failed`. `forward_pass` forwards the first password
and still prompts for the OTP code, so SSH and LightDM ask for the
password first and the token second. A single-line pass+OTP keeps
working either way.

SDDM stays uncovered: its helper segfaults on a two-message PAM
conversation, so 2FA users log in through LightDM.

Idempotent; safe to re-run on enrolled hosts. `OTP_PAM_FILES`
overrides the patched file list.

### netgroup-yp

Hostgroup-based sudo. The SSSD `ipa` provider serves no netgroups, so
sudo cannot match `+hostgroup` sudoHost entries through SSSD. This
plugin exports the IPA hostgroups containing this host into
`/etc/netgroup`, which NSS (`compat`) resolves for sudo.

It installs a sync script (`/usr/local/sbin/ipa-netgroup-sync`,
`SYNC_SCRIPT`) plus a cron file (`/etc/cron.d/ipa-netgroups`,
`CRON_FILE`) that runs it hourly and at boot. Each run authenticates
with the host keytab, reads this host's `memberOf` entries under
`cn=hostgroups`, and rewrites the map only on change.
When `ypserv` runs, the script rebuilds the NIS map too; otherwise
sudo uses the static file alone.

Triples use the form `(host,,nisdomain)`. sudo passes
`getdomainname()` as the innetgr domain, and FreeBSD libc
exact-matches every non-empty query field, so a domain-less `(host,,)`
triple stops matching with no error once `nisdomainname` is set. Keep
the two in sync. The source stays in `/etc/netgroup`: the stock
`/var/yp` Makefile deletes a source file named `netgroup`, so keep
the source out of `/var/yp`. Idempotent.

Env: `NIS_DOMAIN`, `HOST_FQDN`, `IPA_SERVER`, `IPA_REALM`,
`IPA_DOMAIN`, `NETGROUP_FILE`, `SYNC_SCRIPT`, `CRON_FILE`,
`YP_SECURNETS`.

### shell-default

Login shell for IPA users. Enabled by default on new enrollments
(disable with `--no-plugins`). Sets `override_shell` in `sssd.conf` so
IPA users land in bash instead of `/bin/sh`. `SHELL_DEFAULT` defaults
to `/usr/local/bin/bash` and must name an installed shell as a full
path; the plugin refuses to run otherwise. The main script installs
`shells/bash` and restarts sssd after the plugin runs, so the override
applies immediately after enrollment. Standalone runs need a manual
`service sssd restart`.

Env: `SHELL_DEFAULT` (default `/usr/local/bin/bash`), `SSSD_CONF`
(default `/usr/local/etc/sssd/sssd.conf`).

### ssh-publish

Host SSH keys in IPA. Reads `ssh_host_*_key.pub` from
`SSH_HOST_KEY_DIR` (default `/etc/ssh`) and sets the full key set on
the host object with one `ipa host-mod` call, which makes the run
idempotent. It authenticates with the host keytab and destroys the
temp ccache afterwards. When the host principal lacks self-modify
rights, publish from the server instead:

```sh
ipa host-mod HOST --sshpubkey="$(cat /etc/ssh/ssh_host_ed25519_key.pub)" ...
```

Env: `SSH_HOST_KEY_DIR`, `HOST_KEYTAB` (default
`/usr/local/etc/ipa/krb5.keytab`). Standalone runs need
`CLIENT_FQDN` and `IPA_REALM` exported when the main script did not
set them.

### autofs

Automount maps from IPA. Adds `autofs` to the sssd services, sets
`autofs_provider=ipa` on the domain, ensures an `[autofs]` section
exists, and enables `automountd`/`autofs`. Maps such as `auto.home`
then come from IPA. Takes effect after `service sssd restart`.

Env: `SSSD_CONF` (default `/usr/local/etc/sssd/sssd.conf`).

### skel-kde

Starter files for auto-created homedirs. Seeds `SKEL_DIR` (default
`/etc/skel`) with minimal Plasma defaults (Breeze `kdeglobals`) and
pins `pam_mkhomedir` to that dir (`skeldir=`) on `SKEL_PAM_FILES`, so
first logins arrive themed instead of stock. Add files under
`SKEL_DIR` to extend it: `pam_mkhomedir` copies them verbatim into
new homedirs with the mode from its config line.

Env: `SKEL_DIR`, `SKEL_PAM_FILES` (default `/etc/pam.d/system
/etc/pam.d/sshd /etc/pam.d/sudo`).

### firefox-sso

Kerberos SSO in Firefox. Writes
`$FIREFOX_DIR/distribution/policies.json` with Authentication
SPNEGO+Delegated for the IPA domains, so Negotiate auth works against
IPA-hosted web apps. The plugin leaves an existing `policies.json`
WITH an `Authentication` section alone, and refuses one WITHOUT, so
merge it by hand instead of clobbering unrelated policy. Policies
apply at next Firefox start; no restart needed.

Env: `IPA_SSO_DOMAINS` (default the IPA domain, comma/space
separated), `FIREFOX_DIR` (default `/usr/local/lib/firefox`).

## STANDALONE USE

Every plugin also runs standalone with `sh`. You need root for the
real paths; point the documented env var elsewhere for a dry look.
A plugin run this way finds `templates/` next to `scripts/` on its
own, but you must have `envsubst` installed (`pkg install
devel/gettext-tools`). Standalone runs use minimal built-in
`log`/`backup_file`
helpers while sourced runs use the main script's. Behavior is
identical either way.

## WRITING A PLUGIN

Put the file in `scripts/` and limit the name to `[A-Za-z0-9_-]`; the
loader rejects anything else before anything runs. Plugins are sourced
in a subshell, never executed directly. Honor `DRY_RUN=yes`: log what
you would do, change nothing. A nonzero exit aborts the whole run, so
fail loudly and never half-apply. Keep every path overridable as
`${VAR:-default}` so it redirects for dry runs. Never write a file
from an inline heredoc: put its full content in `templates/` and
render it with `render_template` plus an explicit variable list, so
runtime `$` in generated scripts survives untouched. Guarded line
edits of pre-existing OS files (`nsswitch.conf`, PAM stacks) stay
procedural: those files vary per host, so no template can hold them.
For standalone runs, source `render.sh` when the main script did not
already define `render_template` (copy the five-line fallback from
`firefox-sso.sh`).

## FILES

`/var/backups/ipa-client` holds the backups the plugins take.

## SEE ALSO

`sh freebsd-ipa-client.sh --help`, `README.md`
