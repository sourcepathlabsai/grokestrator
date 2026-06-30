import SwiftUI
import UIKit
import AVKit
import QuickLook
import GrokestratorCore

/// iOS counterpart to the Mac `AssistantContentView` — interleaves text with
/// inline media renderers (image / audio / video / file). Used in
/// `iOSConversationView` to render `.assistantContent(parts)` entries.
///
/// Tap any media part to open a full-screen preview / native player. Each
/// media kind uses the iOS-native viewer: inline UIImage for images,
/// `AVPlayerViewController` for video/audio, `QLPreviewController` for files.
struct iOSAssistantContentView: View {
    let parts: [ContentPart]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                renderer(for: part)
            }
        }
    }

    @ViewBuilder
    private func renderer(for part: ContentPart) -> some View {
        switch part {
        case .text(let text):
            SelectableMarkdownText(text, baseSize: 15)
        case .image(let source, let mimeType):
            if case .serverFile(let path) = source {
                iOSRemoteImagePartView(path: path, mimeType: mimeType)
            } else {
                iOSImagePartView(source: source, mimeType: mimeType)
            }
        case .audio(let source, let mimeType, let name):
            if case .serverFile(let path) = source {
                iOSRemoteMediaCard(path: path, mimeType: mimeType, name: name, kind: .audio)
            } else {
                iOSAudioPartView(source: source, mimeType: mimeType, name: name)
            }
        case .video(let source, let mimeType, let name):
            if case .serverFile(let path) = source {
                iOSRemoteVideoPartView(path: path, mimeType: mimeType, name: name)
            } else {
                iOSVideoPartView(source: source, mimeType: mimeType, name: name)
            }
        case .file(let source, let mimeType, let name):
            if case .serverFile(let path) = source {
                iOSRemoteMediaCard(path: path, mimeType: mimeType, name: name, kind: .file)
            } else {
                iOSFilePartView(source: source, mimeType: mimeType, name: name)
            }
        }
    }
}

// MARK: - Image

/// Inline image (aspect-fit, capped at ~260pt tall so chat stays readable).
/// Tap → full-screen viewer with pinch-zoom + share button.
struct iOSImagePartView: View {
    let source: MediaSource
    let mimeType: String
    @State private var showFullScreen = false

    private let maxHeight: CGFloat = 260

    var body: some View {
        Group {
            if let image = loadedImage {
                Button { showFullScreen = true } label: {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: maxHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                }
                .buttonStyle(.plain)
            } else {
                placeholder
            }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            iOSImageFullscreenView(image: loadedImage, source: source, mimeType: mimeType)
        }
    }

    /// Loads from inline data or local file synchronously. Remote URLs would
    /// need AsyncImage (`.remote`); not used by grok-build today.
    private var loadedImage: UIImage? {
        switch source {
        case .inline(let data): return UIImage(data: data)
        case .localFile(let url): return UIImage(contentsOfFile: url.path)
        case .remote: return nil   // remote-image rendering: see fullScreenCover
        case .serverFile: return nil   // handled by iOSRemoteImagePartView
        }
    }

    private var placeholder: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo").foregroundStyle(Theme.textFaint)
            Text("Image unavailable").font(Theme.body(11)).foregroundStyle(Theme.textFaint)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Full-screen image viewer with pinch / pan / double-tap zoom and a Share
/// button. Backed by a UIScrollView wrapping a UIImageView — the standard
/// iOS recipe; SwiftUI alone can't do natural pinch-to-zoom on an image yet.
private struct iOSImageFullscreenView: View {
    let image: UIImage?
    let source: MediaSource
    let mimeType: String
    @Environment(\.dismiss) private var dismiss
    @State private var shareItems: [Any] = []
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    ZoomableImageView(image: image)
                        .background(Color.black)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    Color.black
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { share() } label: { Image(systemName: "square.and.arrow.up") }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .sheet(isPresented: $showShare) {
            iOSActivityView(items: shareItems)
        }
    }

    private func share() {
        let ext = mediaFileExtension(for: mimeType)
        guard let url = source.resolvedURL(preferredExtension: ext) else { return }
        shareItems = [url]
        showShare = true
    }
}

/// Pinch / pan / double-tap-to-zoom image — UIScrollView under the hood
/// since SwiftUI's native gestures don't cover this case naturally yet.
private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.delegate = context.coordinator
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = .black

        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(iv)
        context.coordinator.imageView = iv

        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            iv.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            iv.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            iv.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            iv.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_: UIScrollView, context _: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        func viewForZooming(in _: UIScrollView) -> UIView? { imageView }

        @objc func toggleZoom(_ gr: UITapGestureRecognizer) {
            guard let scroll = gr.view as? UIScrollView else { return }
            let target: CGFloat = scroll.zoomScale > 1 ? 1 : 3
            scroll.setZoomScale(target, animated: true)
        }
    }
}

// MARK: - Audio

/// Minimal audio player: a play/pause button + the file's display name.
/// Uses a single AVPlayer per view; no scrubber for v1.
struct iOSAudioPartView: View {
    let source: MediaSource
    let mimeType: String
    let name: String

