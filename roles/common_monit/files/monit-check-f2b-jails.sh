#!/bin/bash
# Managed by Ansible (common_monit) - do not edit manually.
# Monit `check program` helper: verifies the fail2ban jails that watch nginx's
# log are actually watching a file, not just "running".
#
# Why this exists: found 2026-09-11 on the former K3s setup, a restart of the web
# server had silently disabled all web jails, and nothing noticed, because monit's
# other check only asks whether the fail2ban *process* is alive. A jail with an
# empty file list can never ban anyone again.
#
# Remedy when this fires: `systemctl restart fail2ban`.

command -v fail2ban-client >/dev/null 2>&1 || exit 0
systemctl is-active --quiet fail2ban 2>/dev/null || exit 0   # the service check covers that

empty=""
for jail in $(fail2ban-client status 2>/dev/null \
        | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' '); do
    # Only file-backed jails; sshd uses the systemd journal and has no file list.
    case "$jail" in
        nginx-*) ;;
        *) continue ;;
    esac
    files=$(fail2ban-client status "$jail" 2>/dev/null \
        | sed -n 's/.*File list:[[:space:]]*//p' | tr -d '[:space:]')
    [ -z "$files" ] && empty="$empty $jail"
done

[ -z "$empty" ] && exit 0
echo "fail2ban jails watching no log file (check the nginx log path):${empty}. Fix: systemctl restart fail2ban"
exit 1
