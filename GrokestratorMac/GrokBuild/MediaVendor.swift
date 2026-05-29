import Foundation
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import GrokestratorCore

/// Serves grok-generated media artifacts to remote clients. The transcript only
/// carries the Mac-local file path; a remote iPad/Mac can't read it, so it asks
/// the host (via `GrokBuildRequest.fetchMedia`) for either a small thumbnail
/// (instant inline display) or the full bytes (tap to play / preview).
///
/// All work is nonisolated + async so the server actor isn't blocked while a
/// large file is read or a poster frame is rendered.
enum MediaVendor {
    /// Sanity cap on a full fetch — generous now that bytes stream in chunks
    /// rather than one giant message.
    static let maxFullBytes = 1_024 * 1024 * 1024   // 1 GB
    /// Per-chunk size for streamed full transfers. Kept small so a slow link
    /// (e.g. a remote iPad over the internet) still shows steady per-chunk
    /// progress — the client's inactivity watchdog sees frequent arrivals and
    /// won't false-fail a working-but-slow transfer.
    static let chunkSize = 64 * 1024                // 64 KB

    /// In-process fetch (used by the local driver — no wire, no chunking).
    /// `(data, mimeType)` for a media file, or `nil` if missing / over the cap /
    /// not thumbnailable. `maxDimension != nil` ⇒ downscaled thumbnail / poster.
    static func load(path: String, maxDimension: Int?) async -> (data: Data, mime: String)? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        if let maxDimension {
            return await renderThumbnail(for: url, maxDimension: maxDimension)
        }

        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
              size <= maxFullBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return (data, mimeType(for: url))
    }

    /// Thumbnail/poster as a single small JPEG (for the server's thumbnail path).
    static func thumbnail(path: String, maxDimension: Int) async -> (data: Data, mime: String)? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return await renderThumbnail(for: url, maxDimension: maxDimension)
    }

    /// Streams a full file to `send` in `chunkSize` slices read straight from
    /// disk — so a large video is never held wholly in memory server-side and
    /// each wire frame stays small. Sends a single `nil` if missing / over the
    /// cap. The last slice carries `isFinal == true`; an empty file yields one
    /// empty final chunk.
    static func streamFull(path: String, send: (MediaChunk?) async -> Void) async {
        let url = URL(fileURLWithPath: path)
        let exists = FileManager.default.fileExists(atPath: url.path)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
        guard exists, let size, size <= maxFullBytes, let handle = try? FileHandle(forReadingFrom: url) else {
            await send(nil); return
        }
        defer { try? handle.close() }

        let mime = mimeType(for: url)
        if size == 0 {
            await send(MediaChunk(sequence: 0, isFinal: true, mimeType: mime, data: Data()))
            return
        }
        var offset = 0, seq = 0
        while offset < size {
            if Task.isCancelled { return }
            let len = min(chunkSize, size - offset)
            guard let data = try? handle.read(upToCount: len), !data.isEmpty else {
                await send(MediaChunk(sequence: seq, isFinal: true, mimeType: mime, data: Data()))
                return
            }
            offset += data.count
            await send(MediaChunk(sequence: seq, isFinal: offset >= size, mimeType: mime, data: data))
            seq += 1
        }
    }

    // MARK: - Thumbnails

    private static func renderThumbnail(for url: URL, maxDimension: Int) async -> (data: Data, mime: String)? {
        let ext = url.pathExtension.lowercased()
        if videoExts.contains(ext) { return await videoPoster(url: url, maxDimension: maxDimension) }
        if imageExts.contains(ext) { return imageThumbnail(url: url, maxDimension: maxDimension) }
        return nil   // pdf/other: no thumbnail — the client shows a file icon
    }

    private static func imageThumbnail(url: URL, maxDimension: Int) -> (data: Data, mime: String)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return jpeg(from: cg)
    }

    private static func videoPoster(url: URL, maxDimension: Int) async -> (data: Data, mime: String)? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        // ~1s in (or the start for very short clips) tends to be representative.
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        guard let cg = try? await gen.image(at: time).image else {
            // Retry at t=0 for clips shorter than 1s.
            guard let cg0 = try? await gen.image(at: .zero).image else { return nil }
            return jpeg(from: cg0)
        }
        return jpeg(from: cg)
    }

    private static func jpeg(from cg: CGImage) -> (data: Data, mime: String)? {
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return nil }
        return (data, "image/jpeg")
    }

    // MARK: - Helpers

    private static func mimeType(for url: URL) -> String {
        if let ut = UTType(filenameExtension: url.pathExtension), let mime = ut.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]
    private static let videoExts: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv"]
}
