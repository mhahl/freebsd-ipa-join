# plugins (`--plugins`)

Optional post-enrollment steps. The main script sources each requested
plugin after the base configuration is up:

```sh
sudo sh freebsd-ipa-client.sh --plugins otp
sudo sh freebsd-ipa-client.sh --plugins otp,other   # comma-separated
```

Bundled:

- `otp` — OTP/2FA logins. Rewrites `use_first_pass` to `forward_pass` on
  the system/sshd/sudo/LightDM PAM stacks so the KDC's second-factor
  challenge reaches a prompt instead of failing with `Preauthentication
  failed`. Both SSH and LightDM then ask for the password first and the
  OTP value second (two-step). SDDM is not covered on purpose: its helper
  segfaults on a two-message PAM conversation, so 2FA users log in via
  LightDM instead. Idempotent; safe to re-run on already-enrolled hosts.
  `OTP_PAM_FILES` overrides the patched file list.
- `netgroup-yp` — export this host's IPA hostgroups into `/etc/netgroup`
  so sudo can match `+hostgroup` sudoHost entries (the SSSD ipa provider
  has no netgroup support). Installs a cron-driven export script
  (host keytab + `memberOf` lookup); the file doubles as the NSS files
  fallback. Optionally also stands up a loopback-only ypserv/ypbind pair
  serving the same data over NIS (ypbind pinned to 127.0.0.1); the stock
  Makefile deletes a source file named `netgroup` under `/var/yp`, so
  the source must live in `/etc/netgroup`. Triples are written
  `(host,,nisdomain)`: sudo passes `getdomainname()` as the innetgr
  domain and FreeBSD libc exact-matches every non-empty query field, so
  a domain-less `(host,,)` triple silently stops matching once
  nisdomainname is set — keep the two in sync. Idempotent.
- `shell-default` — sets `override_shell` in `sssd.conf` (`SHELL_DEFAULT`
  env, must be installed). Restart sssd to apply.
- `ssh-publish` — uploads the host's `ssh_host_*_key.pub` keys to its IPA
  entry via host-keytab auth. Full key set each run; idempotent.
- `autofs` — IPA automount maps: `autofs` service + `autofs_provider=ipa`
  in sssd, `[autofs]` section, enables `automountd`/`autofs`.
- `skel-kde` — seeds `SKEL_DIR` (default `/etc/skel`) with Breeze
  `kdeglobals` and pins `pam_mkhomedir` to it (`skeldir=`).
- `firefox-sso` — Firefox `policies.json` with SPNEGO+Delegated for
  `IPA_SSO_DOMAINS` (default the IPA domain). Never clobbers an existing
  policy carrying `Authentication`.

## running directly

Every plugin also runs standalone with `sh` (needs root for the real
paths; point the documented env var elsewhere for a dry look):

```sh
sudo sh scripts/otp.sh
OTP_PAM_FILES=/tmp/test.pam DRY_RUN=yes sh scripts/otp.sh
```

Standalone runs use minimal built-in `log`/`backup_file` helpers; sourced
runs use the main script's. Behavior is identical either way.

## writing a plugin

- File `scripts/<name>.sh`, name limited to `[A-Za-z0-9_-]` (no paths;
  anything else is rejected before anything runs).
- Plugins are **sourced in a subshell**, never executed directly. You get
  the main script's helpers (`log`, `backup_file`) and variables
  (`DRY_RUN`, `BACKUP_DIR`, `IPA_*`, `CLIENT_FQDN`).
- Honor `DRY_RUN=yes`: log what you would do, change nothing.
- Any nonzero exit aborts the whole run. Fail loudly, never half-apply.
- Keep every path overridable as `${VAR:-default}` so it can be
  redirected for dry runs (see `otp.sh` and `OTP_PAM_FILES`).
