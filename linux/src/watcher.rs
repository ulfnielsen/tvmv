//! Watches a single file for content changes, debounced.
//!
//! Port of `Sources/TVMVCore/FileWatcher.swift`, with a different mechanism for
//! the same guarantees: survive "atomic saves" (write-temp-then-rename) and
//! delete-then-recreate, and pick up a file that does not exist yet.
//!
//! # Why the parent directory, not the file
//!
//! The Swift version watches the file's *inode* (`O_EVTONLY` + a
//! `DispatchSource`) and re-attaches when it sees `.delete`/`.rename`, polling
//! on a backoff while the path is missing. inotify offers a better fit: watching
//! the containing directory and filtering by name catches the replacement
//! directly — an editor's rename-over arrives as `MOVED_TO` for our filename,
//! and a file created after `start()` arrives as `CREATE`. No inode to lose, and
//! no polling for the common case.
//!
//! Backoff polling remains for the case the *directory* is missing.
//!
//! The callback fires on the watcher's own thread. The shell marshals it to the
//! GTK main loop (Task 8); this module stays free of GTK so it can be tested
//! headless.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, channel};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use notify::{Event, RecursiveMode, Watcher};

pub const DEFAULT_DEBOUNCE: Duration = Duration::from_millis(150);

/// Retry cadence when the containing directory cannot be watched. Exponential
/// backoff keeps a window on a deleted tree from polling at 10 Hz forever; a
/// successful attach resets it.
const INITIAL_RETRY: Duration = Duration::from_millis(100);
const MAX_RETRY: Duration = Duration::from_millis(5_000);

/// How often the loop wakes to notice `stop()`.
const TICK: Duration = Duration::from_millis(50);

pub struct FileWatcher {
    path: PathBuf,
    debounce: Duration,
    on_change: Arc<dyn Fn() + Send + Sync>,
    running: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
}

impl FileWatcher {
    pub fn new(
        path: impl Into<PathBuf>,
        debounce: Duration,
        on_change: impl Fn() + Send + Sync + 'static,
    ) -> Self {
        Self {
            path: path.into(),
            debounce,
            on_change: Arc::new(on_change),
            running: Arc::new(AtomicBool::new(false)),
            handle: None,
        }
    }

    pub fn start(&mut self) {
        if self.running.swap(true, Ordering::SeqCst) {
            return; // already running
        }
        let path = self.path.clone();
        let debounce = self.debounce;
        let on_change = Arc::clone(&self.on_change);
        let running = Arc::clone(&self.running);

        self.handle = Some(std::thread::spawn(move || {
            watch_loop(&path, debounce, &on_change, &running);
        }));
    }

    pub fn stop(&mut self) {
        self.running.store(false, Ordering::SeqCst);
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for FileWatcher {
    fn drop(&mut self) {
        self.stop();
    }
}

fn watch_loop(
    path: &Path,
    debounce: Duration,
    on_change: &Arc<dyn Fn() + Send + Sync>,
    running: &Arc<AtomicBool>,
) {
    let mut retry = INITIAL_RETRY;

    while running.load(Ordering::SeqCst) {
        let Some(parent) = path.parent() else { return };

        let (tx, rx) = channel::<notify::Result<Event>>();
        let watcher = notify::recommended_watcher(move |res| {
            let _ = tx.send(res);
        })
        .ok()
        .and_then(|mut w| w.watch(parent, RecursiveMode::NonRecursive).ok().map(|_| w));

        let Some(_watcher) = watcher else {
            // Directory missing or unwatchable — back off and try again.
            sleep_interruptibly(retry, running);
            retry = (retry * 2).min(MAX_RETRY);
            continue;
        };
        retry = INITIAL_RETRY;

        // Returns when the watch is lost (directory removed) so the outer loop
        // re-attaches, or when stopped.
        drain(&rx, path, debounce, on_change, running);
    }
}

/// Trailing-edge debounce: a burst of writes collapses into one callback fired
/// `debounce` after the last event, matching the Swift work-item cancellation.
fn drain(
    rx: &Receiver<notify::Result<Event>>,
    path: &Path,
    debounce: Duration,
    on_change: &Arc<dyn Fn() + Send + Sync>,
    running: &Arc<AtomicBool>,
) {
    let mut pending: Option<Instant> = None;

    loop {
        if !running.load(Ordering::SeqCst) {
            return;
        }

        // Wake often enough to observe stop(), and no later than the moment a
        // pending callback comes due.
        let timeout = match pending {
            Some(deadline) => debounce
                .saturating_sub(deadline.elapsed())
                .min(TICK)
                .max(Duration::from_millis(1)),
            None => TICK,
        };

        match rx.recv_timeout(timeout) {
            Ok(Ok(event)) => {
                if event.paths.iter().any(|p| p == path) {
                    pending = Some(Instant::now());
                }
            }
            // The watch backend reported an error; re-attach from the outer loop.
            Ok(Err(_)) => return,
            Err(RecvTimeoutError::Timeout) => {}
            // Sender dropped: the watcher is gone.
            Err(RecvTimeoutError::Disconnected) => return,
        }

        if let Some(started) = pending
            && started.elapsed() >= debounce
        {
            pending = None;
            on_change();
        }
    }
}

fn sleep_interruptibly(total: Duration, running: &Arc<AtomicBool>) {
    let deadline = Instant::now() + total;
    while Instant::now() < deadline {
        if !running.load(Ordering::SeqCst) {
            return;
        }
        std::thread::sleep(TICK.min(deadline - Instant::now()));
    }
}