    @State private var player: AVPlayer?
    @State private var isPlaying = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(Theme.body(13, .medium)).foregroundStyle(Theme.textBody).lineLimit(1)
                Text("Audio").font(Theme.body(11)).foregroundStyle(Theme.textFaint)
            }
            Spacer()
        }
        .padding(10)
        .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }

    private func toggle() {
        if player == nil {
            let ext = mediaFileExtension(for: mimeType)
            guard let url = source.resolvedURL(preferredExtension: ext) else { return }
            player = AVPlayer(url: url)
        }
        if isPlaying { player?.pause() } else { player?.play() }
        isPlaying.toggle()
    }
}

// MARK: - Video

/// Inline video — full `AVPlayerViewController` so iOS users get the standard
/// controls (scrubber, fullscreen, AirPlay, picture-in-picture).
struct iOSVideoPartView: View {
    let source: MediaSource
    let mimeType: String
    let name: String

    var body: some View {
        Group {
            if let url = playableURL {
                VideoPlayerWrapper(url: url)
                    .aspectRatio(16/9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "video.slash").foregroundStyle(Theme.textFaint)
                    Text(name).font(Theme.body(11)).foregroundStyle(Theme.textFaint)
                }
                .padding(10)
                .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var playableURL: URL? {
        source.resolvedURL(preferredExtension: mediaFileExtension(for: mimeType))
    }
}

private struct VideoPlayerWrapper: UIViewControllerRepresentable {
    let url: URL
    /// Auto-play on present (fullscreen remote video). Inline previews can leave
    /// it false so they don't start playing unbidden.
    var autoplay: Bool = false
    func makeUIViewController(context _: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        let player = AVPlayer(url: url)
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        if autoplay {
            // Make sure audio plays even if the device is on silent.
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
        }
        return vc
    }
    func updateUIViewController(_: AVPlayerViewController, context _: Context) {}
}

// MARK: - File (PDF / docs / arbitrary)

/// File card — icon + name + size. Tap → QuickLook preview (handles PDF,
/// most office docs, plain text, images, audio, video natively).
struct iOSFilePartView: View {
    let source: MediaSource
    let mimeType: String
    let name: String

    @State private var previewURL: URL?

    var body: some View {
        Button(action: openPreview) {
            HStack(spacing: 10) {
                Image(systemName: icon(for: mimeType))
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(Theme.body(13, .medium)).foregroundStyle(Theme.textBody).lineLimit(1)
                    Text(mimeType).font(Theme.body(10)).foregroundStyle(Theme.textFaint)
                }
                Spacer()
                Image(systemName: "eye").font(.caption).foregroundStyle(Theme.textFaint)
            }
            .padding(10)
            .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: Binding(get: { previewURL != nil },
                                    set: { if !$0 { previewURL = nil } })) {
            if let url = previewURL {
                QuickLookPreview(url: url)
            }
        }
    }

    private func openPreview() {
        previewURL = source.resolvedURL(preferredExtension: mediaFileExtension(for: mimeType))
    }

    private func icon(for mime: String) -> String {
        switch mime {
        case "application/pdf": return "doc.richtext"
        case "text/csv": return "tablecells"
        case "application/json": return "curlybraces"
        case "application/zip": return "archivebox"
        case "text/plain": return "doc.plaintext"
        default: return "doc"
        }
    }
}

/// `QLPreviewController` wrapper. Pass a local file URL — QuickLook decides
/// how to render based on UTI (PDFs paginate, images zoom, video plays, …).
private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let vc = QLPreviewController()
        vc.dataSource = context.coordinator
        return vc
    }

    func updateUIViewController(_: QLPreviewController, context _: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url; super.init() }
        func numberOfPreviewItems(in _: QLPreviewController) -> Int { 1 }
        func previewController(_: QLPreviewController, previewItemAt _: Int) -> QLPreviewItem {
            url as QLPreviewItem
        }
    }
}

// MARK: - Share

/// `UIActivityViewController` wrapper for the iOS share sheet (used by the
/// fullscreen image viewer's share button).
private struct iOSActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}

// MARK: - Remote media (`.serverFile`) — fetched from the host via MediaLoader

/// Remote image: shows a downscaled thumbnail immediately, tap loads the full
/// image and opens the zoomable fullscreen viewer.
struct iOSRemoteImagePartView: View {
    let path: String
    let mimeType: String
    @Environment(\.mediaLoader) private var loader
    @State private var thumb: UIImage?
    @State private var fullData: Data?
    @State private var showFull = false
    @State private var state: LoadState = .loading

    private let maxHeight: CGFloat = 260

