#!/usr/bin/env bash
# ABOUTME: Upscales every image in a folder into a sibling "<folder>-upped" mirror,
# ABOUTME: and optionally every video into "<folder>-upped-videos".
#
#   scripts/batch-upscale.sh [-v|--videos] [-V|--videos-only] DIR [MODEL]
#
# MODEL is a full model name or any unique piece of one (gan-x4 for
# realesrgan-x4plus); default realesr-general-wdn-x4v3.
#
# Images -> DIR-upped (skipped with -V): JPEG, PNG, HEIC/HEIF, TIFF (any
# extension case), scaled by SCALE (default 2), each named like its original.
# JPEG/PNG keep their format; everything else becomes PNG (photo.HEIC ->
# photo.png). MP4/MOV/M4V are copied in unchanged, so the folder is a full mirror.
#
# Videos -> DIR-upped-videos (with -v or -V): every frame is upscaled to fit
# 3840x2160 (a 4K TV; SCALE is ignored) and re-encoded as H.264 with the
# original audio; videos already that size are copied. Needs ffmpeg; frames in
# $TMPDIR take a few GB, and about 20 minutes, per minute of 30 fps video.
#
# An existing output folder is moved to the Trash and rebuilt, unless it holds
# more than 32 files: then you are asked whether to trash it or resume, which
# skips everything already in it. Logs go to <output folder>.logs/.
#
# More than 32 images to do, or any video, runs JOBS (default 3) superscale
# processes at once. They share one Neural Engine: on an M-series Mac 3 ran
# the default model 2.6x faster than 1, and more than 3 added nothing.
# Face enhancement is always off.
set -uo pipefail

IMAGES=1 VIDEOS=0
args=()
for a; do
  case "$a" in
  -v | --v | --videos) VIDEOS=1 ;;
  -V | --videos-only) VIDEOS=1 IMAGES=0 ;;
  *) args+=("$a") ;;
  esac
done
set -- "${args[@]+"${args[@]}"}"
[[ $# -ge 1 ]] || { sed -n 5p "$0" | sed 's/^# *//' >&2; exit 2; }
IN="${1%/}"
MODEL="${2:-realesr-general-wdn-x4v3}"
SCALE="${SCALE:-2}"
JOBS="${JOBS:-3}"

[[ -d "$IN" ]] || { echo "not a directory: $IN" >&2; exit 2; }
command -v superscale >/dev/null || { echo "superscale not on PATH" >&2; exit 2; }
if ((VIDEOS)) && ! command -v ffmpeg >/dev/null; then
  echo "ffmpeg not found (brew install ffmpeg)" >&2
  exit 2
fi

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

# Make output folder $1 (and its .logs) ready. Sets RESUME=1 when picking up
# an earlier run instead of starting over.
prepare() {
  local n ans
  RESUME=0
  if [[ -e "$1" ]]; then
    n=$(find "$1" -maxdepth 1 -type f | wc -l | tr -d ' ')
    if ((n > 32)); then
      if ! { : </dev/tty; } 2>/dev/null ||
        ! read -r -p "$1 already has $n files. [r]esume, [d]elete and start over, or [q]uit? " ans </dev/tty; then
        echo "no terminal to ask, resuming" >&2
        ans=r
      fi
      case "$ans" in
      r | R) RESUME=1 ;;
      d | D) trash "$1" || exit 1 ;;
      *) exit 1 ;;
      esac
    else
      trash "$1" || exit 1
    fi
  fi
  if [[ -e "$1.logs" ]] && ((!RESUME)); then trash "$1.logs" || exit 1; fi
  mkdir -p "$1" "$1.logs"
}

# Keep the Mac awake until this script exits.
caffeinate -i -w $$ &
tmp=""
trap '[[ -n "$tmp" ]] && rm -rf "$tmp"' EXIT

total=0 done_=0 skipped=0 failed=0
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
# On resume, true (and counted) when $1 already exists.
done_before() {
  ((RESUME)) && [[ -e "$1" ]] && skipped=$((skipped + 1))
}

