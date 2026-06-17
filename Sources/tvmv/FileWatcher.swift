import Dispatch
import Foundation

/// Watches a single file for content changes and invokes `onChange` on the main actor,
/// debounced. Survives "atomic saves" (write-temp-then-rename, or delete-then-recreate)
/// by detecting `.delete`/`.rename` and re-resolving + re-opening the path.
///
/// All mutable state is confined to a private serial `DispatchQueue` so the type is
/// safe to use from any thread. The user-supplied callback is hopped to the `MainActor`.
final class FileWatcher: @unchecked Sendable {
    private let url: URL
    private let onChange: @MainActor @Sendable () -> Void
    private let debounceInterval: DispatchTimeInterval

    private let queue = DispatchQueue(label: "tvmv.FileWatcher")

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var debounceWorkItem: DispatchWorkItem?
    private var isRunning = false

    init(
        url: URL,
        debounceMilliseconds: Int = 150,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        self.url = url
        self.onChange = onChange
        self.debounceInterval = .milliseconds(debounceMilliseconds)
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.attach()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.debounceWorkItem?.cancel()
            self.debounceWorkItem = nil
            self.teardownSource()
        }
    }

    deinit {
        source?.cancel()
        if fileDescriptor >= 0 { close(fileDescriptor) }
    }

    // MARK: - Private (all run on `queue`)

    private func attach() {
        teardownSource()

        let path = url.resolvingSymlinksInPath().path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                guard let self, self.isRunning else { return }
                self.attach()
            }
            return
        }
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
