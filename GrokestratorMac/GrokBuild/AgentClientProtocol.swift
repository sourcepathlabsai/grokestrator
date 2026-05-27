import Foundation

// MARK: - Agent Client Protocol (ACP) for Grok Build
//
// Grok Build (`grok agent stdio`) speaks the standard Agent Client Protocol:
// newline-delimited JSON-RPC 2.0 over stdin/stdout. This file defines:
//   1. The JSON-RPC envelope + the typed param/result shapes we send and receive.
//   2. `ACPEvent` — the *internal* high-level event the rest of the black box
//      (GrokBuildConversation, AgentConversationHistory) consumes. The session
//      client translates ACP `session/update` notifications into `ACPEvent`s.
//
// This is distinct from Grokestrator's own control plane (GrokestratorProtocol).

// MARK: - JSON-RPC envelope

/// A JSON-RPC id, which ACP allows to be either an integer or a string.
public enum RPCID: Codable, Hashable, Sendable {
    case int(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .int(i) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }
}

public struct RPCErrorBody: Decodable, Sendable {
    public let code: Int
    public let message: String
}

/// Just enough of an incoming line to route it (response vs notification vs request).
struct RPCEnvelope: Decodable {
    let id: RPCID?
    let method: String?
    let error: RPCErrorBody?
}

/// Generic wrapper to pull a typed `result` out of a full response line.
struct RPCResult<T: Decodable>: Decodable { let result: T }
/// Generic wrapper to pull typed `params` out of a notification/request line.
struct RPCParams<T: Decodable>: Decodable { let params: T }

/// Minimal JSON value used to build outgoing JSON-RPC messages.
///
/// Encoded with `JSONEncoder(.withoutEscapingSlashes)` — Grok Build's method
/// dispatch rejects slash-escaped method names (e.g. `session\/new`), which
/// `JSONSerialization` would otherwise produce.
enum JSONValue: Encodable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - Typed ACP params / results

struct NewSessionResult: Decodable { let sessionId: String }
struct PromptStopResult: Decodable { let stopReason: String? }

struct ContentBlock: Decodable, Sendable {
    let type: String
    let text: String?
}

/// `session/update` notification payload.
struct SessionUpdateParams: Decodable {
    let sessionId: String
    let update: Update

    struct Update: Decodable {
        let sessionUpdate: String          // e.g. "agent_message_chunk", "agent_thought_chunk", "tool_call"
        let content: ContentBlock?         // for message/thought chunks
        let toolCallId: String?            // for tool_call / tool_call_update
        let title: String?                 // tool call title
        let kind: String?                  // tool call kind
        let status: String?                // tool call status
    }
}

/// `session/request_permission` request payload.
struct PermissionParams: Decodable {
    let sessionId: String?
    let options: [Option]

    struct Option: Decodable {
        let optionId: String
        let name: String?
        let kind: String?                  // e.g. "allow_once", "allow_always", "reject_once"
    }
}

/// `fs/read_text_file` request payload.
struct FsReadParams: Decodable {
    let sessionId: String?
    let path: String
    let line: Int?
    let limit: Int?
}

/// `fs/write_text_file` request payload.
struct FsWriteParams: Decodable {
    let sessionId: String?
    let path: String
    let content: String
}

// MARK: - Internal high-level event (consumed by the rest of the black box)

public enum ACPEvent: Codable, Sendable {
    case sessionCreated(SessionCreatedEvent)
    case message(MessageEvent)
    case thought(ThoughtEvent)

    /// Incremental streamed text for the in-progress assistant message / thought.
    /// Emitted live per chunk; the coalesced `.message` / `.thought` still arrives
    /// at block end (for history + as the authoritative finalized text).
    case messageDelta(String)
    case thoughtDelta(String)
    case toolCall(ToolCallEvent)
    case toolResult(ToolResultEvent)
    case permissionRequest(PermissionRequestEvent)
    case sessionUpdate(SessionUpdateEvent)
    case error(ACPErrorEvent)
    case done(sessionId: String)

    // Progress / activity notes from the real Grok Build agent (the "little notes" you see live)
    case progress(ProgressEvent)
    case activity(ActivityEvent)

    /// Catch-all for unknown event shapes we haven't modeled yet.
    /// Useful during protocol discovery — the raw payload is preserved so we can inspect it.
    case unknown(rawPayload: Data, typeHint: String?)
}

public struct SessionCreatedEvent: Codable, Sendable {
    public let sessionId: String
    public let capabilities: [String]?
}

public struct MessageEvent: Codable, Sendable {
    public let sessionId: String
    public let role: String // "assistant", "user", etc.
    public let content: String
    public let metadata: [String: String]?
}

public struct ThoughtEvent: Codable, Sendable {
    public let sessionId: String
    public let content: String
    public let metadata: [String: String]?
}

public struct ToolCallEvent: Codable, Sendable {
    public let sessionId: String
    public let toolCallId: String
    public let toolName: String
    public let arguments: [String: String]?
}

public struct ToolResultEvent: Codable, Sendable {
    public let sessionId: String
    public let toolCallId: String
    public let result: String
    public let isError: Bool
}

public struct PermissionRequestEvent: Codable, Sendable {
    public let sessionId: String
    public let permissionId: String
    public let description: String
    public let options: [String]
}

public struct SessionUpdateEvent: Codable, Sendable {
    public let sessionId: String
    public let status: String
    public let metadata: [String: String]?
}

public struct ACPErrorEvent: Codable, Sendable {
    public let sessionId: String?
    public let code: String
    public let message: String
}

// MARK: - Progress / Activity Events (the live "little notes" from Grok Build)

/// A granular progress or status update emitted by the agent during thinking/tool use/etc.
public struct ProgressEvent: Codable, Sendable {
    public let sessionId: String?
    public let content: String
    public let phase: String?
    public let progress: Double?
    public let metadata: [String: String]?
}

/// Slightly more general activity note.
public struct ActivityEvent: Codable, Sendable {
    public let sessionId: String?
    public let note: String
    public let kind: String?
    public let metadata: [String: String]?
}
