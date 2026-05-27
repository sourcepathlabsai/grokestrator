import SwiftUI
import AppKit

/// Renders an assistant message that contains a mix of text and inline images.
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

/// An inline image with a download button.
struct ImagePartView: View {
    let source: MediaSource
    let mimeType: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            image
                .frame(maxWidth: 360, maxHeight: 360, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Button {
                MediaDownloader.save(source, mimeType: mimeType)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var image: some View {
        switch source {
        case .inline(let data):
            if let img = NSImage(data: data) {
                Image(nsImage: img).resizable().scaledToFit()
            } else { unavailable }
        case .localFile(let url):
            if let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().scaledToFit()
            } else { unavailable }
        case .remote(let url):
            AsyncImage(url: url) { phase in
                if let img = phase.image { img.resizable().scaledToFit() }
                else if phase.error != nil { unavailable }
                else { ProgressView() }
            }
        }
    }

    private var unavailable: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
            Text("Image unavailable").foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
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
        panel.nameFieldStringValue = suggestedName ?? "image.\(fileExtension(for: mimeType))"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    private static func fileExtension(for mimeType: String) -> String {
        switch mimeType {
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/svg+xml": return "svg"
        case "image/heic": return "heic"
        default: return "png"
        }
    }
}
