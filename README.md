# Static blog on AlmaLinux 10 – Ansible

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![AlmaLinux](https://img.shields.io/badge/AlmaLinux-10-green.svg)](https://almalinux.org/)
[![nginx](https://img.shields.io/badge/nginx-mainline-009639.svg)](https://nginx.org/)
[![Hugo](https://img.shields.io/badge/Hugo-extended-FF4088.svg)](https://gohugo.io/)

Ansible playbook that turns a fresh AlmaLinux 10 server into a hardened host for
a static website: nginx with HTTP/3, Let's Encrypt, nftables, fail2ban, SELinux
enforcing, Prometheus, Grafana, Loki and Monit. One `ansible-playbook` command
rebuilds the machine from nothing.

This repository holds the **server**, not the website. The site (posts, images,
theme, build and deploy scripts) is built with Hugo elsewhere and only arrives on
the server as finished files.

## Where this comes from

This repository was split from [`www_k3s`](https://github.com/aptupgrademe/www_k3s),
which ran WordPress and Nextcloud on K3s and is now archived. The Nextcloud part
continues in [`nextcloud_k3s`](https://github.com/aptupgrademe/nextcloud_k3s). The
shared `common_*` roles started out identical, so a lesson learned in one repository
is worth checking in the other (`scripts/compare-roles.sh`).

## Architecture

```
Internet
    │  HTTPS (443 TCP), HTTP/3 (443 UDP), HTTP 80 → redirect
    ▼
┌──────────────────────────────────────────────────────────┐
│  AlmaLinux 10 host (SELinux enforcing, nftables)         │
│                                                          │
│  nginx mainline    /srv/blog/current → releases/<id>     │
│    └─ /grafana/ →  Grafana 127.0.0.1 (country filter)    │
│                                                          │
│  Prometheus · node + nginx exporter · Loki · Alloy       │
│  fail2ban · auditd · AIDE · rkhunter · Monit             │
│  dnf-automatic · msmtp · visitor statistics              │
└──────────────────────────────────────────────────────────┘
    ▲
    │  rsync + "activate" with a key that can do nothing else
Build machine (Hugo, Pagefind)
```

There is no PHP, no database, no container runtime and no login for visitors.

## What is in it

### Web server (`blog_web`)

- **nginx.org mainline** instead of the distribution package, because HTTP/3 needs it
  (see below)
- TLS 1.2 + 1.3 only, AEAD ciphers, ECDHE with hybrid post-quantum `X25519MLKEM768`
  offered first, session tickets off, HSTS with preload
- The domain is on the HSTS preload list: nobody can click past a certificate warning, so an
  expired certificate takes the site offline for everyone
- Let's Encrypt through certbot (HTTP-01, webroot); a self-signed certificate until
  then, so a host never answers with a bare TLS reset
- **Atomic deploys and rollback**: the deploy key's forced command `blog-deploy` accepts
  an rsync into `incoming/` and `activate <id>`, which makes a hard-linked release and
  switches a symlink. The last five releases stay. `rollback` and `status` exist too,
  nothing else gets through
- systemd sandbox for nginx (few capabilities, memory limit, read-only system), own
  SELinux module for the BPF part
- nginx may open no outgoing connections except to Grafana on loopback (`common_firewall`)
- Old WordPress addresses keep working (redirects in `nginx.conf.j2`)

### HTTP/3

The former setup had HTTP/3 switched off: after a reload, a worker kept alive by one
long connection still held the shared UDP sockets, and about 1 of 8 QUIC connections
hung. Upstream's answer is `quic_bpf`, which sends every packet to the worker that owns
the connection. Measured on the test machine with reloads under load:

| nginx | Hanging connections |
|---|---|
| 1.26 with `quic_bpf` | no improvement |
| 1.30.6 with `quic_bpf` | 40 of 1,000 |
| 1.31.8 with `quic_bpf` | 0 of 2,370 |

So this host runs mainline, with `quic_bpf on` and `worker_shutdown_timeout 30s`.
`blog_web_http3: false` switches it off in one place, including the firewall rule.

### Firewall and bans

- `table inet filter`, default DROP in all directions, FORWARD closed: the host routes
  nothing (`ip_forward=0`, strict `rp_filter`)
- A reload only replaces this one table, in one transaction
- One nftables set pair per fail2ban jail, because with one shared set the unban of a
  short jail removed addresses that a longer jail still banned; a Monit check compares
  fail2ban with the sets
- Port-scan ban in the kernel; optional country filter for SSH and `/grafana/`

| Jail | Trigger | Ban |
|---|---|---|
| `sshd` | Failed SSH login (3×) | 1 h |
| `nginx-grafana-login` | Failed Grafana login (5× / 10 min) | 1 h |
| `nginx-scanner` | 403/404 storm (20× / 60 s) | 1 h |
| `nginx-bad-paths` | Known-malicious paths, including `/wp-login.php` (2×) | 24 h |
| `recidive` | Banned 3× in one day | 30 days |

### Hardening

SELinux enforcing, with own domains for Prometheus, node_exporter and Grafana. auditd,
AIDE, rkhunter, CIS-based sysctl and mount options, legacy iptables blocked, SSH on port
10022 with keys only, dnf-automatic with a reboot when needed. A 2 GB swap file softens memory
spikes (`sysctl_swap_mb`, 0 removes it).

### Monitoring

Grafana dashboards and mail alerts (disk, RAM, CPU, node down, nginx down, job heartbeats,
SELinux denials, fail2ban errors, OOM kills, error budget), Loki for searchable logs over
14 days, and Monit as the watchdog for what Prometheus cannot report about itself. All of
it listens on 127.0.0.1 only. `blog_verify` runs 30 checks at the end of every run, among
them whether a ban really lands in the kernel and whether metrics really arrive.

## Requirements

**Control node:** ansible-core 2.16+, Python 3.10+, and the collections from `requirements.yml`:
`ansible-galaxy collection install -r requirements.yml`. Optional: `pre-commit`, `ansible-lint`.

**Server:** a fresh AlmaLinux 10 install, public IPv4 with DNS records for
Let's Encrypt, SSH root access on port 22 (moves to 10022 during the first run).

## Quick start

```bash
git clone https://github.com/aptupgrademe/www_hugo.git && cd www_hugo
cp inventory/hosts.yml.example inventory/hosts.yml
mkdir inventory/host_vars/myserver
cp inventory/host_vars/www.apt-upgrade.me/vars.yml.example  inventory/host_vars/myserver/vars.yml
cp inventory/host_vars/www.apt-upgrade.me/vault.yml.example inventory/host_vars/myserver/vault.yml
# Fill in both, then encrypt:
ansible-vault encrypt inventory/host_vars/myserver/vault.yml

ansible-playbook blog.yml --limit myserver --vault-password-file .vault_pass
```

The first run keeps `ansible_port: 22`. It writes the new SSH config and firewall rules but
activates neither mid-run, reboots once so both come up together, reconnects on 10022 and
finishes. Then change `ansible_port` to `10022` in `vars.yml`; Ansible reads the port before
it connects, so this one step cannot be automated away. The play prints a reminder.

Reboot once more after the first run: `psi=1` only takes effect at boot, and the Pressure panel
stays empty until then.

Until the first deploy, the site answers with a short maintenance page. Publishing happens from the
build machine, with the key in `blog_web_deploy_pubkey`:

```bash
rsync -rlt --delete -e "ssh -i <key> -p 10022" public/ blogdeploy@<host>:/srv/blog/incoming/
ssh -i <key> -p 10022 blogdeploy@<host> "activate $(date -u +%Y%m%d-%H%M%S)"
```

## Project structure

```
www_hugo/
├── blog.yml                 # The playbook
├── inventory/
│   ├── hosts.yml            # Inventory (gitignored)
│   ├── group_vars/all/      # main.yml, versions.yml (all version pins)
│   └── host_vars/<host>/    # vars.yml, vault.yml (gitignored), *.example
├── roles/
│   ├── blog_*               # Packages, web server, checks, visitor statistics
│   └── common_*             # SSH, firewall, hardening, monitoring
├── scripts/
│   ├── blog-backup/         # Pull backup for a backup machine, see its README
│   ├── analytics/           # Visitor statistics
│   ├── check-drift.sh       # --check --diff: what would a real run change?
│   └── compare-roles.sh     # Differences to the common_* roles of nextcloud_k3s
└── docs/                    # Operations guide in DE, EN, FR
```

## Secrets

Credentials are never committed. `.gitignore` excludes `inventory/hosts.yml`,
`inventory/host_vars/*/vars.yml`, `inventory/host_vars/*/vault.yml` and `.vault_pass`.
Only `*.example` templates with placeholders are tracked.

## Versions

All pins live in [`inventory/group_vars/all/versions.yml`](inventory/group_vars/all/versions.yml).
Renovate proposes bumps as pull requests, `common_version_check` compares them at every run,
`common_version_active` reports what is pinned but not running. nginx, Grafana and all other
packages come from their repositories and are updated by dnf-automatic.

## Checks

| What | How |
|---|---|
| Lint | `ansible-lint`, `yamllint` |
| Secret scan | `gitleaks` on every commit (pre-commit) and over the full history on GitHub |
| Hooks | `pre-commit install` once per clone |
| CI | `.github/workflows/lint.yml` on every push |
| Real hosts | `scripts/check-drift.sh blog.yml <host>`: exit 1 if a real run would change anything |

## Documentation

| Language | Operations guide |
|---|---|
| Deutsch | [docs/blog-betrieb.html](docs/blog-betrieb.html) |
| English | [docs/blog-operations.html](docs/blog-operations.html) |
| Français | [docs/blog-exploitation.html](docs/blog-exploitation.html) |

## License

MIT License, see [LICENSE](LICENSE). You are free to use, modify and distribute this code.
Please retain the copyright notice and attribution to the original author.
