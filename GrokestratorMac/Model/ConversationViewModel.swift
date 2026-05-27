import Foundation
import Observation
import GrokestratorCore

/// One renderable line in the conversation transcript.
struct TranscriptEntry: Identifiable, Sendable {
    let id = UUID()
    let kind: Kind

    enum Kind: Sendable {
        /// Something the user sent.
        case userPrompt(String)
        /// An update streamed back from the agent (or mock).
        case update(ConversationUpdate)
    }
}

/// MainActor-facing state for a single conversation.
///
/// This is the bridge between the actor-based, `AsyncStream<ConversationUpdate>`
/// world (the black box / mock driver) and SwiftUI: it consumes the stream and
/// publishes an observable transcript that views render directly.
@MainActor
@Observable
final class ConversationViewModel {
    private(set) var entries: [TranscriptEntry] = []
    private(set) var isStreaming = false

    private let driver: ConversationDriver
    private var streamingTask: Task<Void, Never>?

    init(driver: ConversationDriver) {
        self.driver = driver
    }

    /// Sends a prompt and streams the response into `entries`.
    func send(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        entries.append(TranscriptEntry(kind: .userPrompt(trimmed)))
        isStreaming = true

        let driver = self.driver
        streamingTask = Task { [weak self] in
            do {
                let stream = try await driver.send(trimmed)
                for await update in stream {
                    // Task inherits the MainActor context, so this is a safe hop-back.
                    self?.append(update)
                }
            } catch {
                self?.append(.error(error.localizedDescription))
            }
            self?.isStreaming = false
        }
    }

    /// Appends a system-level note (e.g. launch status or errors) to the transcript.
    func appendSystem(_ text: String, isError: Bool = false) {
        let update: ConversationUpdate = isError ? .error(text) : .sessionStatus(text)
        entries.append(TranscriptEntry(kind: .update(update)))
    }

    /// Cancels any in-flight turn (e.g. when the view goes away).
    func cancel() {
        streamingTask?.cancel()
        streamingTask = nil
        isStreaming = false
    }

    private func append(_ update: ConversationUpdate) {
        entries.append(TranscriptEntry(kind: .update(update)))
        if case .turnComplete = update {
            isStreaming = false
        }
    }
}
