import Foundation

/// Where a media part's bytes live. The UI resolves a source to displayable /
/// downloadable bytes; it doesn't care which case it is.
public enum MediaSource: Sendable {
    case inline(Data)        // base64 carried inline (e.g. a data: URI)
    case localFile(URL)      // a path on this machine
    case remote(URL)         // an http(s) URL
}

/// One piece of an assistant message. (Slice 1 handles text + image; audio /
/// video / file / link arrive in later slices per design/08.)
public enum ContentPart: Sendable {
    case text(String)
    case image(MediaSource, mimeType: String)
}

/// Extracts inline content parts from assistant text.
///
/// Two sources, both verified against grok-build:
///  1. Markdown image syntax `![alt](src)` — data URI / path / file:// / http(s)
///     (e.g. when asked to embed a data-URI image). These are *spliced* inline.
///  2. **Bare absolute image-file paths** in the prose — how grok surfaces a
///     *generated* image: it saves a local `.jpg` and writes the path (often in a
///     `` `code span` ``) like `/Users/…/images/1.jpg`. We keep the text and
///     *append* the rendered image after it.
///
/// Anything not confidently an image is left as text.
enum ContentParser {
    static func parse(_ markdown: String) -> [ContentPart] {
        var parts: [ContentPart] = []
        for segment in splitMarkdownImages(markdown) {
            guard case .text(let text) = segment else { parts.append(segment); continue }
            parts.append(.text(text))
            for path in bareImagePaths(in: text) {
                parts.append(.image(.localFile(URL(fileURLWithPath: path)), mimeType: imageMime(forPath: path) ?? "image/png"))
            }
        }
        return parts.isEmpty ? [.text(markdown)] : parts
    }

    /// Splits on `![alt](src)` markdown images, splicing image parts inline.
    private static func splitMarkdownImages(_ markdown: String) -> [ContentPart] {
        let pattern = #"!\[[^\]]*\]\(([^)\s]+)\)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [.text(markdown)] }
        let ns = markdown as NSString
        let matches = re.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [.text(markdown)] }

        var parts: [ContentPart] = []
        var cursor = 0
        for m in matches {
            guard let imagePart = imagePart(from: ns.substring(with: m.range(at: 1))) else { continue }
            if m.range.location > cursor {
                parts.append(.text(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))))
            }
            parts.append(imagePart)
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { parts.append(.text(ns.substring(from: cursor))) }
        return parts
    }

    /// Finds absolute paths to image files in free text (deduped, in order).
    private static func bareImagePaths(in text: String) -> [String] {
        let pattern = #"/[^\s`)\]]+\.(?:png|jpe?g|gif|webp|heic)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        var seen = Set<String>(); var paths: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let path = ns.substring(with: m.range)
            if !seen.contains(path) { seen.insert(path); paths.append(path) }
        }
        return paths
    }

    /// Returns an `.image` part only when `src` is confidently an image.
    private static func imagePart(from src: String) -> ContentPart? {
        if src.hasPrefix("data:") {
            guard let comma = src.firstIndex(of: ","),
                  case let header = String(src[src.index(src.startIndex, offsetBy: 5)..<comma]),
                  header.hasPrefix("image/"),
                  header.contains("base64"),
                  let data = Data(base64Encoded: String(src[src.index(after: comma)...]).trimmingCharacters(in: .whitespacesAndNewlines))
            else { return nil }
            let mime = header.split(separator: ";").first.map(String.init) ?? "image/png"
            return .image(.inline(data), mimeType: mime)
        }
        guard let mime = imageMime(forPath: src) else { return nil }
        if src.hasPrefix("http://") || src.hasPrefix("https://"), let url = URL(string: src) {
            return .image(.remote(url), mimeType: mime)
        }
        if src.hasPrefix("file://"), let url = URL(string: src) {
            return .image(.localFile(url), mimeType: mime)
        }
        if src.hasPrefix("/") {
            return .image(.localFile(URL(fileURLWithPath: src)), mimeType: mime)
        }
        return nil
    }

    /// Image mime for a path/URL, or nil if the extension isn't a known image type.
    private static func imageMime(forPath path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "heic": return "image/heic"
        default: return nil
        }
    }
}
