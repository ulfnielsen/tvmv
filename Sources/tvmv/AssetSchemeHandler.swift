import Foundation
import WebKit
import UniformTypeIdentifiers

/// Custom URL scheme handler for `tvmv-asset://`.
///
/// Host-based routing:
///   - `tvmv-asset://app/<path>` -> bundled web resources directory (`appBaseDir`)
///   - `tvmv-asset://doc/<path>` -> the currently-open document's directory
///     (`docBaseDir`), confined against path traversal.
///
/// WKURLSchemeHandler and WKURLSchemeTask are @MainActor-isolated, so this
/// type is too.
@MainActor
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "tvmv-asset"

    /// Base directory for bundled application web resources (the `web/` folder).
    private let appBaseDir: URL

    /// Directory of the currently-open document. Updated as the user opens
    /// different documents. `nil` means "no document loaded yet".
    private var docBaseDir: URL?

    init(appBaseDir: URL, docBaseDir: URL? = nil) {
        self.appBaseDir = appBaseDir.standardizedFileURL
        self.docBaseDir = docBaseDir?.standardizedFileURL
        super.init()
    }

    /// Setter so each web view can update its current document directory.
    func setDocumentDirectory(_ url: URL?) {
        docBaseDir = url?.standardizedFileURL
    }

    enum SchemeError: Error {
        case malformedURL
        case unknownHost(String)
        case noDocumentDirectory
        case pathTraversal
        case notFound
    }

    // MARK: WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        do {
            let fileURL = try resolve(urlSchemeTask.request.url)
            let data = try Data(contentsOf: fileURL)

            let mime = Self.mimeType(for: fileURL)
            let response = URLResponse(
                url: urlSchemeTask.request.url ?? fileURL,
                mimeType: mime,
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

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // Reads are synchronous & best-effort; nothing to cancel.
    }

    // MARK: Resolution

    /// Map a `tvmv-asset://` URL to a confined file URL.
    private func resolve(_ url: URL?) throws -> URL {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host
        else {
            throw SchemeError.malformedURL
        }

        // The path begins with "/"; strip it to get a relative subpath.
        let relativePath = String(components.percentEncodedPath.dropFirst())
        let decoded = relativePath.removingPercentEncoding ?? relativePath

        let baseDir: URL
        switch host {
        case "app":
            baseDir = appBaseDir
        case "doc":
            guard let docBaseDir else { throw SchemeError.noDocumentDirectory }
            baseDir = docBaseDir
        default:
            throw SchemeError.unknownHost(host)
        }

        let candidate = baseDir.appendingPathComponent(decoded).standardizedFileURL

        // Path-traversal confinement: the standardized candidate must live
        // inside (or be) the allowed base directory.
        try Self.confine(candidate, within: baseDir)

        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw SchemeError.notFound
        }
        return candidate
    }

    /// Verify `candidate` is contained within `base` after standardization.
    private static func confine(_ candidate: URL, within base: URL) throws {
        let basePath = base.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path

        if candidatePath == basePath { return }

        let basePrefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        guard candidatePath.hasPrefix(basePrefix) else {
            throw SchemeError.pathTraversal
        }
    }

    /// Derive a MIME type from a file's path extension via UTType.
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
