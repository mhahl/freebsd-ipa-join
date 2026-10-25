# plugins (`--plugins`)

Optional post-enrollment steps. The main script sources each requested
plugin after the base configuration is up:

```sh
sudo sh freebsd-ipa-client.sh --plugins sddm-textonly
sudo sh freebsd-ipa-client.sh --plugins sddm-textonly,other   # comma-separated
```

Bundled:

- `sddm-textonly` — text-only SDDM greeter (Breeze, no avatars, no user
  list, no last-user memory). Writes
  `/usr/local/etc/sddm.conf.d/textonly.conf`; takes effect at next sddm
  start. The greeter never enumerates IPA users on screen.
- `otp` — OTP/2FA logins. Rewrites `use_first_pass` to `forward_pass` on
  the system/sshd/sudo PAM stacks so the KDC's second-factor challenge
  reaches a prompt instead of failing with `Preauthentication failed`.
  Idempotent; safe to re-run on already-enrolled hosts.
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
sudo ./scripts/sddm-textonly.sh
SDDM_CONF=/tmp/textonly.conf DRY_RUN=yes sh scripts/sddm-textonly.sh
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
- Keep every path overridable as `${VAR:-default}` so the test suite can
  redirect it (see `sddm-textonly.sh` and `SDDM_CONF`).
