import Foundation

/// Reads line-delimited JSON ACP messages from a raw stdout `AsyncStream<Data>`
/// and produces a stream of decoded `ACPMessage` values.
///
/// This handles buffering for partial reads, which is common when reading
/// from process pipes.
public actor ACPMessageReader {
    private let dataStream: AsyncStream<Data>
    private var buffer = Data()
    private var continuation: AsyncStream<ACPMessage>.Continuation?

    public init(dataStream: AsyncStream<Data>) {
        self.dataStream = dataStream
    }

    /// Returns a stream of parsed ACP messages.
    /// The stream completes when the underlying data stream completes.
    public func messages() -> AsyncStream<ACPMessage> {
        let (stream, cont) = AsyncStream<ACPMessage>.makeStream()
        self.continuation = cont

        Task {
            await self.processIncomingData()
        }

        return stream
    }

    private func processIncomingData() async {
        for await chunk in dataStream {
            buffer.append(chunk)

            // Process all complete lines in the buffer
            while let newlineIndex = buffer.firstIndex(of: 0x0A) { // '\n'
                let line = buffer[..<newlineIndex]
                buffer.removeSubrange(...newlineIndex)

                // Skip empty lines
                if line.isEmpty { continue }

                if let message = parseMessage(from: line) {
                    continuation?.yield(message)
                }
            }
        }

        // Flush any remaining data as a last attempt (best effort)
        if !buffer.isEmpty {
            if let message = parseMessage(from: buffer) {
                continuation?.yield(message)
            }
            buffer.removeAll()
        }

        continuation?.finish()
    }

    private func parseMessage(from data: Data) -> ACPMessage? {
        do {
            let message = try JSONDecoder().decode(ACPMessage.self, from: data)
            return message
        } catch {
            // Log or handle decode errors. For now we drop malformed lines.
            print("ACPMessageReader: Failed to decode line: \(error)")
            return nil
        }
    }
}
