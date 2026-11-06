#!/bin/bash
# Managed by Ansible (common_monit) - do not edit manually.
# Monit `check program` helper: warns before a TLS certificate actually
# expires. certbot renews at 30 days remaining, so anything still under
# MIN_DAYS means renewal has been failing for a while and nobody noticed -
# without this check that only surfaces when the old cert expires and the site
# goes dark.
#
# Hostnames come from /etc/monit-tls-hosts (written by the role).
#
# Checks what is actually *served* on :443 via SNI over 127.0.0.1 - not the
# certificate file - because that is what a browser really gets, and it needs
# no working public DNS to run.

MIN_DAYS="${1:-21}"

command -v openssl >/dev/null 2>&1 || exit 0

hosts=$(cat /etc/monit-tls-hosts 2>/dev/null)
[ -z "$hosts" ] && exit 0
allow_selfsigned=$(cat /etc/monit-tls-selfsigned-ok 2>/dev/null || echo no)

problems=""

for host in $hosts; do
    cert=$(echo | timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$host" 2>/dev/null)
    if [ -z "$cert" ]; then
        problems="$problems; $host: no certificate served (TLS handshake failed)"
        continue
    fi

    end=$(echo "$cert" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -z "$end" ]; then
        problems="$problems; $host: could not read certificate expiry"
        continue
    fi

    left=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))

    # A self-signed cert is what blog_web starts with. On a production host it
    # means the ACME issuance has not completed.
    subject=$(echo "$cert" | openssl x509 -noout -subject 2>/dev/null | sed 's/^subject=//')
    issuer=$(echo "$cert" | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//')
    if [ "$subject" = "$issuer" ]; then
        [ "$allow_selfsigned" = yes ] && continue
        problems="$problems; $host: still on the self-signed certificate - ACME has not issued one"
        continue
    fi

    if [ "$left" -lt "$MIN_DAYS" ]; then
        problems="$problems; $host: expires in ${left}d (certbot renews at 30d)"
    fi
done

[ -z "$problems" ] && exit 0
echo "TLS certificate problems${problems}"
exit 1
