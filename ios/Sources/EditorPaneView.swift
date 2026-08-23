import SwiftUI
import WebKit
import TVMVCore

/// UIKit twin of the Mac app's CodeMirrorEditorPane: a thin shell over the
/// shared EditorCoordinator/EditorBridge pair in TVMVCore.
struct EditorPaneView: UIViewRepresentable {
    let appWebDir: URL
    var callbacks: EditorBridgeCallbacks = .init()
    var onMakeBridge: (@MainActor (EditorBridge) -> Void)?

    func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator(callbacks: callbacks)
    }

    func makeUIView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let webView = WKWebView(
            frame: .zero,
            configuration: coordinator.makeConfiguration(appWebDir: appWebDir))
        let bridge = coordinator.attach(webView)
        onMakeBridge?(bridge)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.callbacks = callbacks
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: EditorCoordinator) {
        coordinator.detach(uiView)
    }
}
