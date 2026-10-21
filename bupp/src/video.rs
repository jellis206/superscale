//! Video pass: split into frames, upscale the frames in parallel, re-encode.

use std::fs;
use std::io::Write;
use std::path::Path;
use std::process::Command;
use std::time::Instant;

use anyhow::{Context, Result, bail};

use crate::output::{self, OutputDir, TempDir, run_logged};
use crate::pool::{self, Workers};
use crate::superscale;

/// Videos are sized to fit a 4K TV.
const TARGET: (u32, u32) = (3840, 2160);
/// Frames per superscale call: enough that startup cost doesn't matter, few
/// enough that the pool has plenty of tasks to spread out.
const FRAMES_PER_CALL: usize = 10;

/// Upscales `src` into `dest`. The result is built in a temp dir and moved in
/// whole, so an interrupted run never leaves a partial video behind.
// ponytail: frames go through 8-bit JPEG, so HDR (iPhone HLG/Dolby Vision)
// video loses its HDR look; add a tonemap filter to the extract step if needed.
pub fn upscale(src: &Path, dest: &Path, model: &str, out: &OutputDir, workers: &mut Workers) -> Result<()> {
    let started = Instant::now();
    let tmp = TempDir::new_in(&std::env::temp_dir())?;
    let (frames_in, frames_up) = (tmp.path().join("in"), tmp.path().join("up"));
    fs::create_dir_all(&frames_in)?;
    fs::create_dir_all(&frames_up)?;
    let built = tmp.path().join(output::file_name(dest));

    let fps = frame_rate(src)?;
    let mut extract = Command::new("ffmpeg");
    extract
        .args(["-nostdin", "-v", "error", "-i"])
        .arg(src)
        .args(["-vf", &format!("fps={fps}"), "-q:v", "2"])
        .arg(frames_in.join("f%06d.jpg"));
    if !run_logged(out, extract) {
        bail!("could not extract frames");
    }
    let frames = output::list_files(&frames_in, &["jpg"])?;
    // Size after rotation, from a decoded frame rather than the stream metadata.
    let (w, h) = frames.first().and_then(|f| output::image_size(f)).context("no frames")?;

    if w >= TARGET.0 || h >= TARGET.1 {
        println!("  {w}x{h} is already 4K, copying");
        fs::copy(src, &built)?;
    } else {
        let total = frames.len();
        let chunks: Vec<Vec<_>> = frames.chunks(FRAMES_PER_CALL).map(<[_]>::to_vec).collect();
        let (mut finished, mut all_ok) = (0, true);
        pool::run(
            chunks,
            workers,
            |chunk| {
                let n = chunk.len();
                let mut cmd = superscale(model);
                cmd.args(["--width", &TARGET.0.to_string(), "--height", &TARGET.1.to_string()])
                    .arg("-o")
                    .arg(&frames_up)
                    .args(&chunk);
                (run_logged(out, cmd), n)
            },
            |(ok, n), running| {
                finished += n;
                all_ok &= ok;
                print!("\r  {finished}/{total} frames, {running} workers");
                let _ = std::io::stdout().flush();
            },
        );
        println!();
        if !all_ok {
            bail!("some frames failed to upscale");
        }

        let mut encode = Command::new("ffmpeg");
        encode
            .args(["-nostdin", "-v", "error", "-framerate", &fps, "-pattern_type", "glob", "-i"])
            .arg(frames_up.join("*.jpg"))
            .arg("-i")
            .arg(src)
            .args(["-map", "0:v", "-map", "1:a?", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2"])
            .args(["-c:v", "libx264", "-crf", "18", "-preset", "medium", "-pix_fmt", "yuv420p"])
            .args(["-c:a", "copy", "-shortest", "-movflags", "+faststart"])
            .arg(&built);
        if !run_logged(out, encode) {
            bail!("could not encode the upscaled frames");
        }

        let up = output::list_files(&frames_up, &["jpg"])?;
        let (uw, uh) = up.first().and_then(|f| output::image_size(f)).unwrap_or((0, 0));
        let secs = started.elapsed().as_secs_f64();
        println!("  {total} frames, {w}x{h} -> {uw}x{uh} in {secs:.0}s ({:.1} fps)", total as f64 / secs);
    }
    output::move_file(&built, dest)
}

/// The stream's frame rate as ffprobe prints it, e.g. "30/1".
fn frame_rate(video: &Path) -> Result<String> {
    let out = Command::new("ffprobe")
        .args(["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=r_frame_rate", "-of", "csv=p=0"])
        .arg(video)
        .output()?;
    let fps = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if fps.is_empty() {
        bail!("no video stream");
    }
    Ok(fps)
}
