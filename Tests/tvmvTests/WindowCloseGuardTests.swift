import XCTest
import AppKit
@testable import tvmv

/// Headless tests for the dirty-close/quit resolution flow. The Save/Don't
/// Save/Cancel prompt is injected (`presentPrompt`), so the whole sequence —
/// flush ordering, choice handling, window closing, quit filtering — runs
/// without UI.
@MainActor
final class WindowCloseGuardTests: XCTestCase {

    /// A closable window plus a guard delegate wired as its window delegate,
    /// with recording closures.
    @MainActor
    private final class Harness {
        let window: NSWindow
        let proxy = CloseGuardDelegate()
        var dirty = true
        var flushCount = 0
        var saveCount = 0
        var promptCount = 0
        var saveSucceeds = true
        var choice: CloseChoice = .cancel
        var closed = false
        // nonisolated(unsafe): only touched in init and deinit; NotificationCenter
        // observer removal is thread-safe.
        private nonisolated(unsafe) var observer: NSObjectProtocol?

        init() {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "test.md"
            window.delegate = proxy
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.closed = true }
            }
            proxy.needsFlow = { [weak self] in self?.dirty ?? false }
            proxy.isDirty = { [weak self] in self?.dirty ?? false }
            proxy.flush = { [weak self] in self?.flushCount += 1 }
            proxy.save = { [weak self] in
                guard let self else { return false }
                self.saveCount += 1
                if self.saveSucceeds { self.dirty = false }
                return self.saveSucceeds
            }
            proxy.presentPrompt = { [weak self] _ in
                guard let self else { return .cancel }
                self.promptCount += 1
                return self.choice
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func testDontSaveClosesWithoutSaving() async {
        let h = Harness()
        h.choice = .dontSave
        let resolved = await h.proxy.resolveForQuit(h.window)
        XCTAssertTrue(resolved)
        XCTAssertTrue(h.closed)
        XCTAssertEqual(h.flushCount, 1)     // flushed BEFORE the prompt
        XCTAssertEqual(h.promptCount, 1)    // exactly one dialog
        XCTAssertEqual(h.saveCount, 0)      // Don't Save must not save
    }

    func testSaveClosesAfterSuccessfulSave() async {
        let h = Harness()
        h.choice = .save
        let resolved = await h.proxy.resolveForQuit(h.window)
        XCTAssertTrue(resolved)
        XCTAssertTrue(h.closed)
        XCTAssertEqual(h.saveCount, 1)
    }

    func testFailedSaveKeepsWindowOpen() async {
        let h = Harness()
        h.choice = .save
        h.saveSucceeds = false
        let resolved = await h.proxy.resolveForQuit(h.window)
        XCTAssertFalse(resolved)
        XCTAssertFalse(h.closed)
    }

    func testCancelKeepsWindowOpen() async {
        let h = Harness()
        h.choice = .cancel
        let resolved = await h.proxy.resolveForQuit(h.window)
        XCTAssertFalse(resolved)
        XCTAssertFalse(h.closed)
        XCTAssertEqual(h.flushCount, 1)
    }

    func testFlushThatCleansSkipsThePromptEntirely() async {
        // Keystrokes inside the editor debounce made the window LOOK like it
        // needed the flow, but the flush reveals nothing was actually changed.
        let h = Harness()
        h.proxy.flush = { [weak h] in
            h?.flushCount += 1
            h?.dirty = false
        }
        let resolved = await h.proxy.resolveForQuit(h.window)
        XCTAssertTrue(resolved)
        XCTAssertTrue(h.closed)
        XCTAssertEqual(h.promptCount, 0)    // no dialog for no changes
    }

    func testQuitFilterSkipsClosedWindows() {
        // A window closed with "Don't Save" lingers in NSApp.windows (SwiftUI
        // releases it lazily) with a still-dirty model. The quit filter must
        // skip it, or ⌘Q would resurrect and re-prompt it.
        let h = Harness()
        XCTAssertFalse(h.window.isVisible)   // never shown = same state as closed
        XCTAssertTrue(h.dirty)
        let pending = AppDelegate.windowsNeedingResolution([h.window])
        XCTAssertTrue(pending.isEmpty)
    }

    func testQuitFilterIncludesVisibleDirtyWindows() throws {
        let h = Harness()
        h.window.orderFront(nil)
        guard h.window.isVisible else {
            throw XCTSkip("headless test host cannot order windows front")
        }
        XCTAssertEqual(AppDelegate.windowsNeedingResolution([h.window]), [h.window])
        // Clean windows never enter the quit flow, visible or not.
        h.dirty = false
        XCTAssertTrue(AppDelegate.windowsNeedingResolution([h.window]).isEmpty)
        h.window.orderOut(nil)
    }

    func testResolveAllStopsAtFirstCancel() async throws {
        let first = Harness(), second = Harness()
        first.choice = .cancel
        second.choice = .dontSave
        first.window.orderFront(nil)
        second.window.orderFront(nil)
        guard first.window.isVisible, second.window.isVisible else {
            throw XCTSkip("headless test host cannot order windows front")
        }
        let ok = await AppDelegate.resolveAll([first.window, second.window])
        XCTAssertFalse(ok)                    // quit aborted by the Cancel
        XCTAssertEqual(first.promptCount, 1)
        XCTAssertEqual(second.promptCount, 0) // never reached
        XCTAssertFalse(second.closed)
        first.window.orderOut(nil); second.window.orderOut(nil)
    }

    func testResolveAllResolvesEveryWindowOnOneQuit() async throws {
        let first = Harness(), second = Harness()
        first.choice = .dontSave
        second.choice = .save
        first.window.orderFront(nil)
        second.window.orderFront(nil)
        guard first.window.isVisible, second.window.isVisible else {
            throw XCTSkip("headless test host cannot order windows front")
        }
        let ok = await AppDelegate.resolveAll([first.window, second.window])
        XCTAssertTrue(ok)                     // single quit handles both
        XCTAssertTrue(first.closed)
        XCTAssertTrue(second.closed)
        XCTAssertEqual(second.saveCount, 1)
    }
}
