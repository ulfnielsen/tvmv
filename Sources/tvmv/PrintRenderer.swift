import TVMVCore
import AppKit
import WebKit

/// Print and Save as PDF through the existing web pipeline (cmark HTML plus
/// the built-in theme). An offscreen web view, in a window that is never
/// shown, renders the current text — unsaved edits included — and once
/// enrichment (highlighting, KaTeX, Mermaid) has finished the print panel
/// runs as a sheet on the document window.
@MainActor
final class PrintRenderer {
    /// The print in flight; the next print replaces it.
    private static var current: PrintRenderer?

    private let coordinator: PreviewCoordinator
    private let webView: WKWebView
    private let offscreen: NSWindow

    static func print(text: String, title: String?, documentDirectory: URL?, sheetWindow: NSWindow?) {
        current = PrintRenderer(text: text, title: title, documentDirectory: documentDirectory, sheetWindow: sheetWindow)
    }

    private init(text: String, title: String?, documentDirectory: URL?, sheetWindow: NSWindow?) {
        offscreen = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 1000),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        coordinator = PreviewCoordinator(callbacks: MarkdownWebViewCallbacks())
        webView = WKWebView(frame: offscreen.contentView!.bounds,
                            configuration: coordinator.makeConfiguration(appWebDir: WebResources.baseURL,
                                                                         docDir: documentDirectory))
        offscreen.contentView!.addSubview(webView)
        let controller = coordinator.attach(webView)
        var printed = false
        coordinator.callbacks.onReady = {
            Task { @MainActor in
                await controller.setContent(bodyHTML: renderHTML(text),
                                            docBaseHref: "\(AssetSchemeHandler.scheme)://doc/")
                await controller.applyStyle(json: AppSettings.shared.styleJSON)
            }
        }
        coordinator.callbacks.onRenderComplete = { [weak self] in
            guard !printed else { return }
            printed = true
            controller.printDocument(jobTitle: title, sheetWindow: sheetWindow)
            self?.webView.configuration.userContentController.removeScriptMessageHandler(forName: "tvmv")
        }
    }
}
