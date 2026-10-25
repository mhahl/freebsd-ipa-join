#!/bin/sh
# plugin: otp -- allow the OTP/2FA second factor in pam_sss logins.
#
# Rewrites use_first_pass to forward_pass on the system, sshd, sudo, and
# LightDM PAM stacks. use_first_pass never prompts, so when the KDC answers
# with an OTP challenge SSSD has nothing to reply with and the login dies
# with "Preauthentication failed" (no second prompt ever appears).
# forward_pass forwards the first password and still prompts for the OTP
# code, so both SSH and graphical (LightDM) logins get a second token
# prompt. Single-line pass+OTP keeps working either way.
# SDDM is intentionally not covered: its helper cannot drive a two-message
# PAM conversation (it segfaults), so 2FA users log in via LightDM instead.
#
# Sourced by freebsd-ipa-client.sh after the base configuration when
# requested:  sh freebsd-ipa-client.sh --plugins otp
# Also runs directly:  sudo sh scripts/otp.sh
# Uses the main script's log()/backup_file() when sourced, minimal
# built-ins below when run standalone. Honors DRY_RUN.
# OTP_PAM_FILES may list other files (e.g. for dry runs).

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

OTP_PAM_FILES="${OTP_PAM_FILES:-/etc/pam.d/system /etc/pam.d/sshd /etc/pam.d/sudo /usr/local/etc/pam.d/lightdm}"

for _pam in $OTP_PAM_FILES; do
    if [ ! -f "$_pam" ]; then
        log "plugin otp: skip missing $_pam"
        continue
    fi
    if grep -q "pam_sss\.so.*forward_pass" "$_pam"; then
        log "plugin otp: $_pam already forward_pass"
    elif grep -q "pam_sss\.so.*use_first_pass" "$_pam"; then
        if [ "${DRY_RUN:-no}" = "yes" ]; then
            log "[dry-run] plugin otp: upgrade $_pam to forward_pass"
        else
            backup_file "$_pam" || true
            sed -i '' -E "s|pam_sss\.so(.*)use_first_pass|pam_sss.so\1forward_pass|g" "$_pam"
            log "plugin otp: $_pam upgraded to forward_pass (2FA)"
        fi
    elif grep -q "pam_sss\.so" "$_pam"; then
        log "plugin otp: $_pam has pam_sss with no pass flag; leaving alone"
    elif grep -q "include.*system" "$_pam"; then
        log "plugin otp: $_pam has no pam_sss line (covered via system include)"
    else
        log "plugin otp: warning: no pam_sss line in $_pam (base PAM step did not run?)"
    fi
done
