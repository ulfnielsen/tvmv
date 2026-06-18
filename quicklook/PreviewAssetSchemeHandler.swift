import Foundation
import WebKit
import UniformTypeIdentifiers

/// Custom URL scheme handler for `tvmv-asset://` inside the QuickLook extension.
///
/// Host-based routing:
///   - `tvmv-asset://app/<path>` -> the appex's bundled `web/` directory.
///   - `tvmv-asset://doc/<path>` -> the previewed document's directory
///     (best-effort: the QuickLook sandbox may deny sibling files; that's
///     acceptable — the page still renders without those images).
///
/// This is a self-contained copy of the app's AssetSchemeHandler so the
/// extension links only the renderer files it needs, not the whole app target.
@MainActor
final class PreviewAssetSchemeHandler: NSObject, WKURLSchemeHandler {

    private let appBaseDir: URL
    private let docBaseDir: URL?

    init(appBaseDir: URL, docBaseDir: URL?) {
        self.appBaseDir = appBaseDir.standardizedFileURL
        self.docBaseDir = docBaseDir?.standardizedFileURL
        super.init()
    }

    enum SchemeError: Error {
        case malformedURL
        case unknownHost(String)
        case noDocumentDirectory
        case pathTraversal
        case notFound
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        do {
            let fileURL = try resolve(urlSchemeTask.request.url)
            let data = try Data(contentsOf: fileURL)
            let response = URLResponse(
                url: urlSchemeTask.request.url ?? fileURL,
                mimeType: Self.mimeType(for: fileURL),
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private func resolve(_ url: URL?) throws -> URL {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host
        else { throw SchemeError.malformedURL }

        let relativePath = String(components.percentEncodedPath.dropFirst())
        let decoded = relativePath.removingPercentEncoding ?? relativePath

        let baseDir: URL
        switch host {
        case "app": baseDir = appBaseDir
        case "doc":
            guard let docBaseDir else { throw SchemeError.noDocumentDirectory }
            baseDir = docBaseDir
        default: throw SchemeError.unknownHost(host)
        }

        let candidate = baseDir.appendingPathComponent(decoded).standardizedFileURL
        try Self.confine(candidate, within: baseDir)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw SchemeError.notFound
        }
        return candidate
    }

    private static func confine(_ candidate: URL, within base: URL) throws {
        let basePath = base.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        if candidatePath == basePath { return }
        let basePrefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        guard candidatePath.hasPrefix(basePrefix) else {
            throw SchemeError.pathTraversal
        }
    }

    static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension
        if !ext.isEmpty,
           let type = UTType(filenameExtension: ext),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}
