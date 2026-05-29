import Foundation
import SwiftUI

/// Loads media artifacts that live on a (possibly remote) host, caching each so
/// the UI fetches it once. Thumbnails/posters stay in memory; full files are
/// written to a temp file and reused for AVPlayer / QuickLook. Backed by the
/// driver's `fetchMedia`. One instance per conversation, injected via the
/// `\.mediaLoader` environment value.
@MainActor
final class MediaLoader {
    private let thumbFetch: @Sendable (_ path: String, _ maxDimension: Int) async -> (data: Data, mimeType: String)?
    private let fileFetch: @Sendable (_ path: String) async -> (url: URL, mimeType: String)?

    private var thumbs: [String: Data] = [:]                 // "path|dim" → jpeg bytes
    private var files: [String: URL] = [:]                   // path → file url
    private var inFlightThumb: [String: Task<Data?, Never>] = [:]
    private var inFlightFile: [String: Task<URL?, Never>] = [:]

    init(thumbnail: @escaping @Sendable (_ path: String, _ maxDimension: Int) async -> (data: Data, mimeType: String)?,
         file: @escaping @Sendable (_ path: String) async -> (url: URL, mimeType: String)?) {
        self.thumbFetch = thumbnail
        self.fileFetch = file
    }

    /// A downscaled thumbnail / video poster (JPEG bytes), cached in memory.
    /// Concurrent requests for the same key share one fetch.
    func thumbnail(path: String, maxDimension: Int) async -> Data? {
        let key = "\(path)|\(maxDimension)"
        if let d = thumbs[key] { return d }
        if let t = inFlightThumb[key] { return await t.value }
        let fetch = thumbFetch
        let task = Task { await fetch(path, maxDimension)?.data }
        inFlightThumb[key] = task
        let data = await task.value
        inFlightThumb[key] = nil
        if let data { thumbs[key] = data }
        return data
    }

    /// The full file as a local URL (for AVPlayer / QuickLook). The driver
    /// streams it to disk; we just cache the resulting URL. Concurrent requests
    /// for the same path share one fetch.
    func fullFileURL(path: String) async -> URL? {
        if let u = files[path], FileManager.default.fileExists(atPath: u.path) { return u }
        if let t = inFlightFile[path] { return await t.value }
        let fetch = fileFetch
        let task = Task { await fetch(path)?.url }
        inFlightFile[path] = task
        let url = await task.value
        inFlightFile[path] = nil
        if let url { files[path] = url }
        return url
    }

    /// Full file bytes (reads the cached file). Handy for image fullscreen /
    /// share where a `UIImage`/`NSImage` is wanted rather than a URL. Images are
    /// small enough to hold in memory; large media should use `fullFileURL`.
    func full(path: String) async -> Data? {
        guard let url = await fullFileURL(path: path) else { return nil }
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
