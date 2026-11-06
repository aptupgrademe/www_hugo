#!/bin/bash
# =============================================================================
# Shows how the shared common_* roles differ from the sister repo.
#
#   scripts/compare-roles.sh [path to nextcloud_k3s]          list per role
#   scripts/compare-roles.sh [path] common_fail2ban           full diff of one role
#
# The roles started out identical when the repos were split. Differences caused
# by the stack (K3s or not) are expected; a fix that exists on one side only is
# what this is for. Read-only.
# =============================================================================
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
OTHER=${1:-$HERE/../nextcloud_k3s}
ROLE=${2:-}
[ -d "$OTHER/roles" ] || { echo "no roles/ in $OTHER" >&2; exit 2; }
if [ -n "$ROLE" ]; then
    diff -ru "$OTHER/roles/$ROLE" "$HERE/roles/$ROLE" || true
    exit 0
fi
for d in "$HERE"/roles/common_*/ "$OTHER"/roles/common_*/; do basename "$d"; done | sort -u | while read -r r; do
    if [ ! -d "$HERE/roles/$r" ]; then   printf '%-30s only in %s\n' "$r" "$(basename "$OTHER")"
    elif [ ! -d "$OTHER/roles/$r" ]; then printf '%-30s only here\n' "$r"
    else
        n=$(diff -ru "$OTHER/roles/$r" "$HERE/roles/$r" | grep -cE '^[-+][^-+]' || true)
        printf '%-30s %s changed lines\n' "$r" "$n"
    fi
done
