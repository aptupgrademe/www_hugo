# common_firewall

Deploys a hardened nftables firewall ruleset on AlmaLinux 10.

## What this role does

- Renders `/etc/sysconfig/nftables.conf` from the template `templates/fw.nft.j2`
- Enables and starts the `nftables` systemd service
- Uses `table inet` – a single ruleset covering both IPv4 and IPv6
- Default policy: **DROP** on INPUT, OUTPUT, and FORWARD
- Creates one native nftables set pair per fail2ban jail (`f2b_<jail>4/6`, list `fail2ban_nft_jails` in group_vars) plus `banned4`/`banned6` for manual bans, all with timeout-based expiry; each jail writes and unbans only in its own sets
- Drops malformed packets (XMAS, NULL), rate-limits RST floods, and rate-limits ICMP/ICMPv6
- Blocks new outgoing connections of the `nginx` user: it serves files and proxies to Grafana on loopback, nothing else

## Ports open by default

| Direction | Port / Protocol | Purpose |
|---|---|---|
| INPUT | 80, 443 TCP | HTTP/HTTPS (nginx) |
| INPUT | 443 UDP | HTTP/3 (QUIC) |
| INPUT | 10022 TCP | SSH (hardened port) |
| INPUT | DHCPv4 (68←67), DHCPv6 (546←547) | Network configuration, only where the uplink uses DHCP |
| INPUT/OUTPUT | established/related | Stateful connection tracking |
| INPUT | ICMPv4 (echo-request, time-exceeded, port-unreachable) | Rate-limited to 10/s |
| INPUT/OUTPUT | ICMPv6 (neighbour discovery, echo, etc.) | Required for IPv6 |

FORWARD stays closed: this host routes nothing.

## Variables

| Variable | Example | Description |
|---|---|---|
| `server_ipv4` | `1.2.3.4` | Public IPv4 address of the server |
| `server_ipv6` | `2a01::1` | Public IPv6 address (optional) |
| `fw_ssh_geo_countries` | `[DE]` | Optional: SSH (10022) only from these countries' IP blocks (RIPE region). Default `[]` = off |
| `fw_ssh_geo_extra` | `["198.51.100.7/32"]` | Optional: extra CIDRs always allowed for SSH when the country filter is on |

## SSH country filter (optional)

With `fw_ssh_geo_countries` set, port 10022 only accepts new connections from
the IP blocks RIPE has delegated to those countries. Web (80/443) is not
affected. `/usr/local/sbin/ssh-geo-update` downloads RIPE's delegation file,
merges the blocks (DE: ~8,700 IPv4 + ~3,100 IPv6, ~1.5 MB kernel memory) and
writes `/etc/nftables/ssh-geo.nft`, which the ruleset includes - so every
reload and boot refills the sets in the same transaction. A weekly timer
(Sun 02:30-03:00) refreshes the list live; on any error (download, stale
data, a list shrinking by more than 20 %) the old list stays. The first
list is built before the ruleset is templated, so a failed download stops
the play before anything could lock SSH out.

    systemctl list-timers ssh-geo-update.timer
    journalctl -u ssh-geo-update.service
    nft get element inet filter ssh_geo4 { 1.2.3.4 }   # is this address allowed?

Locked out (abroad, foreign VPN): use the provider's web console, or add the
address to `fw_ssh_geo_extra` and run the playbook from an allowed network.

## Configuration file

On AlmaLinux the nftables configuration file is `/etc/sysconfig/nftables.conf`,
**not** `/etc/nftables.conf` (which is the path used on Debian/Ubuntu).
The role writes to the correct path.