    var body: some View {
        Group {
            if let thumb {
                Button { Task { await loadFull() } } label: {
                    Image(uiImage: thumb)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: maxHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                }
                .buttonStyle(.plain)
            } else if state == .failed {
                iOSMediaPlaceholder(icon: "photo", text: "Image unavailable")
            } else {
                iOSMediaPlaceholder(icon: "photo", text: "Loading image…", spinner: true)
            }
        }
        .task { await loadThumb() }
        .fullScreenCover(isPresented: $showFull) {
            iOSImageFullscreenView(image: fullData.flatMap(UIImage.init) ?? thumb,
                                   source: .inline(fullData ?? Data()), mimeType: mimeType)
        }
    }

    private func loadThumb() async {
        guard thumb == nil else { return }
        guard let loader else { state = .failed; return }
        if let data = await loader.thumbnail(path: path, maxDimension: 800), let img = UIImage(data: data) {
            thumb = img; state = .loaded
        } else { state = .failed }
    }

    private func loadFull() async {
        if fullData == nil, let loader {
            fullData = await loader.full(path: path)
        }
        showFull = true
    }
}

/// Remote video: shows a poster frame immediately, tap fetches the full file
/// and plays it fullscreen.
private struct VideoItem: Identifiable { let id = UUID(); let url: URL }

struct iOSRemoteVideoPartView: View {
    let path: String
    let mimeType: String
    let name: String
    @Environment(\.mediaLoader) private var loader
    @State private var poster: UIImage?
    @State private var playItem: VideoItem?
    @State private var failed = false

    var body: some View {
        Button { play() } label: {
            ZStack {
                if let poster {
                    Image(uiImage: poster).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(Theme.surfaceSoft).aspectRatio(16.0/9.0, contentMode: .fit)
                }
                Image(systemName: failed ? "exclamationmark.triangle.fill" : "play.circle.fill")
                    .font(.system(size: 46)).foregroundStyle(.white).shadow(radius: 8)
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        }
        .buttonStyle(.plain)
        .task { await loadPoster() }
        // Item-driven so the player presents reliably (no isPresented/if-let race).
        .fullScreenCover(item: $playItem) { item in iOSVideoFullscreen(url: item.url) }
    }

    private func loadPoster() async {
        guard poster == nil, let loader else { return }
        if let data = await loader.thumbnail(path: path, maxDimension: 800) { poster = UIImage(data: data) }
    }

    private func play() {
        // Stream over HTTP: hand AVPlayer the host's media-server URL and let it
        // buffer/seek natively. No chunked transfer (which deadlocked + stalled).
        guard let url = loader?.streamURL(path: path) else { failed = true; return }
        failed = false
        playItem = VideoItem(url: url)
    }
}

/// Remote audio/file card: tap fetches the full file and previews it via
/// QuickLook (which natively handles PDFs, audio, docs, …).
struct iOSRemoteMediaCard: View {
    enum Kind { case audio, file }
    let path: String
    let mimeType: String
    let name: String
    let kind: Kind
    @Environment(\.mediaLoader) private var loader
    @State private var url: URL?
    @State private var loading = false
    @State private var showPreview = false

    var body: some View {
        Button { Task { await activate() } } label: {
            HStack(spacing: 10) {
                Image(systemName: loading ? "arrow.down.circle" : (kind == .audio ? "waveform" : "doc"))
                    .font(.title3).foregroundStyle(Theme.accent).frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(Theme.body(13, .medium)).foregroundStyle(Theme.textBody).lineLimit(1)
                    Text(loading ? "Fetching…" : "Tap to open").font(Theme.body(10)).foregroundStyle(Theme.textFaint)
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                else { Image(systemName: "eye").font(.caption).foregroundStyle(Theme.textFaint) }
            }
            .padding(10)
            .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPreview) { if let url { QuickLookPreview(url: url) } }
    }

    private func activate() async {
        guard !loading, let loader else { return }
        if url == nil {
            loading = true
            url = await loader.fullFileURL(path: path)
            loading = false
        }
        if url != nil { showPreview = true }
    }
}

private enum LoadState: Equatable { case loading, loaded, failed }

/// Fullscreen video player with a Done button (used by remote video).
private struct iOSVideoFullscreen: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            VideoPlayerWrapper(url: url, autoplay: true).ignoresSafeArea()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white.opacity(0.85))
            }
            .padding()
        }
    }
}

/// Small inline placeholder card for loading / unavailable remote media.
private struct iOSMediaPlaceholder: View {
    let icon: String
    let text: String
    var spinner: Bool = false
    var body: some View {
        HStack(spacing: 8) {
            if spinner { ProgressView().controlSize(.small) }
            else { Image(systemName: icon).foregroundStyle(Theme.textFaint) }
            Text(text).font(Theme.body(11)).foregroundStyle(Theme.textFaint)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Helpers

/// File-extension hint for a given MIME — used by `MediaSource.resolvedURL`
/// when it has to write inline data to a temp file for QuickLook / AVPlayer.
/// Mirrors the Mac `mediaFileExtension(for:)` so behavior is consistent.
@MainActor
func mediaFileExtension(for mimeType: String) -> String {
    switch mimeType {
    case "image/png": return "png"
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
    case "application/json": return "json"
    case "text/plain": return "txt"
    case "application/zip": return "zip"
    default: return "bin"
    }
}
