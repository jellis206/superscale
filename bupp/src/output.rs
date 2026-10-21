//! Output folders (`DIR-upped`, `DIR-upped-videos`), their logs, and temp dirs.

use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Output as ProcessOutput};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

use anyhow::{Context, Result, bail};

/// A folder with more files than this is never trashed without asking.
const ASK_ABOVE: usize = 32;

pub struct OutputDir {
    pub dir: PathBuf,
    logs: PathBuf,
    /// Picking up an earlier run: files already in `dir` are done.
    pub resume: bool,
    log_lock: Mutex<()>,
}

impl OutputDir {
    /// Gets `dir` ready to write into. An existing folder is trashed, unless it
    /// has more than 32 files: then the user picks resume, delete, or quit.
    pub fn prepare(dir: PathBuf) -> Result<Self> {
        let logs = PathBuf::from(format!("{}.logs", dir.display()));
        let mut resume = false;
        if dir.exists() {
            let files = count_files(&dir)?;
            if files <= ASK_ABOVE {
                trash(&dir)?;
            } else {
                let question = format!(
                    "{} already has {files} files. [r]esume, [d]elete and start over, or [q]uit? ",
                    dir.display()
                );
                match ask(&question).as_deref() {
                    None => {
                        eprintln!("no terminal to ask, resuming");
                        resume = true;
                    }
                    Some("r") => resume = true,
                    Some("d") => trash(&dir)?,
                    Some(_) => bail!("quit"),
                }
            }
        }
        if logs.exists() && !resume {
            trash(&logs)?;
        }
        fs::create_dir_all(&dir)?;
        fs::create_dir_all(&logs)?;
        Ok(OutputDir { dir, logs, resume, log_lock: Mutex::new(()) })
    }

    /// True when resuming and `path` is already there.
    pub fn done_before(&self, path: &Path) -> bool {
        self.resume && path.exists()
    }

    /// Appends a command and everything it printed to process.log, in one piece
    /// so parallel workers don't interleave.
    pub fn log_command(&self, command: &Command, result: &std::io::Result<ProcessOutput>) {
        let mut text = format!("$ {command:?}\n");
        match result {
            Ok(out) => {
                text += &String::from_utf8_lossy(&out.stdout);
                text += &String::from_utf8_lossy(&out.stderr);
            }
            Err(e) => text += &format!("failed to start: {e}\n"),
        }
        self.append("process.log", &text);
    }

    pub fn log(&self, text: &str) {
        self.append("process.log", &format!("{text}\n"));
    }

    /// Records `name` in success.log or failed.log.
    pub fn record(&self, name: &str, ok: bool) {
        let file = if ok { "success.log" } else { "failed.log" };
        self.append(file, &format!("{name}\n"));
        if !ok {
            println!("  FAILED (see {})", self.logs.join("process.log").display());
        }
    }

    fn append(&self, file: &str, text: &str) {
        let _guard = self.log_lock.lock().unwrap();
        let opened = OpenOptions::new().create(true).append(true).open(self.logs.join(file));
        if let Ok(mut f) = opened {
            let _ = f.write_all(text.as_bytes());
        }
    }
}

/// Runs `command`, logging it and its output. True if it succeeded.
pub fn run_logged(out: &OutputDir, mut command: Command) -> bool {
    let result = command.output();
    out.log_command(&command, &result);
    matches!(result, Ok(o) if o.status.success())
}

fn count_files(dir: &Path) -> Result<usize> {
    let mut n = 0;
    for entry in fs::read_dir(dir)? {
        if entry?.file_type()?.is_file() {
            n += 1;
        }
    }
    Ok(n)
}

/// Moves `path` to the Trash, so a replaced folder can still be recovered.
fn trash(path: &Path) -> Result<()> {
    let ok = Command::new("trash").arg(path).status().is_ok_and(|s| s.success());
    if !ok {
        bail!("could not move {} to the Trash", path.display());
    }
    Ok(())
}

/// Asks on the terminal, even when stdin is redirected. None without one.
fn ask(question: &str) -> Option<String> {
    let mut tty = OpenOptions::new().read(true).write(true).open("/dev/tty").ok()?;
    tty.write_all(question.as_bytes()).ok()?;
    let mut answer = String::new();
    BufReader::new(tty).read_line(&mut answer).ok()?;
    Some(answer.trim().to_lowercase())
}

/// Moves a file, falling back to copy + delete across volumes.
pub fn move_file(from: &Path, to: &Path) -> Result<()> {
    if fs::rename(from, to).is_err() {
        fs::copy(from, to).with_context(|| format!("copying to {}", to.display()))?;
        fs::remove_file(from)?;
    }
    Ok(())
}

/// Copies a file in under a temporary name, so an interrupted copy never
/// looks finished to a later resume.
pub fn copy_whole(from: &Path, to: &Path) -> Result<()> {
    let part = PathBuf::from(format!("{}.part", to.display()));
    fs::copy(from, &part)?;
    fs::rename(&part, to)?;
    Ok(())
}

/// Temp dirs alive right now, so Ctrl-C can clean them up (Drop doesn't run).
static LIVE: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());

/// A directory deleted when dropped, or by `remove_all_temp_dirs` on Ctrl-C.
pub struct TempDir(PathBuf);

impl TempDir {
    pub fn new_in(parent: &Path) -> Result<Self> {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, Ordering::Relaxed);
        let path = parent.join(format!(".bupp-{}-{n}", std::process::id()));
        fs::create_dir_all(&path)?;
        LIVE.lock().unwrap_or_else(|e| e.into_inner()).push(path.clone());
        Ok(TempDir(path))
    }

    pub fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
        LIVE.lock().unwrap_or_else(|e| e.into_inner()).retain(|p| p != &self.0);
    }
}

pub fn remove_all_temp_dirs() {
    for path in LIVE.lock().unwrap_or_else(|e| e.into_inner()).drain(..) {
        let _ = fs::remove_dir_all(path);
    }
}

/// Files in `dir` with one of `extensions` (any case), sorted by name.
pub fn list_files(dir: &Path, extensions: &[&str]) -> Result<Vec<PathBuf>> {
    let mut files = Vec::new();
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        let matches = path
            .extension()
            .and_then(|e| e.to_str())
            .is_some_and(|e| extensions.contains(&e.to_lowercase().as_str()));
        if matches && path.is_file() {
            files.push(path);
        }
    }
    files.sort();
    Ok(files)
}

pub fn file_name(path: &Path) -> String {
    path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

/// Width and height of an image file, via sips.
pub fn image_size(path: &Path) -> Option<(u32, u32)> {
    let out = Command::new("sips").args(["-g", "pixelWidth", "-g", "pixelHeight"]).arg(path).output().ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    let value = |key: &str| {
        text.lines()
            .find_map(|l| l.trim().strip_prefix(key)?.trim().parse().ok())
    };
    Some((value("pixelWidth:")?, value("pixelHeight:")?))
}
