#!/bin/bash
# =============================================================================
# Blog-Backup – gemeinsame Logik. Wird von <name>_backup.sh eingebunden, nicht
# direkt aufrufen. Zieht per SSH (root) auf diesen Rechner:
#
#   <DATA_ROOT>/<NAME>/site/           /srv/blog: die ausgelieferten Fassungen
#   <DATA_ROOT>/<NAME>/letsencrypt/    /etc/letsencrypt: Zertifikate und ACME-Konto
#   <DATA_ROOT>/<NAME>/stats/          /var/lib/visitor-stats: die Tageszahlen
#   <DATA_ROOT>/<NAME>/ssh-hostkeys/   /etc/ssh/ssh_host_*: Schlüssel des Servers
#   <DATA_ROOT>/<NAME>/content/        Arbeitskopie des Inhalts-Repos (CONTENT_DIR)
#
# Keine Datenbank, kein Dump, kein Passwort: Die Seite besteht aus Dateien.
# Alles andere baut das Playbook neu auf. Metriken und Logs (Prometheus, Loki)
# werden bewusst nicht gesichert.
# Erfolg schreibt /var/lib/blog-backup/last-success auf dem Server (Monit-Check
# blog_backup warnt, wenn er zu alt wird) und <NAME>/last-success.
# =============================================================================

set -o pipefail
: "${NAME:?}" "${REMOTE_HOST:?}"
REMOTE_USER=${REMOTE_USER:-root}
REMOTE_PORT=${REMOTE_PORT:-10022}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_rsa}
KEEP_LOGS=${KEEP_LOGS:-30}
REMOTE_STAMP=${REMOTE_STAMP:-1}
CONTENT_DIR=${CONTENT_DIR:-}
# Nur für Testmaschinen ohne echtes Zertifikat auf 0 setzen. Sonst fehlende Zertifikate sind ein Fehler.
LETSENCRYPT=${LETSENCRYPT:-1}

# DATA_ROOT/LOGDIR überschreibbar, z. B. auf einem NAS: DATA_ROOT=/storage
DATA_ROOT=${DATA_ROOT:-/data/backup/blog-data}
BASE=$DATA_ROOT/$NAME
LOGDIR=${LOGDIR:-/data/backup/blog/logs}
TS=$(date +%Y-%m-%d_%H%M)
SSH="ssh -i $SSH_KEY -p $REMOTE_PORT -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=15 -o ServerAliveInterval=30"
TARGET="$REMOTE_USER@$REMOTE_HOST"

umask 077   # Der private TLS-Schlüssel und die SSH-Hostschlüssel liegen in der Sicherung
mkdir -p "$BASE" "$LOGDIR"
LOG="$LOGDIR/${NAME}_$TS.log"
exec >>"$LOG" 2>&1

log()  { echo "$(date '+%F %T') $*"; }
fail() { log "FEHLER: $*"; log "=== Backup $NAME ABGEBROCHEN ==="; exit 1; }

exec 9>"/tmp/blog-backup-$NAME.lock"
flock -n 9 || { log "läuft bereits – übersprungen"; exit 0; }

log "=== Backup $NAME start ($TARGET) ==="
# Erst ein vollständiger Lauf setzt den Stempel neu: Solange er fehlt, versioniert rdiff nichts.
rm -f "$BASE/last-success"
for i in $(seq 1 90); do
    $SSH "$TARGET" true 2>/dev/null && break
    [ "$i" -eq 90 ] && fail "$REMOTE_HOST per SSH nicht erreichbar"
    sleep 10
done

pull() {   # pull <Quelle auf dem Server> <Zielordner> [Pflicht=1]
    log "rsync $1 -> $BASE/$2 ..."
    mkdir -p "$BASE/$2"
    rsync -rlptDH --delete --delete-delay --partial --numeric-ids -h --stats \
        -e "$SSH" "$TARGET:$1" "$BASE/$2/" | grep -E "^(Number of (regular )?files|Total transferred|Total file size|Number of deleted)"
    local rc=${PIPESTATUS[0]}
    [ "$rc" -eq 0 ] || [ "$rc" -eq 24 ] || fail "rsync $1 (Exit $rc)"
    return 0
}

pull /srv/blog/ site
[ "$LETSENCRYPT" = 1 ] && pull /etc/letsencrypt/ letsencrypt
pull /var/lib/visitor-stats/ stats
pull '/etc/ssh/ssh_host_*' ssh-hostkeys

# Eine leere Sicherung darf nie als Erfolg gelten: Die aktive Fassung muss eine
# Startseite haben. rdiff würde sonst alles als gelöscht verbuchen.
[ -s "$BASE/site/current/index.html" ] || fail "keine Startseite in $BASE/site/current"

if [ -n "$CONTENT_DIR" ]; then
    [ -d "$CONTENT_DIR/.git" ] || fail "$CONTENT_DIR ist kein Git-Repo"
    log "rsync $CONTENT_DIR -> $BASE/content ..."
    mkdir -p "$BASE/content"
    rsync -rlptD --delete --delete-excluded \
        --exclude=/public/ --exclude=/.tools/ --exclude=/site/resources/ \
        "$CONTENT_DIR/" "$BASE/content/" || fail "rsync content"
fi

if [ "$REMOTE_STAMP" = 1 ]; then
    $SSH "$TARGET" "mkdir -p /var/lib/blog-backup && date '+%F %T' > /var/lib/blog-backup/last-success" \
        || log "Hinweis: Zeitstempel auf $REMOTE_HOST nicht geschrieben"
fi
date '+%F %T' > "$BASE/last-success"
ls -1t "$LOGDIR/${NAME}_"*.log | tail -n +$((KEEP_LOGS + 1)) | xargs -r rm -f
log "=== Backup $NAME erfolgreich (${SECONDS}s) ==="
