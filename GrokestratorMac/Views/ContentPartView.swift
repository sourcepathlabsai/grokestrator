import SwiftUI
import AppKit

/// Renders an assistant message that contains a mix of text and inline media.
struct AssistantContentView: View {
    let parts: [ContentPart]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(parts.indices, id: \.self) { i in
                part(parts[i])
            }
        }
    }

    @ViewBuilder
    private func part(_ part: ContentPart) -> some View {
        switch part {
        case .text(let text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(text).textSelection(.enabled)
            }
        case .image(let source, let mimeType):
            ImagePartView(source: source, mimeType: mimeType)
        }
    }
}

/// A clickable image **thumbnail** (opens full-size in Preview) with a download button.
struct ImagePartView: View {
    let source: MediaSource
    let mimeType: String

    private let thumbSize: CGFloat = 140

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                MediaOpener.open(source, mimeType: mimeType)
            } label: {
                thumbnail
                    .frame(width: thumbSize, height: thumbSize)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            }
            .buttonStyle(.plain)
            .help("Open in Preview")

            Button {
                MediaDownloader.save(source, mimeType: mimeType)
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .help("Download")
        }
    }

    /// A square, filled thumbnail (aspect-fill so it reads as a tile).
    @ViewBuilder
    private var thumbnail: some View {
        switch source {
        case .inline(let data):
            if let img = NSImage(data: data) { fill(Image(nsImage: img)) } else { unavailable }
        case .localFile(let url):
            if let img = NSImage(contentsOf: url) { fill(Image(nsImage: img)) } else { unavailable }
        case .remote(let url):
            AsyncImage(url: url) { phase in
                if let img = phase.image { fill(img) }
                else if phase.error != nil { unavailable }
                else { ProgressView() }
            }
        }
    }

    private func fill(_ image: Image) -> some View {
        image.resizable().aspectRatio(contentMode: .fill)
    }

    private var unavailable: some View {
        Image(systemName: "photo")
            .font(.title)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary)
    }
}

// MARK: - Open / Download

/// Opens a media source full-size in the default app (Preview for images).
@MainActor
enum MediaOpener {
    static func open(_ source: MediaSource, mimeType: String) {
        switch source {
        case .localFile(let url):
            NSWorkspace.shared.open(url)
        case .inline(let data):
            openTemp(data, mimeType: mimeType)
        case .remote(let url):
            Task {
                if let data = try? await URLSession.shared.data(from: url).0 {
                    openTemp(data, mimeType: mimeType)
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private static func openTemp(_ data: Data, mimeType: String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grokestrator-\(UUID().uuidString).\(mediaFileExtension(for: mimeType))")
        do {
            try data.write(to: url)
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
        }
    }
}

/// Saves a media source to a user-chosen location via NSSavePanel.
@MainActor
enum MediaDownloader {
    static func save(_ source: MediaSource, mimeType: String) {
        switch source {
        case .inline(let data):
            present(data, mimeType: mimeType)
        case .localFile(let url):
            present(try? Data(contentsOf: url), mimeType: mimeType, suggestedName: url.lastPathComponent)
        case .remote(let url):
            Task {
                let data = try? await URLSession.shared.data(from: url).0
                present(data, mimeType: mimeType, suggestedName: url.lastPathComponent)
            }
        }
    }

    private static func present(_ data: Data?, mimeType: String, suggestedName: String? = nil) {
        guard let data else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName ?? "image.\(mediaFileExtension(for: mimeType))"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }
}

/// File extension for a media mime type (shared by open + download).
func mediaFileExtension(for mimeType: String) -> String {
    switch mimeType {
    case "image/jpeg": return "jpg"
    case "image/gif": return "gif"
    case "image/webp": return "webp"
    case "image/svg+xml": return "svg"
    case "image/heic": return "heic"
    default: return "png"
    }
}
