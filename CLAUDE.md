# CLAUDE.md – working notes for AI assistants (and humans) in this repo

This file is read at the start of every Claude Code session. It holds **how we
work here and why things are the way they are**, so that the same lessons do
not have to be learned twice. It is public: no hostnames, addresses, provider
names, personal data or secrets – those stay in the gitignored inventory and
`docs/intern/`.

The long explanations live where the setting lives: in the comments of the
roles (look for "found 2026-…"), in `docs/` (operations guide in DE/EN/FR)
and in the README. This file only points the way and lists the traps.

## Layout

- This repo is the **server**: playbook `blog.yml`, roles `common_*` and `blog_*`.
  The site (posts, images, theme, build and deploy) lives in the private repo
  `www_hugo_content`; it reaches the server as files through `blog-deploy`.
- Sister repo: `nextcloud_k3s` has the same `common_*` roles in their K3s form.
  `scripts/compare-roles.sh` shows the differences. **A fix in a shared role must be
  checked in the other repo** and either taken over or consciously left out.
- Variables: `inventory/group_vars/all/main.yml`, pinned versions in
  `inventory/group_vars/all/versions.yml`. Real `host_vars` are gitignored;
  `*.example` files show the structure.
- Backup scripts: `scripts/blog-backup/` (live copies run on the backup machines).

## How we work

- **Lint the whole repo** before committing: `ansible-lint` (the CI runs it on
  everything, not per role). Pre-commit runs gitleaks, yamllint, ansible-lint.
- **Check mode first** (`--check --diff`), then the real run, **one host at a
  time** and with `-l <host>` (parallel runs on one host collided on the rpm
  lock). Afterwards a drift check (`scripts/check-drift.sh` or the same tags in
  `--check`) must show `changed=0`.
- **After any `--tags` run, also run `--tags common_rkhunter,common_aide_refresh`**,
  otherwise AIDE and rkhunter mail about the changed files at night.
- **Secret check before every commit and push**: read the full diff, grep for
  passwords/keys/IPs. Never print vault contents; mask passwords in command
  output (`MYSQL_PWD`, `REDISCLI_AUTH`, `sed` the `password`/`secret` lines).
- **No push without an explicit OK** from the repository owner.
- **Fix stale comments and docs immediately** when found; docs exist in three
  languages (`docs/blog-operations|-betrieb|-exploitation.html`).
- **Delete only what is certainly dead** – data of disabled apps stays; back up
  first, count live rows.

## Traps we already fell into (and the rule that came out of it)

### SELinux
- **NoNewPrivileges blocks domain transitions.** Under NNP the policy only
  allows a transition into a domain that grants `nnp_transition`. MariaDB
  started via `/bin/sh` stayed in `initrc_t` for five weeks while everything
  said "enforcing" (fix: exec `mariadbd` directly). Redis needed the local module
  `homelab_redis_nnp` (`init_nnp_daemon_domain`). Many sandbox options
  (`SystemCallFilter`, `MemoryDenyWriteExecute`, `RestrictNamespaces`, …)
  **imply** NNP – leaving `NoNewPrivileges` out does not help.
- **After every unit/sandbox change: `ps -eZ | grep <daemon>`**, not only
  `systemctl status`. A daemon can be "active (running)" in the wrong domain.
- **Files Ansible creates inherit the parent directory's type** (e.g. unit
  drop-in directories get `systemd_unit_file_t` instead of `mysqld_unit_file_t`)
  – `restorecon` after creating them.
- **Own domains (`homelab_*`) go through a permissive learning phase first.**
  Export the AVCs, review them, write the rules by hand with refpolicy macros.
  Never apply `audit2allow -M` blindly. Restart the service once in permissive
  mode to catch start-only accesses (bind, config reads) – `audit.log` rotates
  fast while a permissive domain floods it.
- **`dontaudit` rules hide denials** – also in the permissive learning phase,
  which then allows them silently. node_exporter could not read
  `/proc/1/mountinfo` after the switch to enforcing (no AVC, just
  `permission denied` in its own log) and the disk metrics were gone for two
  days. After enforcing: check the service's own log and
  `node_scrape_collector_success`; `semodule -DB` shows hidden denials
  (`semodule -B` restores the rules).

### systemd and SSH
- **SSH sessions are sandboxed** (no writes to kernel tunables, no namespaces):
  `sysctl -w`, `nsenter`, `tcpdump` fail there. Use
  `systemd-run --wait --pipe --collect …`.
- **`/tmp` is on disk and `noexec`** on the hosts; it is not emptied by a
  reboot. Clean up downloads/extractions yourself; run scripts from stdin.
- **`PrivateTmp=yes` and `TemporaryFileSystem=/tmp` must not be combined** –
  the private disk directory wins and the tmpfs is silently ignored.

### nftables and fail2ban
- **Replace only our own table** (`table inet filter` / `delete table inet
  filter` / rebuild, one transaction), never `flush ruleset`.
- **A reload empties our sets** – the handler restarts fail2ban, which re-applies
  its active bans.
- **One set pair per fail2ban jail** (`fail2ban_nft_jails`). With one shared set,
  the unban of a short jail removed addresses that a longer jail still banned.
  Monit's `f2b_sets` check compares fail2ban with the sets.
