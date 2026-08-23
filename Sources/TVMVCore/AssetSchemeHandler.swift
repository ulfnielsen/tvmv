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
public final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {

    public static let scheme = "tvmv-asset"

    /// Base directory for bundled application web resources (the `web/` folder).
    private let appBaseDir: URL

    /// Directory of the currently-open document. Updated as the user opens
    /// different documents. `nil` means "no document loaded yet".
    private var docBaseDir: URL?

    public init(appBaseDir: URL, docBaseDir: URL? = nil) {
        self.appBaseDir = appBaseDir.standardizedFileURL
        self.docBaseDir = docBaseDir?.standardizedFileURL
        super.init()
    }

    /// Setter so each web view can update its current document directory.
    public func setDocumentDirectory(_ url: URL?) {
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

    /// In-flight reads by scheme task, so `stop` can cancel abandoned requests
    /// instead of letting them read whole files nobody will consume.
    private var activeReads: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// Files stream to WebKit in bounded chunks: a large linked image never
    /// exists as one complete extra `Data` on the main actor, and the blocking
    /// read syscalls happen off it.
    private nonisolated static let chunkSize = 1 << 20

    public func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        let requestURL = urlSchemeTask.request.url
        // The Task inherits this class's main-actor isolation, so every
        // urlSchemeTask callback below runs on the main actor; cancellation
        // (also main-actor) can only interleave at await points, and each
        // callback is preceded by a cancellation check with no await between —
        // WebKit's "no callbacks after stop" contract holds by construction.
        let task = Task { [weak self] in
            defer { self?.activeReads[id] = nil }
            guard let self else { return }
            do {
                let fileURL = try self.resolve(requestURL)
                try await Self.stream(fileURL, requestURL: requestURL, to: urlSchemeTask)
            } catch is CancellationError {
                // Stopped by WebKit; no further callbacks allowed or needed.
            } catch {
                if !Task.isCancelled { urlSchemeTask.didFailWithError(error) }
            }
        }
        activeReads[id] = task
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        activeReads[id]?.cancel()
        activeReads[id] = nil
    }

    private static func stream(
        _ fileURL: URL,
        requestURL: URL?,
        to task: any WKURLSchemeTask
    ) async throws {
        let fd = open(fileURL.path, O_RDONLY)
        guard fd >= 0 else { throw SchemeError.notFound }
        defer { close(fd) }

        var stats = stat()
        let size = fstat(fd, &stats) == 0 ? Int(stats.st_size) : -1

        try Task.checkCancellation()
        task.didReceive(URLResponse(
            url: requestURL ?? fileURL,
            mimeType: mimeType(for: fileURL),
            expectedContentLength: size,
            textEncodingName: nil
        ))

        while true {
            let chunk = try await readChunk(fd: fd)
            try Task.checkCancellation()
            if chunk.isEmpty { break }
            task.didReceive(chunk)
        }
        task.didFinish()
    }

    /// One bounded read(2), off the main actor.
    private static func readChunk(fd: Int32) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            var buffer = Data(count: chunkSize)
            let n = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, chunkSize)
            }
            guard n >= 0 else { throw POSIXError(.EIO) }
            buffer.removeSubrange(n..<chunkSize)
            return buffer
        }.value
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
    public static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension
        if !ext.isEmpty,
           let type = UTType(filenameExtension: ext),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}
