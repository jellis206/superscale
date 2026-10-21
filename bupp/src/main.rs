//! bupp: batch-upscale a folder of photos (and optionally videos) with
//! superscale, into sibling `DIR-upped` / `DIR-upped-videos` folders.

mod output;
mod pool;
mod video;

use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};
use std::time::Instant;

use anyhow::{Context, Result, bail};
use clap::Parser;

use output::{OutputDir, TempDir, file_name, run_logged};
use pool::Workers;

const IMAGE_EXTENSIONS: &[&str] = &["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"];
const VIDEO_EXTENSIONS: &[&str] = &["mp4", "mov", "m4v"];
/// Image batches this small run one at a time.
const PARALLEL_ABOVE: usize = 32;

/// Upscale every image in DIR into DIR-upped (named like the originals, videos
/// copied in unchanged), and with -v/-V every video into DIR-upped-videos.
///
/// An existing output folder is moved to the Trash, unless it has more than 32
/// files: then you choose to resume (skip what's there), delete, or quit.
#[derive(Parser)]
struct Args {
    /// Folder of photos and videos.
    dir: PathBuf,

    /// Model name, or any unique piece of one (wdn, gan-x4, x2).
    #[arg(default_value = "realesr-general-wdn-x4v3")]
    model: String,

    /// Also upscale videos, to fit 3840x2160, into DIR-upped-videos.
    #[arg(short = 'v', long = "videos", visible_alias = "v")]
    videos: bool,

    /// Only upscale videos; leave DIR-upped alone.
    #[arg(short = 'V', long)]
    videos_only: bool,

    /// Image scale factor (videos always fit 4K).
    #[arg(short, long, env = "SCALE", default_value_t = 2.0)]
    scale: f64,

    /// Fixed number of parallel superscale processes. Default: start at 3 and
    /// add workers while each one makes it at least 10% faster.
    #[arg(short, long, env = "JOBS")]
    jobs: Option<usize>,
}

#[derive(Default)]
struct Tally {
    found: usize,
    upscaled: usize,
    skipped: usize,
    failed: usize,
    /// Most superscale processes that ran at once.
    peak_workers: usize,
}

impl Tally {
    fn record(&mut self, out: &OutputDir, name: &str, ok: bool) {
        out.record(name, ok);
        if ok {
            self.upscaled += 1;
        } else {
            self.failed += 1;
        }
    }
}

fn main() -> ExitCode {
    match run(Args::parse()) {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::FAILURE,
        Err(e) => {
            eprintln!("bupp: {e:#}");
            ExitCode::from(2)
        }
    }
}

/// Ok(true) when every file made it.
fn run(args: Args) -> Result<bool> {
    let started = Instant::now();
    if !args.dir.is_dir() {
        bail!("not a directory: {}", args.dir.display());
    }
    if args.scale <= 0.0 {
        bail!("scale must be positive");
    }
    let do_images = !args.videos_only;
    let do_videos = args.videos || args.videos_only;
    if do_videos && Command::new("ffmpeg").arg("-version").output().is_err() {
        bail!("ffmpeg not found (brew install ffmpeg)");
    }
    // Resolved before anything is trashed, so a typo can't cost a folder.
    let model = resolve_model(&args.model)?;
    println!("Model: {model}  Scale: {}x", args.scale);

    ctrlc::set_handler(|| {
        output::remove_all_temp_dirs();
        eprintln!("\ninterrupted");
        std::process::exit(130);
    })?;
    // Keep the Mac awake until bupp exits.
    let _ = Command::new("caffeinate").args(["-i", "-w", &std::process::id().to_string()]).spawn();

    let base = args.dir.to_string_lossy().trim_end_matches('/').to_string();
    let mut workers = Workers::new(args.jobs);
    let mut tally = Tally::default();
    let mut outputs = Vec::new();

    if do_images {
        let out = OutputDir::prepare(PathBuf::from(format!("{base}-upped")))?;
        upscale_images(&args.dir, &out, &model, args.scale, &mut workers, &mut tally)?;
        copy_videos(&args.dir, &out)?;
        outputs.push(out.dir.clone());
    }
    if do_videos {
        let out = OutputDir::prepare(PathBuf::from(format!("{base}-upped-videos")))?;
        upscale_videos(&args.dir, &out, &model, &mut workers, &mut tally)?;
        outputs.push(out.dir.clone());
    }

    let secs = started.elapsed().as_secs();
    let Tally { found, upscaled, skipped, failed, peak_workers } = tally;
    println!();
    println!(
        "Found {found}, upscaled {upscaled}, already done {skipped}, failed {failed} in {}h {}m {}s (up to {peak_workers} workers)",
        secs / 3600,
        secs % 3600 / 60,
        secs % 60,
    );
    let outputs: Vec<_> = outputs.iter().map(|p| p.display().to_string()).collect();
    println!("Output: {}", outputs.join(" and "));
    Ok(failed == 0)
}

/// A superscale command with the options every call shares.
pub fn superscale(model: &str) -> Command {
    let mut cmd = Command::new("superscale");
    cmd.args(["-m", model, "--no-face-enhance"]);
    cmd
}