- MLD packets sit behind a hop-by-hop header, so `nexthdr ipv6-icmp` never
  matches them.

### nginx and HTTP/3
- **HTTP/3 needs nginx mainline with `quic_bpf on`.** Without it a worker kept alive
  by a long connection stays in "shutting down" and still holds the shared UDP 443
  sockets; about 1 of 8 QUIC connections then hung after a reload. 1.26 with
  `quic_bpf` did not help, 1.30.6 hung 40 of 1,000, 1.31.8 hung 0 of 2,370. Test with
  several client stacks and many runs: 8 clean downloads proved nothing, and my first
  suspect (the client) was wrong.
- **`quic_bpf` needs CAP_BPF, CAP_PERFMON and CAP_NET_ADMIN** and the SELinux module
  `homelab_nginx_bpf`.
- SELinux lets nginx bind only certain ports: the local status listener is on 8008,
  8081 was denied.
- **fail2ban cuts the timestamp out of the line before matching**: the regex must be
  `^<HOST> - \S+ [^"]*"...`, without expecting anything between the brackets.

### AlmaLinux 10
- `file_contexts.subs_dist` is **reversed** compared to EL9: `.fc` paths use `/run/…`.
- There is no `/etc/systemd/journald.conf` any more: use a drop-in.
- `audit-rules` is a separate package.
- **`ansible.posix.mount state: mounted` binds again on every run**: more than 2,000
  stacked mounts on `/var/tmp` within a day. fstab with `present`, mount once.
- A weak dependency pulls `kernel-modules-extra`, and the SSH sandbox masks
  `/usr/lib/modules`, so dnf reports "no space": `exclude: kernel*` with
  `install_weak_deps: false`. Kernels stay the job of dnf-automatic.
- Without `container-selinux` the type `container_var_run_t` does not exist.

### Ansible
- **`force_handlers = True`** (ansible.cfg): handlers were lost after an aborted run.
- **ACME is the one step a test VM without DNS cannot prove.** The hook directory only appears on
  certbot's first run. `certbot renew --dry-run` after the real run.
- **`psi=1` needs a reboot after the role set it, and the first-run reboot comes earlier.** On
  AlmaLinux 10 `/proc/pressure` is `proc_psi_t` (`kernel_read_psi`). `irq` answers "not supported"
  on these VMs, so `node_scrape_collector_success{collector="pressure"}` stays 0 although cpu, io
  and memory arrive; the collector alert deliberately does not watch it.
- **Only a real run from zero proves the first install.** A rerun hides what needs an empty
  machine. Three bugs surfaced that way on 2026-11-06 (next three points), each invisible before.
- **`async` must outlast the command.** With `async: 1` and `sleep 2`, ansible-core 2.21 killed
  the reboot, reported `changed`, and the play then waited for a port that never opened. The
  result is in `~/.ansible_async` on the host.
- **Handlers can run before the role they touch.** `systemctl try-restart` exits 5 for a unit that
  does not exist yet, which stopped the first run.
- **`nginx -t` creates an empty pid file while nginx is stopped**, labelled `var_run_t`; nginx in
  `httpd_t` may not open it and does not start. `blog_web` removes an empty one before starting.
- **Background jobs must really detach** (`setsid nohup ... &`). `setsid` alone returns at once and
  looks like a finished run; a job tied to the session dies with it.
- **`'\b'` inside a `when:` string is a backspace** in Jinja. A task ran on every real
  run because of it, hidden in check mode.

### Site and deploy
- The posts live in `www_hugo_content`, not in a database. Everything about Hugo goes
  there.
- **A comment inside a rendered config counts as a change** and restarts the service.
- `/srv/blog` is excluded from AIDE: every deploy changes it.
- **The domain is on the HSTS preload list.** No click-through on certificate warnings for anyone,
  including us: a self-signed test under the real name needs a separate browser profile. A failed
  renewal takes the site offline, so keep a saved certificate at hand when rebuilding.
- **Hugo's default feed lists every page**, so the imprint with the postal address landed in the RSS
  feeds. Feeds and search are posts only; grep the build for private data after template changes.
- **Compare a rebuilt site with the old one line by line.** Yoast had been providing `robots.txt`,
  the sitemap addresses and `twitter:card` without anyone noticing.
- **Releases are hard-linked**: backups need `rsync -H`, or every release counts in full.
- **Restored SSH host keys: `chmod 600`, then `sshd -t`, only then restart.** Keys with mode 640 lost
  their group `ssh_keys` in the copy, sshd did not start and only the provider console could help
  (2026-11-06). A test machine with keys of a different origin did not show it.
- **A test machine can be many times slower than its identical twin** for reasons invisible from
  inside (2026-11-06: reinstall made it 15x faster on disk). Measure before reading anything into
  timings or idle load.

### Monitoring and alerts
- **Grafana alert rules need `condition`**; with `execErrState: OK` a broken rule
  looks green forever. Check the rule state, not the absence of mail.
- Monit watches the services Prometheus/Grafana cannot alert about themselves
  (if Prometheus stops, every rule stays quietly green).

### CI
- **No apostrophe in a comment inside a `shell:` block** – ansible-lint fails
  with `parser-error: failed at splitting arguments` (unbalanced quote).
- A Lint failure after ~30 s is usually `ansible-galaxy` (cache/download), not
  the code – re-run before changing anything.
