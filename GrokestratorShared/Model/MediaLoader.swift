import Foundation
import SwiftUI

/// Loads media artifacts that live on a (possibly remote) host, caching each so
/// the UI fetches it once. Thumbnails/posters stay in memory; full files are
/// written to a temp file and reused for AVPlayer / QuickLook. Backed by the
/// driver's `fetchMedia`. One instance per conversation, injected via the
/// `\.mediaLoader` environment value.
@MainActor
final class MediaLoader {
    private let fetch: @Sendable (_ path: String, _ maxDimension: Int?) async -> (data: Data, mimeType: String)?

    private var thumbs: [String: Data] = [:]                 // "path|dim" → jpeg bytes
    private var fullURLs: [String: URL] = [:]                // path → temp file
    private var inFlightThumb: [String: Task<Data?, Never>] = [:]
    private var inFlightFull: [String: Task<URL?, Never>] = [:]

    init(fetch: @escaping @Sendable (_ path: String, _ maxDimension: Int?) async -> (data: Data, mimeType: String)?) {
        self.fetch = fetch
    }

    /// A downscaled thumbnail / video poster (JPEG bytes), cached in memory.
    /// Concurrent requests for the same key share one fetch.
    func thumbnail(path: String, maxDimension: Int) async -> Data? {
        let key = "\(path)|\(maxDimension)"
        if let d = thumbs[key] { return d }
        if let t = inFlightThumb[key] { return await t.value }
        let fetch = self.fetch
        let task = Task { await fetch(path, maxDimension)?.data }
        inFlightThumb[key] = task
        let data = await task.value
        inFlightThumb[key] = nil
        if let data { thumbs[key] = data }
        return data
    }

    /// The full file written to a temp URL (for AVPlayer / QuickLook), cached.
    func fullFileURL(path: String, preferredExtension ext: String) async -> URL? {
        if let u = fullURLs[path], FileManager.default.fileExists(atPath: u.path) { return u }
        if let t = inFlightFull[path] { return await t.value }
        let fetch = self.fetch
        let task = Task { () -> URL? in
            guard let r = await fetch(path, nil) else { return nil }
            let base = (path as NSString).lastPathComponent
            let name = base.isEmpty ? "file.\(ext)" : base
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("gk-media-\(UInt(bitPattern: path.hashValue))-\(name)")
            return (try? r.data.write(to: tmp, options: .atomic)) != nil ? tmp : nil
        }
        inFlightFull[path] = task
        let url = await task.value
        inFlightFull[path] = nil
        if let url { fullURLs[path] = url }
        return url
    }

    /// Full file bytes (reads the cached temp file). Handy for image fullscreen
    /// / share where a `UIImage`/`NSImage` is wanted rather than a URL.
    func full(path: String, preferredExtension ext: String) async -> Data? {
        guard let url = await fullFileURL(path: path, preferredExtension: ext) else { return nil }
        return try? Data(contentsOf: url)
    }
}

private struct MediaLoaderKey: EnvironmentKey {
    static let defaultValue: MediaLoader? = nil
}

extension EnvironmentValues {
    /// The conversation's media loader, used by media part views to fetch
    /// `.serverFile` artifacts from the host. `nil` ⇒ no remote fetch available
    /// (e.g. a preview); such parts render an "unavailable" placeholder.
    var mediaLoader: MediaLoader? {
        get { self[MediaLoaderKey.self] }
        set { self[MediaLoaderKey.self] = newValue }
    }
}
