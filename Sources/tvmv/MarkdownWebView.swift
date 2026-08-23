import TVMVCore
import SwiftUI
import AppKit
import WebKit

/// NSViewRepresentable wrapping the WKWebView that hosts the markdown
/// renderer. All bridge logic lives in TVMVCore's PreviewCoordinator /
/// MarkdownWebController; this shell supplies the AppKit web view and the
/// platform link-opening behavior.
struct MarkdownWebView: NSViewRepresentable {

    /// Base directory of bundled web resources (the `web/` folder).
    let appWebDir: URL

    /// Directory of the currently-open document (for `tvmv-asset://doc/...`).
    var docDir: URL?

    /// Callbacks back into SwiftUI.
    var callbacks: MarkdownWebViewCallbacks = .init()

    /// Lets the owning view grab a handle to the controller for imperative calls.
    var onMakeController: (@MainActor (MarkdownWebController) -> Void)?

    func makeCoordinator() -> PreviewCoordinator {
        let coordinator = PreviewCoordinator(callbacks: callbacks)
        coordinator.openExternalURL = { NSWorkspace.shared.open($0) }
        return coordinator
    }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let webView = WKWebView(
            frame: .zero,
            configuration: coordinator.makeConfiguration(appWebDir: appWebDir, docDir: docDir))
        webView.allowsMagnification = true   // trackpad pinch-to-zoom (macOS-only API)
        let controller = coordinator.attach(webView)
        onMakeController?(controller)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.setDocumentDirectory(docDir)
        context.coordinator.callbacks = callbacks
    }
}
