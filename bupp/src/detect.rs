//! Is an existing upscale still an upscale of its source as it is now?
//!
//! Both are shrunk (ffmpeg, area averaging) to a 16x16 color thumbnail and
//! compared by mean per-channel difference (0-255). Measured on real photos: an
//! upscale scores 0.4-2.2 against its source, a +2% brightness edit 3.1, a 5%
//! crop 5.9, +30% saturation 7.3, a different photo 20+. The lowest of the 4
//! rotations counts, so it doesn't matter who applied the photo's orientation.

use std::path::Path;
use std::process::Command;

use crate::output::{self, OutputDir};

/// Below this distance the upscale is kept.
const SAME_BELOW: f64 = 3.0;
const SIDE: usize = 16;
const THUMB_BYTES: usize = SIDE * SIDE * 3;

pub fn image_unchanged(out: &OutputDir, src: &Path, dest: &Path) -> bool {
    // Long side over short side, so rotation doesn't matter. Catches crops the
    // squashed thumbnail would miss.
    let shape = |p| output::image_size(p).map(|(w, h)| w.max(h) as f64 / w.min(h).max(1) as f64);
    let distance = match (shape(src), shape(dest)) {
        (Some(a), Some(b)) if (a / b - 1.0).abs() > 0.01 => Some(f64::INFINITY),
        (Some(_), Some(_)) => thumb(src, None).zip(thumb(dest, None)).map(|(a, b)| distance(&a, &b)),
        _ => None,
    };
    judge(out, src, distance)
}

/// Same length (so not trimmed) and the same middle frame. Re-encoding the
/// upscale shifts its length by a frame or so (measured 0.03s).
pub fn video_unchanged(out: &OutputDir, src: &Path, dest: &Path) -> bool {
    let distance = duration(src).zip(duration(dest)).and_then(|(a, b)| {
        if (a - b).abs() > 0.2 {
            return Some(f64::INFINITY);
        }
        Some(distance(&thumb(src, Some(a / 2.0))?, &thumb(dest, Some(a / 2.0))?))
    });
    judge(out, src, distance)
}

fn judge(out: &OutputDir, src: &Path, distance: Option<f64>) -> bool {
    match distance {
        Some(d) => out.log(&format!("{}: distance {d:.2} from its upscale", src.display())),
        None => out.log(&format!("{}: could not compare with its upscale", src.display())),
    }
    distance.is_some_and(|d| d < SAME_BELOW)
}

/// RGB bytes of the frame at `at_secs` (or the image), shrunk to SIDE x SIDE.
fn thumb(path: &Path, at_secs: Option<f64>) -> Option<Vec<u8>> {
    let scale = format!("scale={SIDE}:{SIDE}:flags=area");
    // Camera HEICs are tile grids that ffmpeg only reads as a stream group,
    // which -vf can't filter.
    let grid = format!("[0:g:0]{scale}[thumb]");
    let filters: [&[&str]; 2] = [&["-vf", &scale], &["-filter_complex", &grid, "-map", "[thumb]"]];
    filters.iter().find_map(|filter| {
        let mut cmd = Command::new("ffmpeg");
        cmd.args(["-nostdin", "-v", "error"]);
        if let Some(secs) = at_secs {
            cmd.args(["-ss", &format!("{secs:.3}")]);
        }
        cmd.arg("-i").arg(path).args(*filter).args(["-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", "-"]);
        let out = cmd.output().ok()?;
        (out.stdout.len() == THUMB_BYTES).then_some(out.stdout)
    })
}

fn duration(video: &Path) -> Option<f64> {
    let out = Command::new("ffprobe")
        .args(["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0"])
        .arg(video)
        .output()
        .ok()?;
    String::from_utf8_lossy(&out.stdout).trim().parse().ok()
}

/// Mean per-channel difference, at whichever rotation of `a` matches best.
fn distance(a: &[u8], b: &[u8]) -> f64 {
    let mut a = a.to_vec();
    let mut best = f64::INFINITY;
    for _ in 0..4 {
        let total: u32 = a.iter().zip(b).map(|(x, y)| x.abs_diff(*y) as u32).sum();
        best = best.min(total as f64 / THUMB_BYTES as f64);
        a = rotate(&a);
    }
    best
}

/// Quarter turn clockwise.
fn rotate(rgb: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(rgb.len());
    for row in 0..SIDE {
        for col in 0..SIDE {
            let i = ((SIDE - 1 - col) * SIDE + row) * 3;
            out.extend_from_slice(&rgb[i..i + 3]);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn distance_ignores_rotation_but_not_content() {
        // Red top-left pixel on black: every quarter turn moves it to a new corner.
        let mut a = vec![0; THUMB_BYTES];
        a[0] = 255;
        let turned = rotate(&a);
        assert_eq!(&turned[(SIDE - 1) * 3..SIDE * 3], &[255, 0, 0]);
        assert_eq!(distance(&a, &turned), 0.0);
        assert_eq!(distance(&a, &rotate(&rotate(&turned))), 0.0);
        assert!(distance(&a, &vec![0; THUMB_BYTES]) > 0.0);
    }
}
