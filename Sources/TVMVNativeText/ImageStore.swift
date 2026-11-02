import CoreGraphics
import Foundation
import ImageIO
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Where an image address points and how its bytes are fetched.
public enum ImageSource {
    /// Where an image address points. Like the web reader, local images come
    /// only from inside the document's folder (no "../", absolute paths or
    /// file URLs); http, https and data URLs load as written.
    public static func url(_ address: String, documentURL: URL?) -> URL? {
        if let url = URL(string: address), let scheme = url.scheme?.lowercased() {
            return ["http", "https", "data"].contains(scheme) ? url : nil
        }
        let path = address.removingPercentEncoding ?? address
        guard !path.hasPrefix("/"), let folder = documentURL?.deletingLastPathComponent().standardizedFileURL
        else { return nil }
        let candidate = folder.appendingPathComponent(path).standardizedFileURL
        return isInside(candidate, folder) ? candidate : nil
    }

    nonisolated public static func isInside(_ candidate: URL, _ folder: URL) -> Bool {
        let base = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        return candidate.path.hasPrefix(base)
    }

    /// Read a local image: a regular file, still inside the folder once
    /// symlinks are resolved, and no larger than `limit`.
    nonisolated public static func readLocal(_ url: URL, folder: URL, limit: Int) -> Data? {
        let real = url.resolvingSymlinksInPath()
        guard isInside(real, folder.resolvingSymlinksInPath()),
              let values = try? real.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= limit
        else { return nil }
        return try? Data(contentsOf: real)
    }

    /// Download at most `limit` bytes; nil if there is more.
    nonisolated public static func download(_ url: URL, limit: Int) async -> Data? {
        guard let (bytes, response) = try? await URLSession.shared.bytes(from: url),
              response.expectedContentLength <= Int64(limit) else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { return nil }
            }
        } catch { return nil }
        return data
    }
}

public enum ImageDecoder {
    /// Decode within `maxPixels`, failing closed:
    /// - a raster image must report dimensions for every frame, and all its
    ///   frames together must fit the limit (the image loads them all);
    /// - on macOS, an image ImageIO can't measure loads only if it is purely
    ///   vector (SVG, PDF) and its declared size fits the same limit;
    /// - anything else is refused.
    public static func decode(_ data: Data, maxPixels: Int) -> PlatformImage? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
           CGImageSourceGetType(source) != nil {
            var total = 0
            for index in 0..<CGImageSourceGetCount(source) {
                guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int
                else { return nil }
                let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
                guard !overflow else { return nil }
                total += pixels
                if total > maxPixels { return nil }
            }
            #if os(macOS)
            return NSImage(data: data)
            #else
            return UIImage(data: data)
            #endif
        }
        #if os(macOS)
        guard let picture = NSImage(data: data), !picture.representations.isEmpty,
              picture.representations.allSatisfy({ !($0 is NSBitmapImageRep) }),
              picture.size.width * picture.size.height <= CGFloat(maxPixels)
        else { return nil }
        return picture
        #else
        return nil
        #endif
    }
}

/// Block images by their address as written, loaded once and cached.
@MainActor
public final class ImageStore {
    public enum State: Equatable { case loading, loaded, failed }

    /// A document is untrusted: cap what one image may cost.
    public var maxBytes = 50_000_000
    public var maxPixels = 100_000_000
    /// The document's file: relative image paths resolve against its folder.
    public var documentURL: URL?

    private var images: [String: (state: State, image: PlatformImage?)] = [:]

    public init() {}

    public func state(for address: String) -> State? { images[address]?.state }
    public func image(for address: String) -> PlatformImage? { images[address]?.image }

    /// Start loading every address not yet requested; `onLoaded` runs on the
    /// main actor once each settles, loaded or failed.
    public func request(_ addresses: [String], onLoaded: @escaping @MainActor (String) -> Void) {
        for address in addresses where images[address] == nil {
            images[address] = (.loading, nil)
            guard let url = ImageSource.url(address, documentURL: documentURL) else {
                loaded(address, data: nil, onLoaded)
                continue
            }
            let limit = maxBytes
            let folder = documentURL?.deletingLastPathComponent().standardizedFileURL
            Task {
                let data: Data?
                switch url.scheme?.lowercased() {
                case "http", "https":
                    data = await ImageSource.download(url, limit: limit)
                case "data":
                    data = (try? Data(contentsOf: url)).flatMap { $0.count <= limit ? $0 : nil }
                default:
                    data = await Task.detached(priority: .utility) {
                        folder.flatMap { ImageSource.readLocal(url, folder: $0, limit: limit) }
                    }.value
                }
                self.loaded(address, data: data, onLoaded)
            }
        }
    }

    private func loaded(_ address: String, data: Data?, _ onLoaded: @MainActor (String) -> Void) {
        let picture = data.flatMap { ImageDecoder.decode($0, maxPixels: maxPixels) }
        images[address] = (picture == nil ? .failed : .loaded, picture)
        onLoaded(address)
    }
}
