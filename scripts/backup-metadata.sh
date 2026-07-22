#!/usr/bin/env bash
#
# Back up GreptimeDB's local metadata (WAL + table catalog).
#
# WHY THIS EXISTS: R2 holds the SST data files, but the mapping from table
# names to the region IDs those files are keyed by lives ONLY in the local
# raft-engine WAL under /data/home. Lose it and the R2 data is intact but
# unaddressable — the database starts with zero tables. R2 is not a backup.
#
# Only /data/home is backed up (~70 MB). write_cache and read_cache are
# regenerated from R2 on demand and are deliberately excluded.
#
# Usage:  ./scripts/backup-metadata.sh [output_dir]
# Cron:   0 */6 * * * /path/to/scripts/backup-metadata.sh /root/greptime-backups

set -euo pipefail

readonly CONTAINER="${GREPTIME_CONTAINER:-greptimedb-r2}"
readonly OUTPUT_DIR="${1:-/root/greptime-backups}"
readonly RETENTION_DAYS=14
readonly MIN_EXPECTED_BYTES=10240 # a valid catalog is never this small

timestamp="$(date +%Y%m%d-%H%M%S)"
archive="${OUTPUT_DIR}/greptime-home-${timestamp}.tar.gz"

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "ERROR: container '${CONTAINER}' not found" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "Backing up ${CONTAINER}:/data/home -> ${archive}"
docker exec "$CONTAINER" tar czf - -C /data home >"$archive"

# A backup that silently produced an empty archive is worse than no backup,
# because it looks like success. Fail loudly instead.
size="$(stat -f%z "$archive" 2>/dev/null || stat -c%s "$archive")"
if [ "$size" -lt "$MIN_EXPECTED_BYTES" ]; then
  echo "ERROR: archive is only ${size} bytes — refusing to treat as valid" >&2
  rm -f "$archive"
  exit 1
fi

echo "OK: ${archive} (${size} bytes)"

deleted="$(find "$OUTPUT_DIR" -name 'greptime-home-*.tar.gz' -mtime "+${RETENTION_DAYS}" -print -delete | wc -l | tr -d ' ')"
[ "$deleted" -gt 0 ] && echo "Pruned ${deleted} backup(s) older than ${RETENTION_DAYS} days"

exit 0
