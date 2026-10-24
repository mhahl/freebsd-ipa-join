# freebsd-ipa-join

Enrolls FreeBSD in FreeIPA. Linux `ipa-client-install` has no FreeBSD equivalent.

Plain-stdin wizard, no dialog dependency. Configures SSSD + Kerberos + LDAP so all IPA users and groups resolve, with HBAC access control and IPA sudo rules enforced. Built on KDE via `desktop-installer`; runs on any FreeBSD 13+ host.

## Requirements

- FreeBSD 13+. Anything else prints a warning and continues.
- Root.
- Reachability to the IPA server on 88, 389, 443, 749.
- IPA user with host-management rights (e.g. `admin`). Asked for at setup, used for enrollment and verification, never stored.
- Sane clock. The script enables `ntpd`; Kerberos allows < 5 min skew.

Default mode needs no manual steps on the IPA server.

## Quick start

```sh
sudo sh freebsd-ipa-client.sh
```

Prompts for server, domain, realm, client FQDN, host IP, admin user/password, then mkhomedir/sudo/HBAC toggles. Confirm the summary.

```sh
sudo sh freebsd-ipa-client.sh --unattended \
  --server idm.example.com --domain example.com \
  --hostname client.example.com --user admin --password '...'
```

`--unattended` never prompts. Missing input fails fast, confirmation is skipped (`--yes` does that part alone). No terminal means `--password` is mandatory. Omit `--server` when IPA DNS publishes `_ldap._tcp` SRV records: unattended discovers it from `--domain`, interactive offers it as the default.

## Enrollment modes

| Mode | Flag | How the host keytab is obtained |
|---|---|---|
| `auto` (default) | `--auto` | `kinit` as your admin user, `ipa host-add` server-side, then `ipa-getkeytab` pulls the keytab. No server-side steps. |
| `keytab-file` | `--keytab-file PATH` | Copy a keytab previously exported on the IPA server (`ipa-getkeytab ... -k /root/host.keytab`) and point at it. |
| `keytab-url` | `--keytab-url URL` | Fetch an exported keytab over http(s). Delete it from the web root afterwards. |
| `otp` | `--otp OTP` | Host pre-created with a one-time password (`ipa host-add --password=...`), redeemed via `ipa-getkeytab -P`. |

Full list: `sh freebsd-ipa-client.sh --help`.

## What the script changes

```sh
pkg install security/sssd2 security/sudo-sssd net/openldap26-client \
  security/cyrus-sasl2-gssapi security/pam_mkhomedir security/krb5 \
  security/ca_root_nss net/freeipa-client bind-tools
```

Plain `security/sudo` when IPA sudo is off (`--no-sudo`). Repo snapshots vary, so the installer tries the newest package name first and falls back. Post-install it verifies `sudoers: sss` support and dies with rebuild instructions otherwise.

Files written (originals to `/var/backups/ipa-client`):

- system hostname set to the enrolled FQDN, plus an `/etc/hosts` entry (`--ip` overrides default-route auto-detection)
- `/etc/krb5.conf`: realm, KDC, host keytab location
- `/usr/local/etc/ipa/ca.crt`: IPA CA certificate, also where the `ipa` tools verify TLS
- `/usr/local/etc/ipa/krb5.keytab` (0600): host keytab
- `/usr/local/etc/openldap/ldap.conf`: GSSAPI + StartTLS against the IPA server
- `/usr/local/etc/sssd/sssd.conf` (0600): `id/auth/access/chpass/sudo_provider = ipa`
- `/usr/local/etc/ipa/default.conf`: server/realm pointers. Exact path matters, the FreeBSD port reads ipalib config from LOCALBASE, never `/etc/ipa`.
- `/etc/nsswitch.conf`: `passwd`/`group`/`sudoers: files sss`. Local users still win.
- `/etc/pam.d/system`, `/etc/pam.d/sshd` (and `sudo`): `pam_sss` + `pam_mkhomedir` added, KDE/`sddm` logins keep working.
- `/etc/ssh/sshd_config`, `/etc/ssh/ssh_config`: GSSAPI enabled.
- `sssd` enabled via `sysrc` and (re)started.

Enrollment credentials live in a temp ccache, destroyed after use. The admin password never touches disk.

## Verify

The script self-checks at the end. Manual:

```sh
id admin                   # IPA user resolves with groups
getent passwd admin
sudo -U admin -l           # IPA sudo rules visible
ssh admin@client.example.com
tail -f /var/log/sssd/*.log
```

HBAC denies by design. Failed logins after enrollment usually mean the host is not allowed server-side yet: add it to an HBAC rule (`hbacrule-add --hosts=client.example.com`) or allow list.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `kinit ... failed` | Wrong password, KDC unreachable, or clock skew. Try `ntpdate pool.ntp.org`. |
| `ipa host-add failed` | User lacks host-management rights. Use `admin` or delegate the permission. |
| TLS/certificate errors from `ipa` | CA fetch failed. Check `https://<server>/ipa/config/ca.crt` is reachable. |
| `NSS FAIL` / user not found | `service sssd status`, `/var/log/sssd/`, keytab valid (`klist -k`). |
| `ipa-getkeytab not found` | `pkg install net/freeipa-client`, or use a manual mode. |
| Locked out | Local break-glass users bypass SSSD. `files` comes first in nsswitch. |

## Uninstall

```sh
sudo sh freebsd-ipa-client.sh --uninstall
```

Stops `sssd`, disables it, restores all backed-up configs, removes the host keytab. Backups stay in `/var/backups/ipa-client`.

## Tests

Stubs the external tools, runs anywhere with POSIX sh. Covers auto enrollment, hosts handling, SRV discovery, input validation, package fallback, prompt handling.

```sh
sh tests/test-enrollment.sh
```

## Notes

- 2FA/OTP logins work: PAM uses `forward_pass` so the second-factor prompt appears. 2FA admins enter password+OTP in the single password prompt.
- Re-enrolling an existing host rotates its keytab and invalidates old copies.
- Bare `getent passwd` lists local users only unless `enumerate = True` (`--enumerate`, slower on large directories).
