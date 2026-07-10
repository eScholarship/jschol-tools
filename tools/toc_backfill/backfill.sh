#!/usr/bin/env bash
#
# Full TOC backfill: re-run convert.rb over the candidate item list in chunks,
# fixing the page+1 anchor bug
#
# Usage:
#   ./tools/toc_backfill/backfill.sh [ids_file] [batch_size]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

IDS_FILE="${1:-tmp/backfill_ids.txt}"
BATCH_SIZE="${2:-500}"
# Override WORK_DIR to isolate runs (e.g. a small scale test vs. the real backfill)
WORK_DIR="${WORK_DIR:-tmp/toc_backfill_run}"
CHUNK_DIR="$WORK_DIR/chunks"
LOG_DIR="$WORK_DIR/logs"
DONE_FILE="$WORK_DIR/completed_chunks.txt"
FAIL_FILE="$WORK_DIR/failed_chunks.txt"

RUBY="${RUBY:-ruby}"
CONVERT=($RUBY tools/convert.rb)

if [[ ! -f "$IDS_FILE" ]]; then
  echo "ERROR: ids file not found: $IDS_FILE" >&2
  exit 1
fi

mkdir -p "$CHUNK_DIR" "$LOG_DIR"
touch "$DONE_FILE"
: > "$FAIL_FILE"   # reset the failure list each run

# Split the id list into numbered chunk files
# Existing chunk_* files are reused so the done-list stays valid across re-runs
if [[ -z "$(ls -A "$CHUNK_DIR" 2>/dev/null)" ]]; then
  split -l "$BATCH_SIZE" -d -a 5 "$IDS_FILE" "$CHUNK_DIR/chunk_"
fi

total_chunks=$(ls "$CHUNK_DIR"/chunk_* | wc -l | tr -d ' ')
total_ids=$(grep -c . "$IDS_FILE")
echo "Backfill: $total_ids ids across $total_chunks chunks of ~$BATCH_SIZE (RUBY='$RUBY')"
echo

idx=0
for chunk in "$CHUNK_DIR"/chunk_*; do
  idx=$((idx + 1))
  name=$(basename "$chunk")

  if grep -qxF "$name" "$DONE_FILE"; then
    echo "[$idx/$total_chunks] skip $name (already done)"
    continue
  fi

  n=$(grep -c . "$chunk")
  echo "[$idx/$total_chunks] run  $name ($n items) -> $LOG_DIR/$name.log"
  if "${CONVERT[@]}" --items --noCloudSearch $(cat "$chunk") > "$LOG_DIR/$name.log" 2>&1; then
    echo "$name" >> "$DONE_FILE"
    echo "[$idx/$total_chunks] ok   $name"
  else
    status=$?
    echo "$name (exit $status)" >> "$FAIL_FILE"
    echo "[$idx/$total_chunks] FAIL $name (exit $status) -- see $LOG_DIR/$name.log" >&2
    # Not marked done: a re-run will retry it
  fi
done

echo
echo "== Backfill summary =="
echo "  chunks completed: $(grep -c . "$DONE_FILE") / $total_chunks"
if [[ -s "$FAIL_FILE" ]]; then
  echo "  chunks FAILED (will retry on re-run):"
  sed 's/^/    /' "$FAIL_FILE"
else
  echo "  chunks failed:    0"
fi

echo
echo "  item-level tallies (scanned from logs):"
echo "    changed:   $(grep -rhc 'Changed item' "$LOG_DIR" 2>/dev/null | paste -sd+ - | bc 2>/dev/null || echo '?')"
echo "    unchanged: $(grep -rhc 'Unchanged item' "$LOG_DIR" 2>/dev/null | paste -sd+ - | bc 2>/dev/null || echo '?')"
echo "    toc errors: $(grep -rh 'error generating toc' "$LOG_DIR" 2>/dev/null | wc -l | tr -d ' ')"
echo
echo "Artifacts under $WORK_DIR/ (chunks/, logs/, completed_chunks.txt, failed_chunks.txt)"
