#!/usr/bin/env bash
# ABOUTME: Upscales every image, then every video, in a folder into a sibling
# ABOUTME: "<folder>-upped" mirror, logging failures without stopping the batch.
#
#   scripts/batch-upscale.sh DIR [MODEL]
#
# MODEL is a full model name or any unique piece of one (gan-x4 for
# realesrgan-x4plus); default realesr-general-wdn-x4v3.
# Writes DIR-upped next to DIR, each output named like its original. An existing
# DIR-upped is moved to the Trash and rebuilt. Logs go to DIR-upped.logs/.
#
# Pass 1, images: JPEG, PNG, HEIC/HEIF, TIFF (any extension case), scaled by
# SCALE (default 2). JPEG/PNG keep their format; everything else becomes PNG
# (photo.HEIC -> photo.png).
# Pass 2, videos: MP4, MOV, M4V. Every frame is upscaled to fit 3840x2160 (a 4K
# TV; SCALE is ignored) and re-encoded as H.264 with the original audio. Videos
# already that size are copied as-is. Needs ffmpeg, and frames in $TMPDIR take
# a few GB per minute of video.
# Face enhancement is always off.
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
tmp=""
trap '[[ -n "$tmp" ]] && rm -rf "$tmp"' EXIT

total=0 done_=0 failed=0
record() { # $1 = name, $2 = exit status of the upscale
  if (($2 == 0)); then
    done_=$((done_ + 1))
    echo "$1" >>"$LOG/success.log"
  else
    failed=$((failed + 1))
    echo "$1" >>"$LOG/failed.log"
    echo "  FAILED (see $LOG/process.log)"
  fi
}
list() { # files in IN with any of the given extensions, sorted
  local args=() ext
  for ext; do args+=(-o -iname "*.$ext"); done
  find "$IN" -maxdepth 1 -type f \( "${args[@]:1}" \) -print0 | sort -z
}

# ---- pass 1: images ----
while IFS= read -r -d '' photo; do
  total=$((total + 1))
  name=$(basename "$photo")
  stem="${name%.*}" ext="${name##*.}"
  # superscale writes stem_<scale>x.<ext>, and only as PNG/JPEG; for other
  # inputs that is PNG data under the input's extension, so rename to .png.
  final="$OUT/$name"
  [[ "$ext" =~ ^([jJ][pP][eE]?[gG]|[pP][nN][gG])$ ]] || final="$OUT/$stem.png"
  echo "[$total] $name"
  superscale -m "$MODEL" -s "$SCALE" --no-face-enhance -o "$OUT" "$photo" >>"$LOG/process.log" 2>&1 &&
    mv -- "$OUT/${stem}_${SCALE}x.$ext" "$final"
  record "$name" $?
done < <(list jpg jpeg png heic heif tif tiff)

# ---- pass 2: videos ----
# ponytail: frames go through 8-bit JPEG, so HDR (iPhone HLG/Dolby Vision) video
# loses its HDR look; add a tonemap filter to the extract step if that matters.
upscale_video() { # $1 = source video, $2 = destination
  local fps size frames start=$SECONDS
  tmp=$(mktemp -d) && mkdir "$tmp/in" "$tmp/up" || return 1
  fps=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$1") &&
    ffmpeg -nostdin -v error -i "$1" -vf "fps=$fps" -q:v 2 "$tmp/in/f%06d.jpg" || return 1
  frames=$(find "$tmp/in" -type f | wc -l | tr -d ' ')
  # Size after rotation, from a decoded frame rather than the stream metadata.
  size=$(sips -g pixelWidth -g pixelHeight "$tmp/in/f000001.jpg" | awk 'NR>1{printf "%s ", $2}')
  if awk -v s="$size" 'BEGIN{split(s, d, " "); exit !(d[1] >= 3840 || d[2] >= 2160)}'; then
    echo "  ${size% } is already 4K, copying"
    cp -- "$1" "$2"
  else
    superscale -m "$MODEL" --width 3840 --height 2160 --no-face-enhance -o "$tmp/up" "$tmp"/in/*.jpg >&2 &&
      ffmpeg -nostdin -v error -framerate "$fps" -pattern_type glob -i "$tmp/up/*.jpg" -i "$1" \
        -map 0:v -map '1:a?' -vf 'scale=trunc(iw/2)*2:trunc(ih/2)*2' \
        -c:v libx264 -crf 18 -preset medium -pix_fmt yuv420p -c:a copy -shortest \
        -movflags +faststart "$2" || return 1
    local secs=$((SECONDS - start))
    echo "  $frames frames, ${size% } -> $(sips -g pixelWidth -g pixelHeight "$tmp/up/f000001_"*.jpg |
      awk 'NR>1{printf "%s ", $2}')in ${secs}s ($(awk -v f="$frames" -v s="$secs" 'BEGIN{printf "%.1f", f / (s ? s : 1)}') fps)"
  fi
  rm -rf "$tmp"
  tmp=""
}

if [[ -n "$(list mp4 mov m4v | tr -d '\0')" ]] && ! command -v ffmpeg >/dev/null; then
  echo "ffmpeg not found, skipping videos (brew install ffmpeg)" >&2
else
  while IFS= read -r -d '' video; do
    total=$((total + 1))
    name=$(basename "$video")
    echo "[$total] $name"
    upscale_video "$video" "$OUT/$name" 2>>"$LOG/process.log"
    record "$name" $?
  done < <(list mp4 mov m4v)
fi

echo
echo "Found $total, upscaled $done_, failed $failed"
echo "Output: $OUT  Logs: $LOG"
((failed == 0))
