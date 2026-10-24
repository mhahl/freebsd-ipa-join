# freebsd-ipa-join

Enroll a FreeBSD desktop/server in FreeIPA — the equivalent of Linux's
`ipa-client-install`, which doesn't exist on FreeBSD.

An interactive curses wizard (via `bsddialog`, falling back to `dialog`, then
plain prompts) installs and configures SSSD + Kerberos + LDAP so **all IPA
users and groups resolve on the system**, with **HBAC access control** and
**IPA sudo rules** enforced. It was built for a FreeBSD KDE system installed
via `desktop-installer`, but works on any FreeBSD 13+ host.

## Requirements

- FreeBSD 13 or newer (13/14/15/16; other releases only print a warning)
- Root (`sudo sh freebsd-ipa-client.sh`)
- Network reachability to the IPA server (ports 88, 389, 443, 749)
- An IPA user with host-management rights (e.g. `admin`) — asked for during
  setup, used for enrollment and verification, **never stored**
- Reasonably correct clock (the script enables `ntpd`; Kerberos tolerates
  < 5 min skew)

No manual steps on the IPA server are needed in the default mode.

## Quick start

```sh
sudo sh freebsd-ipa-client.sh
```

The wizard asks for: IPA server, IPA domain, Kerberos realm, this host's
FQDN, the privileged IPA user and their password, then toggles for home-dir
creation, IPA sudo, and HBAC enforcement. Confirm the summary and it runs.

Unattended (automatic mode needs only these five flags):

```sh
sudo sh freebsd-ipa-client.sh --unattended \
  --server idm.example.com --domain example.com \
  --hostname client.example.com --user admin --password '...'
```

## Enrollment modes

| Mode | Flag | How the host keytab is obtained |
|---|---|---|
| `auto` (default) | `--auto` | `kinit` as your admin user, `ipa host-add` server-side, then `ipa-getkeytab` pulls the keytab. No server-side steps. |
| `keytab-file` | `--keytab-file PATH` | Copy a keytab previously exported on the IPA server (`ipa-getkeytab ... -k /root/host.keytab`) and point at it. |
| `keytab-url` | `--keytab-url URL` | Fetch an exported keytab over http(s). Remember to delete it from the web root afterwards. |
| `otp` | `--otp OTP` | Host pre-created with a one-time password (`ipa host-add --password=...`), redeemed via `ipa-getkeytab -P`. |

Get the full option list with `sh freebsd-ipa-client.sh --help`.

## What the script changes

Packages installed via `pkg`: `security/sssd`, `security/sudo`,
`net/openldap26-client`, `security/cyrus-sasl-gssapi`,
`security/pam_mkhomedir`, `security/krb5`, `security/ca_root_nss`,
`net/freeipa-client` (official `ipa` CLI + `ipa-getkeytab`), `bind-tools`.

Files written (originals backed up to `/var/backups/ipa-client`):

- system hostname set to the enrolled FQDN, plus an `/etc/hosts` entry for it (`--ip` overrides the default-route auto-detection)
- `/etc/krb5.conf` — realm, KDC, host keytab location
- `/usr/local/etc/ipa/ca.crt` + `/etc/ipa/ca.crt` — IPA CA certificate
- `/usr/local/etc/ipa/krb5.keytab` (0600) — host keytab
- `/usr/local/etc/openldap/ldap.conf` — GSSAPI + StartTLS against the IPA server
- `/usr/local/etc/sssd/sssd.conf` (0600) — `id/auth/access/chpass/sudo_provider = ipa`
- `/etc/ipa/default.conf` — server/realm pointers for the `ipa` CLI
- `/etc/nsswitch.conf` — `passwd`/`group`/`sudoers: files sss` (local users still win)
- `/etc/pam.d/system`, `/etc/pam.d/sshd` (and `sudo`) — `pam_sss` + `pam_mkhomedir` added compatibly, so KDE/`sddm` logins keep working
- `/etc/ssh/sshd_config`, `/etc/ssh/ssh_config` — GSSAPI enabled
- `sssd` enabled via `sysrc` and (re)started

Enrollment credentials live only in a temporary ccache that is destroyed
after use; the admin password never touches disk.

## Verifying success

The script verifies itself at the end (`kinit`, `getent passwd <user>`,
`sudo -U <user> -l`). Manually:

```sh
id admin                   # IPA user resolves with groups
getent passwd admin
sudo -U admin -l           # IPA sudo rules visible
ssh admin@client.example.com
tail -f /var/log/sssd/*.log
```

> **HBAC denies by design.** If logins fail after enrollment, the host usually
> just isn't allowed yet server-side: add it to an HBAC rule
> (`hbacrule-add --hosts=client.example.com`) or allow list.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `kinit ... failed` | Wrong password, KDC unreachable, or clock skew — run `ntpdate pool.ntp.org` |
| `ipa host-add failed` | User lacks host-management rights; use `admin` or delegate the permission |
| TLS/certificate errors from `ipa` | CA fetch failed; check `https://<server>/ipa/config/ca.crt` is reachable |
| `NSS FAIL` / user not found | `service sssd status`, `/var/log/sssd/`; keytab valid? (`klist -k`) |
| `ipa-getkeytab not found` | `pkg install net/freeipa-client`, or use a manual mode |
| Locked out | Local (break-glass) users bypass SSSD (`files` comes first in nsswitch) |

## Uninstall

```sh
sudo sh freebsd-ipa-client.sh --uninstall
```

Stops `sssd`, disables it, restores all backed-up configs, and removes the
host keytab. Backups are kept in `/var/backups/ipa-client`.

## Tests

`tests/test-enrollment.sh` covers the automatic enrollment logic with stub
`ipa`/`kinit`/`ipa-getkeytab` binaries, so it runs anywhere with POSIX sh:

```sh
sh tests/test-enrollment.sh
```

It checks: `default.conf` content, missing-host add + 0600 keytab pull,
existing-host reuse, abort on keytab failure, missing-tools hint, and
missing-password error.

## Notes

- Re-enrolling an existing host rotates its keytab and invalidates old copies.
- `getent passwd` without arguments lists local users only unless
  `enumerate = True` is set (`--enumerate` flag; slower on large directories).
- Repo layout: `freebsd-ipa-client.sh` (the installer), `tests/` (see above).
