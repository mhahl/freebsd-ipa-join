# FREEBSD-IPA-CLIENT.SH(8) - enroll FreeBSD in FreeIPA

## NAME

`freebsd-ipa-client.sh` - enroll a FreeBSD host in FreeIPA (users/groups via SSSD, HBAC, sudo)

## SYNOPSIS

```sh
sudo sh freebsd-ipa-client.sh
sudo sh freebsd-ipa-client.sh --unattended --server SERVER --domain DOMAIN \
  --hostname FQDN --user USER --password PASSWORD [--plugins LIST] [--yes]
```

## DESCRIPTION

Configures SSSD + Kerberos + LDAP. Default mode adds the host server-side (`ipa host-add`) and pulls its keytab (`ipa-getkeytab`) with the credentials you enter at setup. No manual steps on the IPA server.

The `otp` (2FA PAM) and `shell-default` (bash login shell) plugins run by default; `--plugins` adds extras without dropping them, and `--no-plugins` turns plugins off entirely.

## OPTIONS

```text
--server FQDN      IPA server. Omitted: discovered via _ldap._tcp SRV.
--domain DOMAIN    IPA DNS domain.
--realm REALM      Kerberos realm. Default: upper(DOMAIN).
--hostname FQDN    This client's FQDN. Default: hostname qualified with DOMAIN.
--ip ADDR          This host's IP for /etc/hosts. Default: default-route interface.
--user NAME        IPA user with host-management rights. Default: admin.
--password PW      Else read with echo disabled; never stored.
--auto             host-add + keytab pull. Default.
--keytab-file PATH Keytab exported on the IPA server.
--keytab-url URL   Keytab fetched over http(s). Remove from web root after.
--otp OTP          One-time host password (host pre-created with OTP).
--plugins LIST     Comma-separated extras from scripts/, added to the
                   defaults otp,shell-default: netgroup-yp, ssh-publish,
                   autofs, skel-kde, firefox-sso.
--no-plugins       Run no plugins at all (disables the defaults too).
--no-mkhomedir     Do not create home dirs on first login.
--no-sudo          Skip IPA sudo provider (installs plain sudo).
--permit           Disable HBAC enforcement. Debug only.
--enumerate        enumerate=True (getent lists ALL users; slow).
--dry-run          Print actions, change nothing.
--unattended       Never prompt; fail if required input is missing.
--yes              Skip final confirmation.
--uninstall        Restore backups, disable sssd, remove host keytab.
--help             Usage.
```

2FA admins: append the OTP to `--password` on a single line.

## EXAMPLES

```sh
sudo sh freebsd-ipa-client.sh
sudo sh freebsd-ipa-client.sh --unattended --server idm.example.com \
  --domain example.com --hostname client.example.com \
  --user admin --password '...' --plugins autofs,skel-kde
sudo sh scripts/otp.sh                     # standalone plugin run
id admin && getent passwd admin            # verify NSS
sudo -U admin -l                           # verify IPA sudo rules
```

## FILES

The script backs up every original to `/var/backups/ipa-client`.
`templates/` (repo only) holds the source of every generated file,
rendered with `envsubst` at install time.

```text
/etc/krb5.conf                     realm, KDC, host keytab location
/etc/nsswitch.conf                 passwd/group/sudoers: files sss
/etc/pam.d/system, sshd, sudo      pam_sss + pam_mkhomedir
/etc/ssh/sshd_config, ssh_config   GSSAPI; UserKeys via sss_ssh_authorizedkeys
/etc/hosts                         FQDN entry; sets system hostname to FQDN
/usr/local/etc/ipa/ca.crt          IPA CA certificate
/usr/local/etc/ipa/krb5.keytab     host keytab, 0600
/usr/local/etc/ipa/default.conf    server/realm pointers (LOCALBASE path)
/usr/local/etc/sssd/sssd.conf      ipa providers, 0600
/usr/local/etc/openldap/ldap.conf  GSSAPI + StartTLS
```

## SEE ALSO

`sh freebsd-ipa-client.sh --help`, `scripts/README.md`