/// Exact model name, or the one model containing `wanted`.
fn resolve_model(wanted: &str) -> Result<String> {
    let list = Command::new("superscale")
        .arg("--list-models")
        .output()
        .context("superscale not found (devtools superscale)")?;
    let text = String::from_utf8_lossy(&list.stdout);
    let models: Vec<&str> = text
        .lines()
        .skip_while(|l| !l.starts_with("Models:"))
        .skip(1)
        .take_while(|l| !l.trim().is_empty())
        .filter_map(|l| l.split_whitespace().next())
        .collect();
    if models.contains(&wanted) {
        return Ok(wanted.to_string());
    }
    let matches: Vec<&str> = models.iter().copied().filter(|m| m.contains(wanted)).collect();
    match matches.as_slice() {
        [one] => Ok(one.to_string()),
        [] => bail!("model '{wanted}' matches nothing. Models: {}", models.join(" ")),
        several => bail!("model '{wanted}' matches several: {}", several.join(" ")),
    }
}

/// Where an image's upscaled copy goes: same name, but superscale only writes
/// PNG/JPEG, so anything else (HEIC, TIFF) becomes .png.
fn image_dest(out: &OutputDir, photo: &Path) -> PathBuf {
    let ext = photo.extension().unwrap_or_default().to_string_lossy().to_lowercase();
    if ["jpg", "jpeg", "png"].contains(&ext.as_str()) {
        out.dir.join(file_name(photo))
    } else {
        out.dir.join(photo.with_extension("png").file_name().unwrap_or_default())
    }
}

fn upscale_images(
    dir: &Path,
    out: &OutputDir,
    model: &str,
    scale: f64,
    workers: &mut Workers,
    tally: &mut Tally,
) -> Result<()> {
    let photos = output::list_files(dir, IMAGE_EXTENSIONS)?;
    tally.found += photos.len();
    let pending: Vec<PathBuf> = photos.into_iter().filter(|p| !out.done_before(&image_dest(out, p))).collect();
    tally.skipped += tally.found - pending.len();
    let total = pending.len();
    if total == 0 {
        return Ok(());
    }

    // Each image goes through its own scratch folder inside the output folder,
    // so whatever superscale names its file, exactly one comes out to move.
    let scratch = TempDir::new_in(&out.dir)?;
    let mut one_at_a_time = Workers::fixed(1);
    let workers = if total > PARALLEL_ABOVE { workers } else { &mut one_at_a_time };
    println!("Upscaling {total} image(s)");
    let mut finished = 0;
    pool::run(
        pending.into_iter().enumerate().collect(),
        workers,
        |(i, photo)| {
            let ok = upscale_image(&photo, &scratch.path().join(i.to_string()), out, model, scale)
                .map_err(|e| out.log(&format!("{}: {e:#}", photo.display())))
                .is_ok();
            (photo, ok)
        },
        |(photo, ok), running| {
            finished += 1;
            tally.peak_workers = tally.peak_workers.max(running);
            println!("[{finished}/{total}] {}  ({running} workers)", file_name(&photo));
            tally.record(out, &file_name(&photo), ok);
        },
    );
    Ok(())
}

fn upscale_image(photo: &Path, scratch: &Path, out: &OutputDir, model: &str, scale: f64) -> Result<()> {
    std::fs::create_dir_all(scratch)?;
    let mut cmd = superscale(model);
    cmd.args(["-s", &scale.to_string(), "-o"]).arg(scratch).arg(photo);
    if !run_logged(out, cmd) {
        bail!("superscale failed");
    }
    let made = std::fs::read_dir(scratch)?.next().context("superscale wrote nothing")??.path();
    output::move_file(&made, &image_dest(out, photo))?;
    std::fs::remove_dir(scratch)?;
    Ok(())
}

/// Copies videos into the image mirror unchanged, so it has everything.
fn copy_videos(dir: &Path, out: &OutputDir) -> Result<()> {
    let mut copied = 0;
    for video in output::list_files(dir, VIDEO_EXTENSIONS)? {
        let dest = out.dir.join(file_name(&video));
        if !dest.exists() {
            output::copy_whole(&video, &dest)?;
            copied += 1;
        }
    }
    if copied > 0 {
        println!("Copied {copied} video(s) as-is");
    }
    Ok(())
}

fn upscale_videos(dir: &Path, out: &OutputDir, model: &str, workers: &mut Workers, tally: &mut Tally) -> Result<()> {
    let videos = output::list_files(dir, VIDEO_EXTENSIONS)?;
    tally.found += videos.len();
    for (i, video) in videos.iter().enumerate() {
        let name = file_name(video);
        let dest = out.dir.join(&name);
        if out.done_before(&dest) {
            tally.skipped += 1;
            continue;
        }
        println!("[{}/{}] {name}", i + 1, videos.len());
        let result = video::upscale(video, &dest, model, out, workers);
        if let Err(e) = &result {
            out.log(&format!("{}: {e:#}", video.display()));
        }
        tally.record(out, &name, result.is_ok());
        tally.peak_workers = tally.peak_workers.max(workers.count());
    }
    Ok(())
}
