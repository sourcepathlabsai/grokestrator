import Foundation
import Network
import UniformTypeIdentifiers

/// A tiny HTTP/1.1 file server that streams grok-generated artifacts to remote
/// clients. `AVPlayer` / QuickLook consume media far better over HTTP
/// (progressive playback, byte-range seeking, graceful buffering on a slow
/// link) than via the chunked control-connection transfer — which also
/// deadlocked against the session actor for multi-chunk files.
///
/// Bound to all interfaces; the Tailscale/LAN tunnel is the trust boundary,
/// exactly as for the control connection (which can already vend any file).
/// Serves only existing regular files, by `?path=` query, with `Range` support.
public actor MediaHTTPServer {
    private var listener: NWListener?
    public private(set) var port: UInt16?

    public init() {}

    /// Starts the server on `port`. Idempotent.
    public func start(port: UInt16) throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))
        l.newConnectionHandler = { conn in
            Task.detached { await MediaHTTPServer.serve(conn) }
        }
        l.stateUpdateHandler = { _ in }
        l.start(queue: .global(qos: .userInitiated))
        listener = l
        self.port = port
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    // MARK: - Request handling

    private static func serve(_ conn: NWConnection) async {
        conn.start(queue: .global(qos: .userInitiated))
        defer { conn.cancel() }

        guard let header = await readHeader(conn) else { return }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { await sendStatus(conn, 400, "Bad Request"); return }
        let tokens = requestLine.split(separator: " ")
        guard tokens.count >= 2, tokens[0] == "GET" || tokens[0] == "HEAD" else {
            await sendStatus(conn, 405, "Method Not Allowed"); return
        }
        let isHead = tokens[0] == "HEAD"

        // /media?path=<percent-encoded absolute path>
        guard let comps = URLComponents(string: "http://h" + tokens[1]),
              let path = comps.queryItems?.first(where: { $0.name == "path" })?.value else {
            await sendStatus(conn, 400, "Bad Request"); return
        }
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int else {
            await sendStatus(conn, 404, "Not Found"); return
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"

        // Optional Range: bytes=start-end
        var start = 0, end = size - 1, partial = false
        if let rangeLine = lines.first(where: { $0.lowercased().hasPrefix("range:") }),
           let (s, e) = parseRange(rangeLine, size: size) {
            start = s; end = e; partial = true
        }
        guard start <= end, start >= 0, end < size else {
            await sendStatus(conn, 416, "Range Not Satisfiable"); return
        }
        let length = end - start + 1

        var head = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: \(mime)\r\n"
        head += "Content-Length: \(length)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        if partial { head += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
        head += "Connection: close\r\n\r\n"
        guard await send(conn, Data(head.utf8)) else { return }
        if isHead { return }

        // Stream the body from disk in blocks (never load the whole file).
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: UInt64(start))
        var remaining = length
        while remaining > 0 {
            let block = min(256 * 1024, remaining)
            guard let data = try? fh.read(upToCount: block), !data.isEmpty else { break }
            remaining -= data.count
            if await send(conn, data) == false { break }   // client went away (seek/cancel)
        }
    }

    /// `Range: bytes=start-end` (end optional). Returns nil if unparseable.
    private static func parseRange(_ line: String, size: Int) -> (Int, Int)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let spec = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, let start = Int(first) else { return nil }
        let end = (parts.count > 1 && !parts[1].isEmpty) ? (Int(parts[1]) ?? (size - 1)) : (size - 1)
        return (start, min(end, size - 1))
    }

    // MARK: - Socket helpers

    private static func readHeader(_ conn: NWConnection) async -> String? {
        var data = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while data.count < 32 * 1024 {
            guard let chunk = await receive(conn), !chunk.isEmpty else { break }
            data.append(chunk)
            if let r = data.range(of: terminator) {
                return String(decoding: data[..<r.lowerBound], as: UTF8.self)
            }
        }
        return nil
    }

    private static func receive(_ conn: NWConnection) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { d, _, _, error in
                cont.resume(returning: error == nil ? (d ?? Data()) : nil)
            }
        }
    }

    @discardableResult
    private static func send(_ conn: NWConnection, _ data: Data) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            conn.send(content: data, completion: .contentProcessed { error in cont.resume(returning: error == nil) })
        }
    }

    private static func sendStatus(_ conn: NWConnection, _ code: Int, _ reason: String) async {
        let s = "HTTP/1.1 \(code) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        await send(conn, Data(s.utf8))
    }
}
