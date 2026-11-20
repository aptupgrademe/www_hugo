#!/bin/bash
# =============================================================================
# Blog-Sicherung als komprimiertes Archiv (ersetzt blog_rdiff.sh, 2026-11-20).
#   Quelle: <SRC>/<instanz>: lokal (/data/backup/blog-data) oder über SSH (root@nas::/storage)
#   Ziel:   <DST>/<instanz>_<datum>.tar.gz    (ein Archiv pro Lauf)
#
# Warum kein rdiff-backup mehr: Hugo schreibt bei jedem Build alle ~70.000 Seiten
# neu. rdiff-backup legte pro Lauf 60.000-210.000 kleine Increment-Dateien an;
# auf der SMR-Platte des Backup-PCs dauerte das 2-4 Stunden. Ein Archiv ist ein
# einziger sequenzieller Schreibvorgang (wenige Minuten). Gepackt und
# komprimiert wird auf dem Quellrechner, übertragen wird nur der Datenstrom.
#
# Aufbewahrung: alle Archive der letzten KEEP_DAYS Tage, dazu das erste Archiv
# jedes Monats für KEEP_MONTHS Monate.
#
# Wiederherstellen, z. B. die Website-Dateien des Archivs vom 20.11.2026:
#   tar -xzf /data/backup/blog-archive/blog_2026-11-20_0800.tar.gz -C /tmp/restore blog/site
#   Die damals aktive Fassung liegt dann unter /tmp/restore/blog/site/current/.
# Inhalt ansehen: tar -tzf <archiv> | less
# Ältere Stände bis 2026-11-19 liegen weiter in der rdiff-Historie (blog_rdiff.sh).
#
# Aufruf (backup-all.sh):
#   SRC=root@nas::/storage DST=/data/backup/blog-archive LOGDIR=/data/backup/wordpress/logs blog_tar.sh
# Die Erfolgszeile enthält "=== rdiff erfolgreich", darauf wartet backup-autoshutdown.
# =============================================================================

set -o pipefail
# SRC: host::/pfad (über SSH) oder ein lokaler Pfad.
SRC=${SRC:-/data/backup/blog-data}
SRC_HOST=; SRC_PATH=$SRC
case "$SRC" in *::*) SRC_HOST=${SRC%%::*}; SRC_PATH=${SRC#*::} ;; esac
DST=${DST:-/data/backup/blog-archive}
INSTANCES=${INSTANCES:-"blog"}
LOGDIR=${LOGDIR:-/data/backup/blog/logs}
KEEP_DAYS=${KEEP_DAYS:-30}
KEEP_MONTHS=${KEEP_MONTHS:-12}
KEEP_LOGS=30
# Befehl auf dem Quellrechner ausführen (lokal, wenn SRC keinen Host hat).
on_src() { if [ -n "$SRC_HOST" ]; then ssh -o BatchMode=yes -o ConnectTimeout=15 "$SRC_HOST" "$1"; else bash -c "$1"; fi; }

umask 077
mkdir -p "$DST" "$LOGDIR"
LOG="$LOGDIR/archive_$(date +%Y-%m-%d_%H%M).log"
exec >>"$LOG" 2>&1
log()  { echo "$(date '+%F %T') $*"; }
fail() { log "FEHLER: $*"; log "=== Archiv ABGEBROCHEN ==="; exit 1; }

exec 7>/tmp/blog-archive.lock
flock -n 7 || { log "Archiv läuft bereits – übersprungen"; exit 0; }

log "=== Archiv $SRC -> $DST start ==="
stamp=$(date +%Y-%m-%d_%H%M)
for inst in $INSTANCES; do
    # Auf ein laufendes Backup des Quellrechners warten; ein leerer oder
    # fehlgeschlagener Stand wird nicht archiviert.
    on_src "flock -w 10800 /tmp/blog-backup-$inst.lock true && test -s '$SRC_PATH/$inst/last-success' && test -s '$SRC_PATH/$inst/site/current/index.html'" \
        || fail "Quelle $SRC/$inst nicht bereit (Backup läuft, fehlgeschlagen oder leer)"

    out="$DST/${inst}_$stamp.tar.gz"
    t0=$SECONDS
    # -1: die Bilder sind schon komprimiert; höhere Stufen kosten Zeit für wenig Gewinn.
    on_src "tar -C '$SRC_PATH' --numeric-owner -cf - '$inst' | gzip -1" > "$out.part" \
        || { rm -f "$out.part"; fail "tar/gzip für $inst"; }
    # Prüfen, bevor das Archiv seinen endgültigen Namen bekommt.
    n=$(tar -tzf "$out.part" | wc -l) && [ "$n" -gt 100 ] \
        || { rm -f "$out.part"; fail "Archiv $out.part unlesbar oder fast leer ($n Einträge)"; }
    tar -tzf "$out.part" "$inst/site/current/index.html" >/dev/null \
        || { rm -f "$out.part"; fail "index.html fehlt im Archiv"; }
    mv "$out.part" "$out"
    log "$inst: $(du -h "$out" | cut -f1), $n Einträge, $((SECONDS - t0)) s -> $out"

    # Aufbewahrung: jünger als KEEP_DAYS Tage, oder das erste Archiv seines Monats
    # innerhalb der letzten KEEP_MONTHS Monate.
    cutoff_d=$(date -d "-$KEEP_DAYS days" +%Y-%m-%d)
    cutoff_m=$(date -d "-$KEEP_MONTHS months" +%Y-%m)
    seen=""
    for f in $(ls -1 "$DST/${inst}_"*.tar.gz 2>/dev/null | sort); do
        d=$(basename "$f" .tar.gz); d=${d#"${inst}_"}; day=${d%_*}; mon=${day%-*}
        keep=no
        [[ "$day" > "$cutoff_d" || "$day" == "$cutoff_d" ]] && keep=yes
        if [[ " $seen " != *" $mon "* ]]; then
            seen="$seen $mon"
            [[ "$mon" > "$cutoff_m" || "$mon" == "$cutoff_m" ]] && keep=yes
        fi
        [ "$keep" = yes ] || { rm -f "$f"; log "entfernt (Aufbewahrung): $(basename "$f")"; }
    done
    rm -f "$DST/${inst}_"*.part
done

ls -1t "$LOGDIR"/archive_*.log 2>/dev/null | tail -n +$((KEEP_LOGS + 1)) | xargs -r rm -f
log "Archive: $(ls -1 "$DST"/*.tar.gz | wc -l), zusammen $(du -sh "$DST" | cut -f1)"
log "=== rdiff erfolgreich (Archiv, ${SECONDS}s) ==="
