import Foundation

/// Framing + serialization shared by `NetworkGrokestratorTransport` (client) and
/// `GrokestratorListener` (server). Newline-delimited JSON of
/// `GrokestratorMessage` envelopes — the same shape we already speak to grok
/// over stdio, just over a TCP socket. Tailscale handles encryption / auth.
public enum LineFramedJSONCodec {
    /// Encodes a message to a single newline-terminated frame.
    public static func encode(_ message: GrokestratorMessage) throws -> Data {
        let encoder = JSONEncoder()
        // ISO dates for forward-compatible inspection in logs/dumps.
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(message)
        data.append(0x0A)   // newline frame terminator
        return data
    }

    /// Decodes a single newline-terminated frame.
    public static func decode(_ frame: Data) throws -> GrokestratorMessage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GrokestratorMessage.self, from: frame)
    }
}

/// One-shot guard for bridging callback APIs (NWConnection / NWListener state
/// handlers) to a single continuation resume without Swift 6 complaints about
/// captured mutable vars in Sendable closures.
final class OnceGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire(_ work: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !fired else { return }
        fired = true
        work()
    }
}

/// Accumulates incoming bytes from a stream-oriented transport and yields full
/// frames whenever a newline is encountered. Robust to fragmented reads (a
/// single recv can carry partial / multiple frames).
public struct LineFrameBuffer {
    private var buffer = Data()

    public init() {}

    /// Appends bytes; returns any complete frames (newline excluded).
    public mutating func append(_ bytes: Data) -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let frame = buffer.subdata(in: buffer.startIndex..<nl)
            if !frame.isEmpty { frames.append(frame) }
            buffer = buffer.subdata(in: buffer.index(after: nl)..<buffer.endIndex)
        }
        return frames
    }
}
