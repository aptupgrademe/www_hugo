# Blog backup (pull, rsync + rdiff-backup)

Runs on a **backup machine**, not on the blog host. It pulls over SSH as root.
There is no database and no password: the site is files.

```
/data/backup/blog/                 scripts (a copy of this folder) + logs/
/data/backup/blog-data/<name>/
    site/           /srv/blog: the published releases and the "current" link
    letsencrypt/    /etc/letsencrypt: certificates and the ACME account
    stats/          /var/lib/visitor-stats: the daily visitor counts
    ssh-hostkeys/   /etc/ssh/ssh_host_*: so a rebuilt server keeps its identity
    content/        working copy of the content repo (optional, CONTENT_DIR)
    last-success
/data/backup/blog-rdiff/           rdiff-backup history of blog-data (365 days)
```

All of it is created with `umask 077`: the TLS private key and the SSH host keys
are in there.

| File | Tracked | Purpose |
|---|---|---|
| `blog_backup_lib.sh` | yes | Backup logic: wait for SSH, rsync, check for a start page, stamp |
| `blog_rdiff.sh` | yes | Versions the instances in `INSTANCES`; waits for running backups |
| `example_backup.sh.example` | yes | Template for one instance |
| `<name>_backup.sh` | **no** (gitignored) | Filled-in copy with the real hostname |

What is deliberately not saved: metrics and logs (Prometheus, Loki), and
everything the playbook rebuilds. The posts live in a Git repository; a copy of
the working tree is only a safety net, including what is not committed yet.

## Setup

```bash
mkdir -p /data/backup/blog && cp -a scripts/blog-backup/. /data/backup/blog/
cd /data/backup/blog && cp example_backup.sh.example blog_backup.sh   # fill in, chmod 750
crontab -e
  45 12 * * * /data/backup/blog/blog_backup.sh
  30 13 * * * /data/backup/blog/blog_rdiff.sh
```

After every success the blog host gets `/var/lib/blog-backup/last-success`.
Monit (`common_monit`, check `blog_backup`) alerts when it is older than
`monit_backup_max_days` (3).

### Split setup: pull host and versioning host

The pull and the versioning can live on different machines, e.g. an always-on NAS that pulls
nightly into its own storage, and a backup PC that only versions what the NAS has:

```sh
# on the NAS (as root), per instance script before sourcing the library:
DATA_ROOT=/storage                    # -> /storage/<name>/{site,letsencrypt,...}
LOGDIR=/var/log/backup/blog
SSH_KEY=/root/.ssh/id_rsa

# on the backup PC: rdiff-backup over SSH (same rdiff-backup version on both sides)
30 13 * * * SRC=root@nas::/storage /data/backup/blog/blog_rdiff.sh
```

With a remote `SRC`, `blog_rdiff.sh` first waits on the NAS for a running backup of each instance
and refuses to run if an instance has no `last-success` or no start page (versioning an empty
source would record everything as deleted).

## Restore

The normal way back needs no backup at all: run `blog.yml` on a fresh server, then
deploy from the content repo. The backup saves time and keeps what cannot be rebuilt:

```bash
B=/data/backup/blog-data/blog      # or an older state:
# rdiff-backup --api-version 201 restore --at 3D /data/backup/blog-rdiff/blog /tmp/blog-3d && B=/tmp/blog-3d
H=root@<blog-host>; SSH="ssh -p 10022"

# Certificates, so a rebuilt server does not need new ones right away
rsync -rlptD -e "$SSH" "$B/letsencrypt/" "$H:/etc/letsencrypt/"
# Visitor counts
rsync -rlptD -e "$SSH" "$B/stats/" "$H:/var/lib/visitor-stats/"
$SSH $H 'restorecon -R /etc/letsencrypt /var/lib/visitor-stats; systemctl reload nginx'
# A published state, without a build: with the deploy key into incoming/, then activate
D="ssh -i <deploy-key> -p 10022"
rsync -rlt --delete --chmod=D755,F644 -e "$D" "$B/site/current/" blogdeploy@<blog-host>:/srv/blog/incoming/
$D blogdeploy@<blog-host> "activate $(date -u +%Y%m%d-%H%M%S)"
```
