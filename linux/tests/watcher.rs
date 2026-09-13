//! File-watcher tests, mirroring `Tests/TVMVCoreTests/FileWatcherTests.swift`.
//!
//! These are timing tests against the real filesystem, so the bounds are
//! deliberately loose: they assert the *semantics* (something fired, a burst
//! coalesced) rather than exact counts or latencies.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use tvmv::watcher::FileWatcher;

struct Dir(PathBuf);

impl Dir {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join("tvmv-watcher-tests").join(name);
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn file(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn counter() -> (Arc<AtomicUsize>, impl Fn() + Send + Sync + 'static) {
    let count = Arc::new(AtomicUsize::new(0));
    let handle = Arc::clone(&count);
    (count, move || {
        handle.fetch_add(1, Ordering::SeqCst);
    })
}

/// Poll until `count` is non-zero or the deadline passes.
fn wait_for_fire(count: &Arc<AtomicUsize>, timeout: Duration) -> usize {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        let n = count.load(Ordering::SeqCst);
        if n > 0 {
            return n;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    count.load(Ordering::SeqCst)
}

/// Write without replacing the inode.
fn write_in_place(path: &PathBuf, contents: &str) {
    std::fs::write(path, contents).unwrap();
}

/// Write the way editors do: temp file, then rename over the target.
fn write_atomically(path: &PathBuf, contents: &str) {
    let temp = path.with_extension("tmp-save");
    std::fs::write(&temp, contents).unwrap();
    std::fs::rename(&temp, path).unwrap();
}

#[test]
fn burst_of_writes_coalesces_into_one_callback() {
    let dir = Dir::new("burst");
    let file = dir.file("doc.md");
    write_in_place(&file, "start");

    let (count, cb) = counter();
    let mut watcher = FileWatcher::new(file.clone(), Duration::from_millis(120), cb);
    watcher.start();
    std::thread::sleep(Duration::from_millis(200));

    for i in 0..5 {
        write_in_place(&file, &format!("edit {i}"));
        std::thread::sleep(Duration::from_millis(10));
    }
    std::thread::sleep(Duration::from_millis(500));
    watcher.stop();

    let n = count.load(Ordering::SeqCst);
    assert!(n >= 1, "no callback fired");
    assert!(n <= 2, "burst should coalesce, not fire per-write (fired {n}x)");
}

#[test]
fn in_place_write_fires() {
    let dir = Dir::new("in-place");
    let file = dir.file("doc.md");
    write_in_place(&file, "start");

    let (count, cb) = counter();
    let mut watcher = FileWatcher::new(file.clone(), Duration::from_millis(50), cb);
    watcher.start();
    std::thread::sleep(Duration::from_millis(200));

    write_in_place(&file, "changed");
    assert!(wait_for_fire(&count, Duration::from_secs(3)) >= 1, "in-place write not seen");
    watcher.stop();
}

/// The editor pattern: write a temp file, rename it over the target. The
/// original inode is replaced, which is what breaks naive inode watching.
#[test]
fn atomic_rename_over_fires() {
    let dir = Dir::new("atomic");
    let file = dir.file("doc.md");
    write_in_place(&file, "start");

    let (count, cb) = counter();
    let mut watcher = FileWatcher::new(file.clone(), Duration::from_millis(50), cb);
    watcher.start();
    std::thread::sleep(Duration::from_millis(200));

    write_atomically(&file, "saved by an editor");
    assert!(wait_for_fire(&count, Duration::from_secs(3)) >= 1, "rename-over not seen");
    watcher.stop();
}

/// Two atomic saves in a row: the second must still be seen, i.e. the watch did
/// not die with the first replaced inode.
#[test]
fn repeated_atomic_saves_keep_firing() {
    let dir = Dir::new("atomic-twice");
    let file = dir.file("doc.md");
    write_in_place(&file, "start");

    let (count, cb) = counter();
    let mut watcher = FileWatcher::new(file.clone(), Duration::from_millis(50), cb);
    watcher.start();
    std::thread::sleep(Duration::from_millis(200));

    write_atomically(&file, "first");
    assert!(wait_for_fire(&count, Duration::from_secs(3)) >= 1, "first save not seen");
    let after_first = count.load(Ordering::SeqCst);

    std::thread::sleep(Duration::from_millis(150));
    write_atomically(&file, "second");

    let deadline = Instant::now() + Duration::from_secs(3);
    while Instant::now() < deadline && count.load(Ordering::SeqCst) <= after_first {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(count.load(Ordering::SeqCst) > after_first, "second save not seen");
    watcher.stop();
}

#[test]
fn file_created_after_start_is_picked_up() {
    let dir = Dir::new("late-create");
    let file = dir.file("late.md");

    let (count, cb) = counter();
    let mut watcher = FileWatcher::new(file.clone(), Duration::from_millis(50), cb);
    watcher.start();
    std::thread::sleep(Duration::from_millis(300));

    write_in_place(&file, "hello");
    assert!(wait_for_fire(&count, Duration::from_secs(3)) >= 1, "late creation not seen");
    watcher.stop();
}

#[test]
fn delete_then_recreate_keeps_watching() {
    let dir = Dir::new("delete-recreate");
    let file = dir.file("doc.md");
    write_in_place(&file, "start");

    let (count, cb) = counter();
    let mut watcher = FileWatcher::new(file.clone(), Duration::from_millis(50), cb);
    watcher.start();
    std::thread::sleep(Duration::from_millis(200));

    std::fs::remove_file(&file).unwrap();
    std::thread::sleep(Duration::from_millis(200));
    write_in_place(&file, "back again");

    assert!(wait_for_fire(&count, Duration::from_secs(3)) >= 1, "recreate not seen");
    watcher.stop();
}

/// Events for other files in the same directory must be ignored — the watch is
/// on the directory, so the filter is doing real work.
#[test]
fn other_files_in_the_directory_are_ignored() {
    let dir = Dir::new("sibling-noise");
    let file = dir.file("doc.md");
    write_in_place(&file, "start");

    let (count, cb) = counter();
    let mut watcher = FileWatcher::new(file.clone(), Duration::from_millis(50), cb);
    watcher.start();
    std::thread::sleep(Duration::from_millis(200));

    for i in 0..5 {
        write_in_place(&dir.file(&format!("other-{i}.md")), "noise");
    }
    std::thread::sleep(Duration::from_millis(400));
    watcher.stop();

    assert_eq!(count.load(Ordering::SeqCst), 0, "fired for a sibling file's change");
}

#[test]
fn stop_silences_the_watcher() {
    let dir = Dir::new("stop");
    let file = dir.file("doc.md");
    write_in_place(&file, "start");

    let (count, cb) = counter();
    let mut watcher = FileWatcher::new(file.clone(), Duration::from_millis(50), cb);
    watcher.start();
    std::thread::sleep(Duration::from_millis(200));
    watcher.stop();

    let before = count.load(Ordering::SeqCst);
    write_in_place(&file, "after stop");
    std::thread::sleep(Duration::from_millis(400));
    assert_eq!(count.load(Ordering::SeqCst), before, "fired after stop()");
}

/// A watcher on a path whose directory does not exist must back off rather than
/// spin, and must attach once the directory appears.
#[test]
fn missing_directory_backs_off_then_attaches() {
    let dir = Dir::new("late-dir");
    let subdir = dir.0.join("not-yet");
    let file = subdir.join("doc.md");

    let (count, cb) = counter();
    let mut watcher = FileWatcher::new(file.clone(), Duration::from_millis(50), cb);
    watcher.start();
    std::thread::sleep(Duration::from_millis(300));

    std::fs::create_dir_all(&subdir).unwrap();
    std::thread::sleep(Duration::from_millis(300));
    write_in_place(&file, "hello");

    assert!(wait_for_fire(&count, Duration::from_secs(6)) >= 1, "never attached to late directory");
    watcher.stop();
}

/// `stop()` is idempotent and `drop` must not hang or double-join.
#[test]
fn stop_is_idempotent_and_drop_is_clean() {
    let dir = Dir::new("idempotent");
    let file = dir.file("doc.md");
    write_in_place(&file, "start");

    let (_, cb) = counter();
    let mut watcher = FileWatcher::new(file, Duration::from_millis(50), cb);
    watcher.start();
    watcher.start(); // second start is a no-op
    watcher.stop();
    watcher.stop();
    drop(watcher);
}
