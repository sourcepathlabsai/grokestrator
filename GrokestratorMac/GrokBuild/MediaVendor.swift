import Foundation
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Serves grok-generated media artifacts to remote clients. The transcript only
/// carries the Mac-local file path; a remote iPad/Mac can't read it, so it asks
/// the host (via `GrokBuildRequest.fetchMedia`) for either a small thumbnail
/// (instant inline display) or the full bytes (tap to play / preview).
///
/// All work is nonisolated + async so the server actor isn't blocked while a
/// large file is read or a poster frame is rendered.
enum MediaVendor {
    /// Hard cap on a full (non-thumbnail) fetch. Bytes cross the wire base64'd in
    /// one JSON message, so an unbounded video would wedge the framing. Large
    /// files simply don't inline today — a follow-up can chunk them.
    static let maxFullBytes = 64 * 1024 * 1024   // 64 MB

    /// Returns `(data, mimeType)` for a media file, or `nil` if missing,
    /// over the size cap, or not thumbnailable. `maxDimension != nil` ⇒ a
    /// downscaled JPEG thumbnail (image) or poster frame (video).
    static func load(path: String, maxDimension: Int?) async -> (data: Data, mime: String)? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        if let maxDimension {
            return await thumbnail(for: url, maxDimension: maxDimension)
        }

        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
              size <= maxFullBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return (data, mimeType(for: url))
    }

    // MARK: - Thumbnails

    private static func thumbnail(for url: URL, maxDimension: Int) async -> (data: Data, mime: String)? {
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
