//! A worker pool that keeps adding workers while that keeps making it faster.
//!
//! Every superscale process shares the Mac's one Neural Engine, so past a few
//! workers they just queue for it. How many pay off depends on the chip and the
//! model, so the pool measures instead of guessing: it starts with 3, adds one
//! whenever the last addition raised throughput by 10% or more, and settles at
//! the first one that didn't. RAM only caps it.

use std::collections::VecDeque;
use std::process::Command;
use std::sync::{Mutex, mpsc};
use std::thread;
use std::time::Instant;

/// Rough peak memory of one superscale process (measured ~2.9 GB).
const BYTES_PER_WORKER: u64 = 3 << 30;
/// How much faster a level must be than the one before to earn another worker.
const MIN_GAIN: f64 = 1.10;

/// How many superscale processes to run at once. Shared across pool runs, so
/// once one run has settled on a count the next starts there.
pub struct Workers {
    count: usize,
    cap: usize,
    settled: bool,
}

impl Workers {
    /// `Some(n)` is a fixed count (JOBS); `None` tunes itself.
    pub fn new(fixed: Option<usize>) -> Self {
        match fixed {
            Some(n) => Self::fixed(n),
            None => {
                let cap = ((ram_bytes() / 2) / BYTES_PER_WORKER).max(1) as usize;
                Workers { count: 3.min(cap), cap, settled: false }
            }
        }
    }

    pub fn fixed(n: usize) -> Self {
        Workers { count: n.max(1), cap: n.max(1), settled: true }
    }

    pub fn count(&self) -> usize {
        self.count
    }
}

/// Runs `work` on every task across `workers`, handing each result to `done`
/// on this thread as it arrives, along with the number of workers running.
pub fn run<T: Send, R: Send>(
    tasks: Vec<T>,
    workers: &mut Workers,
    work: impl Fn(T) -> R + Sync,
    mut done: impl FnMut(R, usize),
) {
    let total = tasks.len();
    if total == 0 {
        return;
    }
    let queue = Mutex::new(VecDeque::from(tasks));
    let (tx, rx) = mpsc::channel();

    thread::scope(|scope| {
        let spawn_worker = || {
            let (tx, queue, work) = (tx.clone(), &queue, &work);
            scope.spawn(move || {
                loop {
                    let next = queue.lock().unwrap().pop_front();
                    let Some(task) = next else { break };
                    if tx.send(work(task)).is_err() {
                        break;
                    }
                }
            });
        };

        let mut running = workers.count.min(total);
        for _ in 0..running {
            spawn_worker();
        }

        // Throughput is measured per "level" (a stretch at one worker count),
        // over 2 completions per worker so each one has finished something.
        let mut level_start = Instant::now();
        let mut level_done = 0;
        let mut last_rate: Option<f64> = None;

        for _ in 0..total {
            done(rx.recv().expect("a worker died"), running);
            if workers.settled {
                continue;
            }
            level_done += 1;
            if level_done < 2 * running {
                continue;
            }
            let rate = level_done as f64 / level_start.elapsed().as_secs_f64();
            let faster = last_rate.is_none_or(|last| rate >= last * MIN_GAIN);
            let more_work = !queue.lock().unwrap().is_empty();
            if faster && running < workers.cap && more_work {
                spawn_worker();
                running += 1;
                workers.count = running;
                last_rate = Some(rate);
                level_start = Instant::now();
                level_done = 0;
            } else if more_work || !faster {
                // Out of headroom, or the last worker didn't help: stop here.
                workers.settled = true;
            }
        }
    });
}

fn ram_bytes() -> u64 {
    Command::new("sysctl")
        .args(["-n", "hw.memsize"])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(16 << 30)
}
