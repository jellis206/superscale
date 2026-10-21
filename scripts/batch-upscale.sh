#!/usr/bin/env bash
# ABOUTME: Upscales every image in a folder, one at a time, logging failures.
# ABOUTME: Skips images already upscaled, so an interrupted run can be resumed.
#
#   scripts/batch-upscale.sh INPUT_DIR OUTPUT_DIR [MODEL]
#
# Takes JPEG, PNG, HEIC/HEIF and TIFF (any extension case). JPEG/PNG keep their
# format (photo.JPG -> photo_2x.JPG); everything else becomes PNG
# (photo.HEIC -> photo_2x.png). Logs go to OUTPUT_DIR/../logs.
# Env: SCALE (default 2). Face enhancement is always off.
set -uo pipefail

[[ $# -ge 2 ]] || { sed -n 5p "$0" | sed 's/^# *//' >&2; exit 2; }
IN="$1"
OUT="$2"
MODEL="${3:-realesr-general-wdn-x4v3}"
SCALE="${SCALE:-2}"
LOG="$(dirname "$OUT")/logs"

[[ -d "$IN" ]] || { echo "not a directory: $IN" >&2; exit 2; }
command -v superscale >/dev/null || { echo "superscale not on PATH" >&2; exit 2; }
mkdir -p "$OUT" "$LOG"

# Keep the Mac awake until this script exits.
caffeinate -i -w $$ &

total=0 done_=0 skipped=0 failed=0
while IFS= read -r -d '' photo; do
  total=$((total + 1))
  name=$(basename "$photo")
  stem="${name%.*}" ext="${name##*.}"
  # superscale only writes PNG/JPEG; for other inputs it writes PNG data under
  # the input's extension, so those get renamed to .png below.
  written="$OUT/${stem}_${SCALE}x.$ext" final="$written"
  [[ "$ext" =~ ^([jJ][pP][eE]?[gG]|[pP][nN][gG])$ ]] || final="$OUT/${stem}_${SCALE}x.png"
  if [[ -e "$final" ]]; then
    skipped=$((skipped + 1))
    continue
  fi
  echo "[$total] $name"
  if superscale -m "$MODEL" -s "$SCALE" --no-face-enhance -o "$OUT" "$photo" >>"$LOG/process.log" 2>&1 &&
    { [[ "$written" == "$final" ]] || mv -- "$written" "$final"; }; then
    done_=$((done_ + 1))
    echo "$name" >>"$LOG/success.log"
  else
    failed=$((failed + 1))
    echo "$name" >>"$LOG/failed.log"
    echo "  FAILED (see $LOG/process.log)"
  fi
done < <(find "$IN" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
  -o -iname '*.heic' -o -iname '*.heif' -o -iname '*.tif' -o -iname '*.tiff' \) -print0 | sort -z)

echo
echo "Found $total, upscaled $done_, already done $skipped, failed $failed"
echo "Output: $OUT  Logs: $LOG"
((failed == 0))
