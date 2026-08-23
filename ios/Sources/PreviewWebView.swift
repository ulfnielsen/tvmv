import SwiftUI
import WebKit
import TVMVCore

/// UIKit twin of the Mac app's MarkdownWebView: a thin shell over the shared
/// PreviewCoordinator/MarkdownWebController pair in TVMVCore.
struct PreviewWebView: UIViewRepresentable {
    let appWebDir: URL
    var docDir: URL?
    var callbacks: MarkdownWebViewCallbacks = .init()
    var onMakeController: (@MainActor (MarkdownWebController) -> Void)?

    func makeCoordinator() -> PreviewCoordinator {
        let coordinator = PreviewCoordinator(callbacks: callbacks)
        coordinator.openExternalURL = { UIApplication.shared.open($0) }
        return coordinator
    }

    func makeUIView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let webView = WKWebView(
            frame: .zero,
            configuration: coordinator.makeConfiguration(appWebDir: appWebDir,
                                                         docDir: docDir))
        webView.scrollView.keyboardDismissMode = .interactive
        let controller = coordinator.attach(webView)
        onMakeController?(controller)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.setDocumentDirectory(docDir)
        context.coordinator.callbacks = callbacks
    }
}
