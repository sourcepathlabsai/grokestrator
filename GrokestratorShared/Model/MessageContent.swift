import Foundation

/// Where a media part's bytes live. The UI resolves a source to displayable /
/// playable / downloadable bytes; it doesn't care which case it is.
public enum MediaSource: Sendable {
    case inline(Data)         // base64 carried inline (e.g. a data: URI)
    case localFile(URL)       // a path on this machine
    case remote(URL)          // an http(s) URL
    case serverFile(path: String)  // a path on the *host* — fetch via the driver

    /// A URL usable by AVPlayer / Quick Look. Inline data is written to a temp file.
    /// `.serverFile` returns nil here — it must be fetched first (see `MediaLoader`).
    func resolvedURL(preferredExtension ext: String) -> URL? {
        switch self {
        case .localFile(let url): return url
        case .remote(let url): return url
        case .serverFile: return nil
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

    /// `remote == true` ⇒ media artifacts live on a *host* we can't read locally
    /// (a remote client): emit `.serverFile(path)` sources and skip the local
    /// existence check, so the renderer can fetch them over the wire. `false`
    /// (local host) keeps the original `.localFile` + existence-filter behavior.
    static func parse(_ text: String, remote: Bool = false) -> [ContentPart] {
        var parts: [ContentPart] = []
        var seenMedia = Set<String>()

        // Adds a media part, skipping duplicates (the same file referenced twice —
        // e.g. grok's "session path" + "easy copy").
        func addMedia(_ part: ContentPart) {
            guard let key = mediaKey(part) else { return }
            if seenMedia.insert(key).inserted { parts.append(part) }
        }

        for segment in splitMarkdownMedia(text, remote: remote) {
            guard case .text(let t) = segment else { addMedia(segment); continue }
            // Keep the text; append any bare media paths found in it (artifacts to view/play).
            parts.append(.text(t))
            for path in bareMediaPaths(in: t) {
                let source: MediaSource = remote ? .serverFile(path: path) : .localFile(URL(fileURLWithPath: path))
                if let part = part(forPath: path, source: source, remote: remote) {
                    addMedia(part)
                }
            }
        }
        return parts.isEmpty ? [.text(text)] : parts
    }

    /// True unless `source` is a local file that doesn't exist or is empty.
    /// Drops phantom references (e.g. a `~/copy.mp4` mangled into `/copy.mp4`).
    /// Remote sources can't be checked here — assume present and let the fetch
    /// decide (a missing host file just renders as "unavailable").
    private static func renderable(_ source: MediaSource, remote: Bool) -> Bool {
        if remote { return true }
        guard case .localFile(let url) = source else { return true }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        return (size ?? 0) > 0
    }

    /// Stable identity for de-duplicating media parts.
    private static func mediaKey(_ part: ContentPart) -> String? {
        let source: MediaSource
        switch part {
        case .text: return nil
        case let .image(s, _): source = s
        case let .audio(s, _, _): source = s
        case let .video(s, _, _): source = s
        case let .file(s, _, _): source = s
        }
        switch source {
        case .localFile(let u): return "f:" + u.standardizedFileURL.path
        case .remote(let u): return "r:" + u.absoluteString
        case .serverFile(let p): return "s:" + p
        case .inline(let d): return "i:\(d.count)"
        }
    }

    /// Splices classifiable markdown media (`![](src)` images and `[label](src)`
    /// media/file links) inline; unclassifiable matches stay as text.
    private static func splitMarkdownMedia(_ text: String, remote: Bool) -> [ContentPart] {
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
            let part: ContentPart? = isImage ? imagePart(from: src, remote: remote) : linkPart(from: src, label: label, remote: remote)
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

    private static func imagePart(from src: String, remote: Bool) -> ContentPart? {
        if src.hasPrefix("data:") {
            guard let comma = src.firstIndex(of: ","),
                  case let header = String(src[src.index(src.startIndex, offsetBy: 5)..<comma]),
                  header.hasPrefix("image/"), header.contains("base64"),
                  let data = Data(base64Encoded: String(src[src.index(after: comma)...]).trimmingCharacters(in: .whitespacesAndNewlines))
            else { return nil }
            return .image(.inline(data), mimeType: header.split(separator: ";").first.map(String.init) ?? "image/png")
        }
        guard category(forPath: src)?.0 == .image, let source = mediaSource(from: src, remote: remote), renderable(source, remote: remote) else { return nil }
        return .image(source, mimeType: category(forPath: src)!.1)
    }

    private static func linkPart(from src: String, label: String, remote: Bool) -> ContentPart? {
        guard let source = mediaSource(from: src, remote: remote) else { return nil }
        let name = label.isEmpty ? (src as NSString).lastPathComponent : label
        return part(forPath: src, source: source, name: name, remote: remote)
    }

    private static func part(forPath path: String, source: MediaSource, name: String? = nil, remote: Bool) -> ContentPart? {
        guard let (category, mime) = category(forPath: path), renderable(source, remote: remote) else { return nil }
        let display = name ?? (path as NSString).lastPathComponent
        switch category {
        case .image: return .image(source, mimeType: mime)
        case .audio: return .audio(source, mimeType: mime, name: display)
        case .video: return .video(source, mimeType: mime, name: display)
        case .file: return .file(source, mimeType: mime, name: display)
        }
    }

    /// http(s) → `.remote`. A host path → `.serverFile` when `remote` (fetch via
    /// the driver) or `.localFile` otherwise (readable directly).
    private static func mediaSource(from src: String, remote: Bool) -> MediaSource? {
        if src.hasPrefix("http://") || src.hasPrefix("https://"), let url = URL(string: src) { return .remote(url) }
        if src.hasPrefix("file://"), let url = URL(string: src) {
            return remote ? .serverFile(path: url.path) : .localFile(url)
        }
        if src.hasPrefix("/") {
            return remote ? .serverFile(path: src) : .localFile(URL(fileURLWithPath: src))
        }
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
