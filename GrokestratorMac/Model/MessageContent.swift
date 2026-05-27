import Foundation

/// Where a media part's bytes live. The UI resolves a source to displayable /
/// playable / downloadable bytes; it doesn't care which case it is.
public enum MediaSource: Sendable {
    case inline(Data)        // base64 carried inline (e.g. a data: URI)
    case localFile(URL)      // a path on this machine
    case remote(URL)         // an http(s) URL

    /// A URL usable by AVPlayer / Quick Look. Inline data is written to a temp file.
    func resolvedURL(preferredExtension ext: String) -> URL? {
        switch self {
        case .localFile(let url): return url
        case .remote(let url): return url
        case .inline(let data):
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("grokestrator-\(UUID().uuidString).\(ext)")
            return (try? data.write(to: url)) != nil ? url : nil
        }
    }
}

/// One piece of an assistant message. Media parts render inline (image thumbnail,
/// audio/video players, file card) with download — see design/08.
public enum ContentPart: Sendable {
    case text(String)
    case image(MediaSource, mimeType: String)
    case audio(MediaSource, mimeType: String, name: String)
    case video(MediaSource, mimeType: String, name: String)
    case file(MediaSource, mimeType: String, name: String)
}

/// Extracts inline content parts from assistant text. Verified against grok-build:
/// media surfaces as markdown (`![alt](src)` / `[label](src)`) or bare local paths
/// in the prose (grok saves an artifact and writes its path). Classified by
/// extension; anything not confidently media/file is left as text.
enum ContentParser {
    private enum Category { case image, audio, video, file }

    static func parse(_ text: String) -> [ContentPart] {
        var parts: [ContentPart] = []
        for segment in splitMarkdownMedia(text) {
            guard case .text(let t) = segment else { parts.append(segment); continue }
            // Keep the text; append any bare media paths found in it (artifacts to view/play).
            parts.append(.text(t))
            for path in bareMediaPaths(in: t) {
                if let part = part(forPath: path, source: .localFile(URL(fileURLWithPath: path))) {
                    parts.append(part)
                }
            }
        }
        return parts.isEmpty ? [.text(text)] : parts
    }

    /// Splices classifiable markdown media (`![](src)` images and `[label](src)`
    /// media/file links) inline; unclassifiable matches stay as text.
    private static func splitMarkdownMedia(_ text: String) -> [ContentPart] {
        let pattern = #"(!?)\[([^\]]*)\]\(([^)\s]+)\)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [.text(text)] }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [.text(text)] }

        var parts: [ContentPart] = []
        var cursor = 0
        for m in matches {
            let isImage = ns.substring(with: m.range(at: 1)) == "!"
            let label = ns.substring(with: m.range(at: 2))
            let src = ns.substring(with: m.range(at: 3))
            let part: ContentPart? = isImage ? imagePart(from: src) : linkPart(from: src, label: label)
            guard let part else { continue } // not media → leave in text
            if m.range.location > cursor {
                parts.append(.text(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))))
            }
            parts.append(part)
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { parts.append(.text(ns.substring(from: cursor))) }
        return parts
    }

    /// Bare absolute paths to media artifacts (image/audio/video/pdf only — not
    /// arbitrary files, to avoid carding every source path grok mentions).
    private static func bareMediaPaths(in text: String) -> [String] {
        let exts = "png|jpe?g|gif|webp|heic|svg|mp3|wav|m4a|aac|aiff|aif|flac|ogg|mp4|m4v|mov|webm|mkv|pdf"
        guard let re = try? NSRegularExpression(pattern: "/[^\\s`)\\]]+\\.(?:\(exts))", options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        var seen = Set<String>(); var paths: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let p = ns.substring(with: m.range)
            if !seen.contains(p) { seen.insert(p); paths.append(p) }
        }
        return paths
    }

    private static func imagePart(from src: String) -> ContentPart? {
        if src.hasPrefix("data:") {
            guard let comma = src.firstIndex(of: ","),
                  case let header = String(src[src.index(src.startIndex, offsetBy: 5)..<comma]),
                  header.hasPrefix("image/"), header.contains("base64"),
                  let data = Data(base64Encoded: String(src[src.index(after: comma)...]).trimmingCharacters(in: .whitespacesAndNewlines))
            else { return nil }
            return .image(.inline(data), mimeType: header.split(separator: ";").first.map(String.init) ?? "image/png")
        }
        guard category(forPath: src)?.0 == .image, let source = mediaSource(from: src) else { return nil }
        return .image(source, mimeType: category(forPath: src)!.1)
    }

    private static func linkPart(from src: String, label: String) -> ContentPart? {
        guard let source = mediaSource(from: src) else { return nil }
        let name = label.isEmpty ? (src as NSString).lastPathComponent : label
        return part(forPath: src, source: source, name: name)
    }

    private static func part(forPath path: String, source: MediaSource, name: String? = nil) -> ContentPart? {
        guard let (category, mime) = category(forPath: path) else { return nil }
        let display = name ?? (path as NSString).lastPathComponent
        switch category {
        case .image: return .image(source, mimeType: mime)
        case .audio: return .audio(source, mimeType: mime, name: display)
        case .video: return .video(source, mimeType: mime, name: display)
        case .file: return .file(source, mimeType: mime, name: display)
        }
    }

    private static func mediaSource(from src: String) -> MediaSource? {
        if src.hasPrefix("http://") || src.hasPrefix("https://"), let url = URL(string: src) { return .remote(url) }
        if src.hasPrefix("file://"), let url = URL(string: src) { return .localFile(url) }
        if src.hasPrefix("/") { return .localFile(URL(fileURLWithPath: src)) }
        return nil
    }

    private static func category(forPath path: String) -> (Category, String)? {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": return (.image, "image/png")
        case "jpg", "jpeg": return (.image, "image/jpeg")
        case "gif": return (.image, "image/gif")
        case "webp": return (.image, "image/webp")
        case "svg": return (.image, "image/svg+xml")
        case "heic": return (.image, "image/heic")
        case "mp3": return (.audio, "audio/mpeg")
        case "wav": return (.audio, "audio/wav")
        case "m4a", "aac": return (.audio, "audio/mp4")
        case "aiff", "aif": return (.audio, "audio/aiff")
        case "flac": return (.audio, "audio/flac")
        case "ogg": return (.audio, "audio/ogg")
        case "mp4", "m4v": return (.video, "video/mp4")
        case "mov": return (.video, "video/quicktime")
        case "webm": return (.video, "video/webm")
        case "mkv": return (.video, "video/x-matroska")
        case "pdf": return (.file, "application/pdf")
        case "csv": return (.file, "text/csv")
        case "zip": return (.file, "application/zip")
        case "json": return (.file, "application/json")
        case "txt", "md": return (.file, "text/plain")
        default: return nil
        }
    }
}
