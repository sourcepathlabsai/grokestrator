import SwiftUI
import AppKit
import AVKit
import QuickLookThumbnailing

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
        case .audio(let source, let mimeType, let name):
            AudioPlayerView(source: source, mimeType: mimeType, name: name)
        case .video(let source, let mimeType, let name):
            VideoPlayerView(source: source, mimeType: mimeType, name: name)
        case .file(let source, let mimeType, let name):
            FilePartView(source: source, mimeType: mimeType, name: name)
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

// MARK: - Audio / Video / File

/// Compact audio player: play/pause + name + download. (Scrubber is a later refinement.)
struct AudioPlayerView: View {
    let source: MediaSource
    let mimeType: String
    let name: String

    @State private var player: AVPlayer?
    @State private var isPlaying = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.largeTitle)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Label(name, systemImage: "waveform").font(.callout).lineLimit(1)
                Text(mimeType).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                MediaDownloader.save(source, mimeType: mimeType)
            } label: { Image(systemName: "arrow.down.circle") }
                .buttonStyle(.borderless)
                .help("Download")
        }
        .padding(10)
        .frame(maxWidth: 380)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { _ in
            isPlaying = false
            player?.seek(to: .zero)
        }
        .onDisappear { player?.pause() }
    }

    private func toggle() {
        if player == nil {
            player = source.resolvedURL(preferredExtension: mediaFileExtension(for: mimeType)).map { AVPlayer(url: $0) }
        }
        guard let player else { NSSound.beep(); return }
        isPlaying ? player.pause() : player.play()
        isPlaying.toggle()
    }
}

/// AppKit `AVPlayerView` wrapper. We avoid SwiftUI's `VideoPlayer` (the
/// `_AVKit_SwiftUI` overlay) because instantiating its type metadata crashes
/// the Swift runtime (SIGABRT in getSuperclassMetadata) on macOS the moment a
/// video renders. Plain AVKit `AVPlayerView` is stable.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

/// Inline video player (AVKit transport) + download.
struct VideoPlayerView: View {
    let source: MediaSource
    let mimeType: String
    let name: String

    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let player {
                    PlayerView(player: player)
                } else {
                    Image(systemName: "film")
                        .font(.largeTitle).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.quaternary)
                }
            }
            .frame(width: 380, height: 230)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button {
                    MediaDownloader.save(source, mimeType: mimeType)
                } label: { Label("Download", systemImage: "arrow.down.circle") }
                    .buttonStyle(.borderless).controlSize(.small)
            }
            .frame(maxWidth: 380)
        }
        .onAppear {
            if player == nil {
                player = source.resolvedURL(preferredExtension: mediaFileExtension(for: mimeType)).map { AVPlayer(url: $0) }
            }
        }
        .onDisappear { player?.pause() }
    }
}

/// A card for a file: a QuickLook thumbnail (e.g. a PDF's first page) you can
/// click to open in the default app, an "Open with" menu of available apps
/// (Preview / Acrobat / …), and a download button.
struct FilePartView: View {
    let source: MediaSource
    let mimeType: String
    let name: String

    @State private var fileURL: URL?
    @State private var thumbnail: NSImage?
    @State private var openApps: [URL] = []

    var body: some View {
        HStack(spacing: 10) {
            Button { open(with: nil) } label: { thumbnailView }
                .buttonStyle(.plain)
                .help("Open")

            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.callout).lineLimit(1)
                Text(mimeType).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()

            if openApps.count > 1 {
                Menu {
                    ForEach(openApps, id: \.self) { app in
                        Button(appName(app)) { open(with: app) }
                    }
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Open with…")
            } else {
                Button { open(with: nil) } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.borderless).help("Open")
            }

            Button { MediaDownloader.save(source, mimeType: mimeType) } label: { Image(systemName: "arrow.down.circle") }
                .buttonStyle(.borderless).help("Download")
        }
        .padding(10)
        .frame(maxWidth: 380)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .task { await prepare() }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFit()
            } else {
                Image(systemName: icon).font(.title).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 44, height: 56)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
    }

    private func prepare() async {
        guard fileURL == nil,
              let url = source.resolvedURL(preferredExtension: mediaFileExtension(for: mimeType))
        else { return }
        fileURL = url
        var seen = Set<String>()
        openApps = NSWorkspace.shared.urlsForApplications(toOpen: url).filter { seen.insert($0.path).inserted }

        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 88, height: 112), scale: 2, representationTypes: .thumbnail
        )
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            thumbnail = rep.nsImage
        }
    }

    private func open(with app: URL?) {
        guard let url = fileURL ?? source.resolvedURL(preferredExtension: mediaFileExtension(for: mimeType)) else {
            NSSound.beep(); return
        }
        if let app {
            Task { _ = try? await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func appName(_ app: URL) -> String {
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private var icon: String {
        switch mimeType {
        case "application/pdf": return "doc.richtext"
        case "text/csv": return "tablecells"
        case "application/zip": return "doc.zipper"
        case "application/json", "text/plain": return "doc.text"
        default: return "doc"
        }
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
    case "audio/mpeg": return "mp3"
    case "audio/wav": return "wav"
    case "audio/mp4": return "m4a"
    case "audio/aiff": return "aiff"
    case "audio/flac": return "flac"
    case "audio/ogg": return "ogg"
    case "video/mp4": return "mp4"
    case "video/quicktime": return "mov"
    case "video/webm": return "webm"
    case "video/x-matroska": return "mkv"
    case "application/pdf": return "pdf"
    case "text/csv": return "csv"
    case "application/zip": return "zip"
    case "application/json": return "json"
    case "text/plain": return "txt"
    default: return "png"
    }
}
