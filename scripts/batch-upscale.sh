#!/usr/bin/env bash
# ABOUTME: Upscales every image in a folder into a sibling "<folder>-upped" mirror.
# ABOUTME: Runs one image at a time and logs failures without stopping the batch.
#
#   scripts/batch-upscale.sh DIR [MODEL]
#
# MODEL is a full model name or any unique piece of one (gan-x4 for
# realesrgan-x4plus); default realesr-general-wdn-x4v3.
# Writes DIR-upped next to DIR, each output named like its original. An existing
# DIR-upped is moved to the Trash and rebuilt. Takes JPEG, PNG, HEIC/HEIF and
# TIFF (any extension case); JPEG/PNG keep their format, everything else
# becomes PNG (photo.HEIC -> photo.png). Logs go to DIR-upped.logs/.
# Env: SCALE (default 2). Face enhancement is always off.
set -uo pipefail

[[ $# -ge 1 ]] || { sed -n 5p "$0" | sed 's/^# *//' >&2; exit 2; }
IN="${1%/}"
MODEL="${2:-realesr-general-wdn-x4v3}"
SCALE="${SCALE:-2}"
OUT="$IN-upped"
LOG="$OUT.logs"

[[ -d "$IN" ]] || { echo "not a directory: $IN" >&2; exit 2; }
command -v superscale >/dev/null || { echo "superscale not on PATH" >&2; exit 2; }

# MODEL may be any unique substring of a model name (wdn, gan-x4, x2).
models=$(superscale --list-models | awk '/^Models:/{on=1; next} on && NF==0{exit} on{print $1}')
if ! grep -qxF -- "$MODEL" <<<"$models"; then
  matches=$(grep -F -- "$MODEL" <<<"$models")
  [[ -n "$matches" && $(wc -l <<<"$matches") -eq 1 ]] || {
    echo "model '$MODEL' matches ${matches:+several: }$(tr '\n' ' ' <<<"${matches:-nothing. Models: $models}")" >&2
    exit 2
  }
  MODEL="$matches"
fi
echo "Model: $MODEL  Scale: ${SCALE}x"
for old in "$OUT" "$LOG"; do
  [[ -e "$old" ]] && { trash "$old" || exit 1; }
done
mkdir -p "$OUT" "$LOG"

# Keep the Mac awake until this script exits.
caffeinate -i -w $$ &

total=0 done_=0 failed=0
while IFS= read -r -d '' photo; do
  total=$((total + 1))
  name=$(basename "$photo")
  stem="${name%.*}" ext="${name##*.}"
  # superscale writes stem_<scale>x.<ext>, and only as PNG/JPEG; for other
  # inputs that is PNG data under the input's extension, so rename to .png.
  final="$OUT/$name"
  [[ "$ext" =~ ^([jJ][pP][eE]?[gG]|[pP][nN][gG])$ ]] || final="$OUT/$stem.png"
  echo "[$total] $name"
  if superscale -m "$MODEL" -s "$SCALE" --no-face-enhance -o "$OUT" "$photo" >>"$LOG/process.log" 2>&1 &&
    mv -- "$OUT/${stem}_${SCALE}x.$ext" "$final"; then
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
echo "Found $total, upscaled $done_, failed $failed"
echo "Output: $OUT  Logs: $LOG"
((failed == 0))
