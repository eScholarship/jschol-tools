#!/usr/bin/env bash
#
# Validate the TOC fix on a small sample:
#   1. snapshot attrs.toc BEFORE
#   2. run convert.rb on the sample
#   3. snapshot attrs.toc AFTER
#   4. diff, and tally how many items lost their TOC entirely
#
# Usage:
#   ./tools/toc_backfill/sample_check.sh [ids_file]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

IDS_FILE="${1:-sample_ids.txt}"
OUT_DIR="toc_backfill_sample"

RUBY="${RUBY:-ruby}"
CONVERT=($RUBY tools/convert.rb)
SNAPSHOT=($RUBY tools/toc_backfill/toc_snapshot.rb)

if [[ ! -f "$IDS_FILE" ]]; then
  echo "ERROR: ids file not found: $IDS_FILE" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
N=$(grep -c . "$IDS_FILE")

echo "== Snapshotting BEFORE ($N items) =="
"${SNAPSHOT[@]}" "$IDS_FILE" > "$OUT_DIR/before.txt"

echo "== Running convert.rb --items --noCloudSearch on sample =="
"${CONVERT[@]}" --items --noCloudSearch $(cat "$IDS_FILE") > "$OUT_DIR/convert.log" 2>&1
convert_status=$?
if [[ $convert_status -ne 0 ]]; then
  echo "WARNING: convert.rb exited $convert_status -- see $OUT_DIR/convert.log" >&2
fi

echo "== Snapshotting AFTER =="
"${SNAPSHOT[@]}" "$IDS_FILE" > "$OUT_DIR/after.txt"

echo
echo "== DIFF (before -> after) =="
if diff -u "$OUT_DIR/before.txt" "$OUT_DIR/after.txt" > "$OUT_DIR/toc.diff"; then
  echo "(no changes detected)"
else
  cat "$OUT_DIR/toc.diff"
fi

echo
echo "== Summary =="
before_notoc=$(grep -c "(no toc)" "$OUT_DIR/before.txt" || true)
after_notoc=$(grep -c "(no toc)" "$OUT_DIR/after.txt" || true)
echo "  items with NO toc  before: $before_notoc   after: $after_notoc"
echo "  (a rise here = items dropped below the 4-entry filterTOCDivs floor, e.g. qt3j61f58g)"
echo
echo "Artifacts in $OUT_DIR/: before.txt, after.txt, toc.diff, convert.log"
