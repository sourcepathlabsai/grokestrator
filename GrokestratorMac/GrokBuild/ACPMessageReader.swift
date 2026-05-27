import Foundation

/// Splits a raw stdout `AsyncStream<Data>` into newline-delimited JSON lines.
///
/// Grok Build speaks newline-delimited JSON-RPC 2.0, so each line is one complete
/// JSON-RPC object. This actor handles buffering across partial pipe reads and
/// yields one `Data` per JSON line; decoding/routing happens in the session client.
public actor ACPMessageReader {
    private let dataStream: AsyncStream<Data>
    private var buffer = Data()

    public init(dataStream: AsyncStream<Data>) {
        self.dataStream = dataStream
    }

    /// Returns a stream of raw JSON lines (one JSON-RPC object each).
    /// Completes when the underlying data stream completes.
    public func lines() -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)

        Task {
            await self.process(into: continuation)
            continuation.finish()
        }

        return stream
    }

    private func process(into continuation: AsyncStream<Data>.Continuation) async {
        for await chunk in dataStream {
            buffer.append(chunk)

            while let newlineIndex = buffer.firstIndex(of: 0x0A) { // '\n'
                let line = Data(buffer[..<newlineIndex])
                buffer.removeSubrange(...newlineIndex)
                if !line.isEmpty {
                    continuation.yield(line)
                }
            }
        }

        // Flush any trailing partial line (best effort).
        if !buffer.isEmpty {
            continuation.yield(buffer)
            buffer.removeAll()
        }
    }
}
