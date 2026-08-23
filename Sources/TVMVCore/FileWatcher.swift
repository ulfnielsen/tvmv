import Dispatch
import Foundation

/// Watches a single file for content changes and invokes `onChange` on the main actor,
/// debounced. Survives "atomic saves" (write-temp-then-rename, or delete-then-recreate)
/// by detecting `.delete`/`.rename` and re-resolving + re-opening the path.
///
/// All mutable state is confined to a private serial `DispatchQueue` so the type is
/// safe to use from any thread. The user-supplied callback is hopped to the `MainActor`.
public final class FileWatcher: @unchecked Sendable {
    private let url: URL
    private let onChange: @MainActor @Sendable () -> Void
    private let debounceInterval: DispatchTimeInterval

    private let queue = DispatchQueue(label: "tvmv.FileWatcher")

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var debounceWorkItem: DispatchWorkItem?
    private var isRunning = false

    /// Re-attach retry cadence when the path can't be opened (missing file).
    /// Exponential backoff keeps a window on a deleted document from polling
    /// at 10 Hz forever; a successful attach resets it.
    private static let initialRetryMs = 100
    private static let maxRetryMs = 5_000
    private var retryDelayMs = FileWatcher.initialRetryMs

    public init(
        url: URL,
        debounceMilliseconds: Int = 150,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        self.url = url
        self.onChange = onChange
        self.debounceInterval = .milliseconds(debounceMilliseconds)
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.retryDelayMs = Self.initialRetryMs
            self.attach()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.debounceWorkItem?.cancel()
            self.debounceWorkItem = nil
            self.teardownSource()
        }
    }

    deinit {
        // Exactly one owner per descriptor: when a source exists, its cancel
        // handler closes the captured fd (asynchronously, on the queue).
        // Closing here too would free the number for reuse before that handler
        // runs, letting it close an unrelated descriptor.
        if let src = source {
            src.cancel()
        } else if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
    }

    /// Current retry delay, for tests asserting backoff behavior.
    func retryDelayForTesting() -> Int {
        queue.sync { retryDelayMs }
    }

    // MARK: - Private (all run on `queue`)

    private func attach() {
        teardownSource()

        let path = url.resolvingSymlinksInPath().path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            let delay = retryDelayMs
            retryDelayMs = min(retryDelayMs * 2, Self.maxRetryMs)
            queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
                guard let self, self.isRunning else { return }
                self.attach()
            }
            return
        }
        retryDelayMs = Self.initialRetryMs
        fileDescriptor = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .link, .revoke],
            queue: queue
        )

        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
                self.scheduleCallback()
                self.queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                    guard let self, self.isRunning else { return }
                    self.attach()
                }
            } else if flags.contains(.write) || flags.contains(.extend) || flags.contains(.link) {
                self.scheduleCallback()
            }
        }

        src.setCancelHandler { [fd] in close(fd) }

        source = src
        src.resume()
    }

    private func teardownSource() {
        if let src = source {
            source = nil
            fileDescriptor = -1
            src.cancel()
        } else if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    private func scheduleCallback() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            let cb = self.onChange
            Task { @MainActor in cb() }
        }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
