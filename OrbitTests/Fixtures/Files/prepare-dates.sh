#!/bin/bash
# Gives the file-tool fixtures dates relative to today and (re)imports them into
# Spotlight. The Spotlight integration tests (ORBIT_SPOTLIGHT_TESTS=1) and the
# end-to-end runs (ORBIT_DEBUG_FILE_SCOPE=<this folder>) rely on it:
#
#   - everything, these scripts too: modified 90 days ago (outside recent_files' 30 days)
#   - Rechnungen/*-2026-08.*: last month (the 10th and the 15th)
#   - Rechnungen/Rechnung-Telekom-2026-06.pdf: three months ago
#   - Dokumente/Notizen.md: modified 2 days ago; Dokumente/Protokoll.odt: 5 days ago
#   - Dokumente/Angebot.docx: last used yesterday (modified 90 days ago)
#
# Spotlight picks the changes up within seconds; the tests wait for it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

# touch -t stamps (BSD date; -v1d first, so "last month" works on the 31st too).
old=$(date -v-90d +%Y%m%d1000)
last_month=$(date -v1d -v-1m +%Y%m)
three_months_ago=$(date -v1d -v-3m +%Y%m)
two_days_ago=$(date -v-2d +%Y%m%d0915)
five_days_ago=$(date -v-5d +%Y%m%d1640)

find . -mindepth 1 -exec touch -h -t "$old" {} +

touch -t "${last_month}151200" Rechnungen/Rechnung-Telekom-2026-08.pdf Rechnungen/Kontoauszug-2026-08.pdf \
    Rechnungen/Invoice-Notes-2026-08.txt
touch -t "${last_month}100930" Rechnungen/Vodafone-Invoice-2026-08.pdf
touch -t "${three_months_ago}151200" Rechnungen/Rechnung-Telekom-2026-06.pdf
touch -t "$two_days_ago" Dokumente/Notizen.md
touch -t "$five_days_ago" Dokumente/Protokoll.odt

# Last used: Finder's attribute, a little-endian struct timespec (seconds, nanoseconds).
set_last_used() {
    local hex le="" i
    hex=$(printf '%016x' "$1")
    for i in 14 12 10 8 6 4 2 0; do le="$le${hex:$i:2}"; done
    xattr -wx 'com.apple.lastuseddate#PS' "${le}0000000000000000" "$2"
}
find . -mindepth 1 -exec xattr -d 'com.apple.lastuseddate#PS' {} + 2>/dev/null || true
set_last_used "$(date -v-1d +%s)" Dokumente/Angebot.docx

mdimport "$DIR" >/dev/null 2>&1 || true
echo "Dates set relative to $(date +%Y-%m-%d); Spotlight re-import requested for $DIR."