# ---- images -> DIR-upped ----
if ((IMAGES)); then
  OUT="$IN-upped" LOG="$IN-upped.logs"
  prepare "$OUT"
  # superscale writes stem_<scale>x.<ext>, and only as PNG/JPEG; for other
  # inputs that is PNG data under the input's extension, so rename to .png.
  image_dest() {
    local name="${1##*/}"
    if [[ "${name##*.}" =~ ^([jJ][pP][eE]?[gG]|[pP][nN][gG])$ ]]; then
      echo "$OUT/$name"
    else
      echo "$OUT/${name%.*}.png"
    fi
  }
  upscale_image() {
    local name="${1##*/}"
    superscale -m "$MODEL" -s "$SCALE" --no-face-enhance -o "$OUT" "$1" >>"$LOG/process.log" 2>&1 &&
      mv -- "$OUT/${name%.*}_${SCALE}x.${name##*.}" "$(image_dest "$1")"
  }

  pending=()
  while IFS= read -r -d '' photo; do
    total=$((total + 1))
    done_before "$(image_dest "$photo")" || pending+=("$photo")
  done < <(list jpg jpeg png heic heif tif tiff)
  n=${#pending[@]} workers=1
  ((n > 32)) && workers=$JOBS
  ((n)) && echo "Upscaling $n image(s), $workers at a time"
  # Each worker takes every $workers-th image and reports "<status> <path>".
  k=0
  while read -r status photo; do
    k=$((k + 1))
    echo "[$k/$n] ${photo##*/}"
    record "${photo##*/}" "$status"
  done < <(
    for ((w = 0; w < workers; w++)); do
      (for ((j = w; j < n; j += workers)); do
        upscale_image "${pending[j]}"
        echo "$? ${pending[j]}"
      done) &
    done
    wait
  )

  copied=0
  while IFS= read -r -d '' video; do
    dest="$OUT/$(basename "$video")"
    [[ -e "$dest" ]] && continue
    cp -- "$video" "$dest.part" && mv -- "$dest.part" "$dest" && copied=$((copied + 1))
  done < <(list mp4 mov m4v)
  ((copied)) && echo "Copied $copied video(s) as-is"
fi

# ---- videos -> DIR-upped-videos ----
# ponytail: frames go through 8-bit JPEG, so HDR (iPhone HLG/Dolby Vision) video
# loses its HDR look; add a tonemap filter to the extract step if that matters.
upscale_video() { # $1 = source video, $2 = destination
  local fps size frames start=$SECONDS name
  name=$(basename "$2")
  tmp=$(mktemp -d) && mkdir "$tmp/in" "$tmp/up" || return 1
  fps=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$1") &&
    ffmpeg -nostdin -v error -i "$1" -vf "fps=$fps" -q:v 2 "$tmp/in/f%06d.jpg" || return 1
  frames=$(find "$tmp/in" -type f | wc -l | tr -d ' ')
  # Size after rotation, from a decoded frame rather than the stream metadata.
  size=$(sips -g pixelWidth -g pixelHeight "$tmp/in/f000001.jpg" | awk 'NR>1{printf "%s ", $2}')
  if awk -v s="$size" 'BEGIN{split(s, d, " "); exit !(d[1] >= 3840 || d[2] >= 2160)}'; then
    echo "  ${size% } is already 4K, copying"
    cp -- "$1" "$tmp/$name" || return 1
  else
    # Frames are split across $JOBS superscale processes.
    local all=("$tmp"/in/*.jpg) chunk pids=() w j pid ok=1
    for ((w = 0; w < JOBS && w < frames; w++)); do
      chunk=()
      for ((j = w; j < frames; j += JOBS)); do chunk+=("${all[j]}"); done
      superscale -m "$MODEL" --width 3840 --height 2160 --no-face-enhance -o "$tmp/up" "${chunk[@]}" >&2 &
      pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid" || ok=0; done
    ((ok)) &&
      ffmpeg -nostdin -v error -framerate "$fps" -pattern_type glob -i "$tmp/up/*.jpg" -i "$1" \
        -map 0:v -map '1:a?' -vf 'scale=trunc(iw/2)*2:trunc(ih/2)*2' \
        -c:v libx264 -crf 18 -preset medium -pix_fmt yuv420p -c:a copy -shortest \
        -movflags +faststart "$tmp/$name" || return 1
    local secs=$((SECONDS - start))
    echo "  $frames frames, ${size% } -> $(sips -g pixelWidth -g pixelHeight "$tmp/up/f000001_"*.jpg |
      awk 'NR>1{printf "%s ", $2}')in ${secs}s ($(awk -v f="$frames" -v s="$secs" 'BEGIN{printf "%.1f", f / (s ? s : 1)}') fps)"
  fi
  # Built in tmp and moved in whole, so an interrupted run never leaves a
  # partial video that resume would mistake for a finished one.
  mv -- "$tmp/$name" "$2" || return 1
  rm -rf "$tmp"
  tmp=""
}

if ((VIDEOS)); then
  OUT="$IN-upped-videos" LOG="$IN-upped-videos.logs"
  prepare "$OUT"
  while IFS= read -r -d '' video; do
    total=$((total + 1))
    name=$(basename "$video")
    done_before "$OUT/$name" && continue
    echo "[$total] $name"
    upscale_video "$video" "$OUT/$name" 2>>"$LOG/process.log"
    record "$name" $?
  done < <(list mp4 mov m4v)
fi

echo
echo "Found $total, upscaled $done_, already done $skipped, failed $failed in $((SECONDS / 3600))h $((SECONDS % 3600 / 60))m $((SECONDS % 60))s"
echo "Output: $IN-upped$( ((IMAGES)) || echo -videos)$( ((IMAGES && VIDEOS)) && echo " and $IN-upped-videos")"
((failed == 0))
