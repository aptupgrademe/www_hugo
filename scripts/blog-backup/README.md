# Blog backup (pull with rsync, versioning as compressed archives)

Runs on a **backup machine**, not on the blog host. It pulls over SSH as root.
There is no database and no password: the site is files.

```
/data/backup/blog/                 scripts (a copy of this folder) + logs/
/data/backup/blog-data/<name>/
    site/current/   /srv/blog/current: only the live release, as a real directory
    letsencrypt/    /etc/letsencrypt: certificates and the ACME account
    stats/          /var/lib/visitor-stats: the daily visitor counts
    ssh-hostkeys/   /etc/ssh/ssh_host_*: so a rebuilt server keeps its identity
    content/        working copy of the content repo (optional, CONTENT_DIR)
    last-success
/data/backup/blog-archive/         <name>_<date>.tar.gz, one per run: 30 days + the first of each month for 12 months
/data/backup/blog-rdiff/           rdiff-backup history until 2026-11-19 (read-only, see below)
```

All of it is created with `umask 077`: the TLS private key and the SSH host keys
are in there.

| File | Tracked | Purpose |
|---|---|---|
| `blog_backup_lib.sh` | yes | Backup logic: wait for SSH, rsync, check for a start page, stamp |
| `blog_tar.sh` | yes | Versions the instances in `INSTANCES` as one `tar.gz` per run; waits for running backups |
| `blog_rdiff.sh` | yes | The former versioning with rdiff-backup (until 2026-11-19), kept for restoring old states |
| `example_backup.sh.example` | yes | Template for one instance |
| `<name>_backup.sh` | **no** (gitignored) | Filled-in copy with the real hostname |

What is deliberately not saved: metrics and logs (Prometheus, Loki), the older
releases (each deploy gets a new directory name, so a history kept every removed
release in full; the content repo rebuilds them), and everything the playbook rebuilds. The posts live in a Git repository; a copy of
the working tree is only a safety net, including what is not committed yet.

## Setup

```bash
mkdir -p /data/backup/blog && cp -a scripts/blog-backup/. /data/backup/blog/
cd /data/backup/blog && cp example_backup.sh.example blog_backup.sh   # fill in, chmod 750
crontab -e
  45 12 * * * /data/backup/blog/blog_backup.sh
  30 13 * * * /data/backup/blog/blog_tar.sh
```

After every success the blog host gets `/var/lib/blog-backup/last-success`.
Monit (`common_monit`, check `blog_backup`) alerts when it is older than
`monit_backup_max_days` (3). A backup that does not finish leaves no local
`last-success`, and `blog_tar.sh` then refuses to archive that instance.
A test machine without a real certificate sets `LETSENCRYPT=0` in its instance script.

### Split setup: pull host and versioning host

The pull and the versioning can live on different machines, e.g. an always-on NAS that pulls
nightly into its own storage, and a backup PC that only versions what the NAS has:

```sh
# on the NAS (as root), per instance script before sourcing the library:
DATA_ROOT=/storage                    # -> /storage/<name>/{site,letsencrypt,...}
LOGDIR=/var/log/backup/blog
SSH_KEY=/root/.ssh/id_rsa

# on the backup PC: tar + gzip run on the NAS, only the stream crosses the network
30 13 * * * SRC=root@nas::/storage DST=/data/backup/blog-archive /data/backup/blog/blog_tar.sh
```

`blog_tar.sh` first waits on the NAS for a running backup of each instance
and refuses to run if an instance has no `last-success` or no start page (versioning an empty
source would record everything as deleted). The archive is checked (readable, more than 100 entries,
`site/current/index.html` present) before it gets its final name.

### Why archives instead of rdiff-backup (2026-11-20)

Hugo rewrites all ~70,000 pages on every build. rdiff-backup therefore wrote 60,000-210,000 small
increment files per run; on the backup PC's SMR disk that took two to four hours. One archive is a
single sequential write of about 1-2 GB and takes minutes. The archives are self-contained: each one
restores on its own, without the ones before it.

## Restore

The normal way back needs no backup at all: run `blog.yml` on a fresh server, then
deploy from the content repo. The backup saves time and keeps what cannot be rebuilt:

```bash
B=/data/backup/blog-data/blog      # or an older state from an archive:
# mkdir /tmp/blog-old && tar -xzf /data/backup/blog-archive/blog_<date>.tar.gz -C /tmp/blog-old && B=/tmp/blog-old/blog
# states before 2026-11-20 come from the rdiff history:
# rdiff-backup --api-version 201 restore --at 3D /data/backup/blog-rdiff/blog /tmp/blog-3d && B=/tmp/blog-3d
H=root@<blog-host>; SSH="ssh -p 10022"

# Certificates, so a rebuilt server does not need new ones right away
rsync -rlptD -e "$SSH" "$B/letsencrypt/" "$H:/etc/letsencrypt/"
# Visitor counts
rsync -rlptD -e "$SSH" "$B/stats/" "$H:/var/lib/visitor-stats/"
# SSH host keys, so clients do not warn about a changed server
rsync -rlptD -e "$SSH" "$B/ssh-hostkeys/" "$H:/etc/ssh/"
# Check with sshd -t BEFORE restarting: keys with mode 640 lose their group ssh_keys here, sshd
# then refuses them and does not start, and the SSH session is gone (found 2026-11-06).
$SSH $H 'chmod 600 /etc/ssh/ssh_host_*_key; restorecon -R /etc/letsencrypt /var/lib/visitor-stats /etc/ssh; systemctl reload nginx; sshd -t && systemctl restart sshd'
# A published state, without a build: with the deploy key into incoming/, then activate
D="ssh -i <deploy-key> -p 10022"
rsync -rlt --delete --chmod=D755,F644 -e "$D" "$B/site/current/" blogdeploy@<blog-host>:/srv/blog/incoming/
$D blogdeploy@<blog-host> "activate $(date -u +%Y%m%d-%H%M%S)"
```
