import Foundation
import GrokestratorCore

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
    /// grok wraps the actionable reason (billing/`spending-limit`, auth, upstream
    /// HTTP status) in `error.data` while `message` stays a generic "Internal error"
    /// and `code` a generic `-32603`. Verified against grok 0.2.72 wire logs.
    public let data: RPCErrorData?

    /// Best human-facing summary: prefer the nested detail when grok supplies one,
    /// else fall back to the generic top-level message.
    public var detail: String {
        if let d = data?.message, !d.isEmpty { return d }
        return message
    }

    /// A user-actionable one-liner for known grok failure classes — so a `-32603`
    /// wrapping a billing/credits `403` reads as advice, not a cryptic code. Falls
    /// back to the raw `detail` for everything else.
    public var actionableSummary: String {
        let d = detail.lowercased()
        let isBilling = data?.httpStatus == 403
            || d.contains("spending-limit")
            || d.contains("out of credits")
            || d.contains("grok subscription")
        if isBilling {
            return "Grok is out of credits or needs a subscription — add credits at "
                 + "grok.com or upgrade to SuperGrok, then retry."
        }
        return detail
    }
}

/// The `error.data` payload grok attaches to a wrapped `-32603` (verified 0.2.72).
public struct RPCErrorData: Decodable, Sendable {
    public let message: String?
    public let httpStatus: Int?
    enum CodingKeys: String, CodingKey { case message; case httpStatus = "http_status" }
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

/// `session/prompt` result. `_meta` carries the turn's token usage (verified
/// against grok 0.2.3: totalTokens / input / output / cachedRead / reasoning).
struct PromptStopResult: Decodable {
    let stopReason: String?
    let meta: TokenMeta?
    enum CodingKeys: String, CodingKey { case stopReason, meta = "_meta" }
}

/// Token usage block — appears on the `session/prompt` result `_meta` and
/// (as a running `totalTokens`) on `session/update` `_meta`.
struct TokenMeta: Decodable {
    let totalTokens: Int?
    let inputTokens: Int?
    let outputTokens: Int?
    let cachedReadTokens: Int?
    let reasoningTokens: Int?
}

struct ContentBlock: Decodable, Sendable {
    let type: String
    let text: String?
}

/// `session/update` notification payload.
struct SessionUpdateParams: Decodable {
    let sessionId: String
    let update: Update
    let meta: TokenMeta?               // running token usage (e.g. `_meta.totalTokens`)
    enum CodingKeys: String, CodingKey { case sessionId, update, meta = "_meta" }

    struct Update: Decodable {
        let sessionUpdate: String          // e.g. "agent_message_chunk", "agent_thought_chunk", "tool_call"
        let content: ContentBlock?         // for message/thought chunks (a single object)
        let toolCallId: String?            // for tool_call / tool_call_update
        let title: String?                 // tool call title
        let kind: String?                  // tool call kind
        let status: String?                // tool call status
        let availableCommands: [CommandWire]?   // for "available_commands_update"
        let entries: [PlanEntryWire]?      // for "plan" (grok's live task checklist)
        let currentModeId: String?         // for "current_mode_update" (ACP standard; unobserved from grok)

        enum CodingKeys: String, CodingKey {
            case sessionUpdate, content, toolCallId, title, kind, status, availableCommands, entries, currentModeId
        }

        // `content` is polymorphic on the wire: a single `ContentBlock` for
        // message/thought chunks, but an ARRAY for `tool_call_update` results. Decoding
        // it strictly as `ContentBlock?` threw on the array form and dropped the ENTIRE
        // update (e.g. the completed image-gen result with its `rawOutput.path`). Decode
        // it leniently — an array (or any non-object) yields `nil`, which is fine: tool
        // results are read from `rawOutput`, not this field.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessionUpdate = try c.decode(String.self, forKey: .sessionUpdate)
            content = (try? c.decodeIfPresent(ContentBlock.self, forKey: .content)) ?? nil
            toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            kind = try c.decodeIfPresent(String.self, forKey: .kind)
            status = try c.decodeIfPresent(String.self, forKey: .status)
            availableCommands = try c.decodeIfPresent([CommandWire].self, forKey: .availableCommands)
            entries = try c.decodeIfPresent([PlanEntryWire].self, forKey: .entries)
            currentModeId = try c.decodeIfPresent(String.self, forKey: .currentModeId)
        }
    }
}

/// Wire shape of one entry in grok's `plan` session update. Verified against
/// real grok logs: `{ content, priority, status }`. `priority`/`status` are
/// decoded as raw strings and mapped defensively (unknown → sensible default)
/// so a future grok value never crashes decoding.
struct PlanEntryWire: Decodable {
    let content: String
    let priority: String?
    let status: String?
}

/// Wire shape of an advertised slash command — shared by the `initialize` result
/// and the `available_commands_update` notification.
struct CommandWire: Decodable {
    let name: String
    let description: String?
    let input: Input?
    struct Input: Decodable { let hint: String? }
}

/// `session/request_permission` request payload.
struct PermissionParams: Decodable {
    let sessionId: String?
    let toolCall: ToolCall?
    let options: [Option]

    struct ToolCall: Decodable {
        let title: String?
        let kind: String?                  // e.g. "execute", "edit", "read"
        let rawInput: RawInput?

        /// Tool-specific input. `variant` (e.g. "Bash") is the most precise category
        /// for remembering an allow-always choice ("don't ask again for bash commands").
        struct RawInput: Decodable {
            let variant: String?
            let command: String?
            let file_path: String?
            let old_string: String?
            let new_string: String?
        }
    }

    struct Option: Decodable {
        let optionId: String
        let name: String?
        let kind: String?                  // "allow_once" | "allow_always" | "reject_once" | "reject_always"
    }

    /// Stable category for "remember this kind of permission": the rawInput variant
    /// (e.g. "Bash") when present, else the tool-call kind (e.g. "execute").
    var category: String? { toolCall?.rawInput?.variant ?? toolCall?.kind }
}

/// `_x.ai/ask_user_question` request payload (verified from real wire logs):
/// `{ sessionId, questions: [{ question, options: [{ label, description }] }] }`.
struct AskUserQuestionParams: Decodable {
    let sessionId: String?
    let questions: [AUQQuestion]

    struct AUQQuestion: Decodable {
        let question: String
        let options: [AUQOption]
    }

    struct AUQOption: Decodable {
        let label: String
        let description: String?
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
    case userQuestion(UserQuestionEvent)
    /// A pending permission / user-question was answered — emitted when we resolve
    /// it so every subscriber clears its overlay (cross-device dismissal). `id` is
    /// the request id carried by the original permission/question event.
    case interactionResolved(InteractionResolvedEvent)

    /// grok's live task plan (a re-broadcast snapshot of the whole checklist).
    case plan(PlanEvent)
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

public struct InteractionResolvedEvent: Codable, Sendable {
    public let sessionId: String
    /// The resolved request id (matches the permission/question event's id).
    public let id: String
    public init(sessionId: String, id: String) {
        self.sessionId = sessionId
        self.id = id
    }
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

/// grok's live task plan event, already mapped to the Core `AgentPlan` model
/// (raw priority/status strings normalized defensively in the session client).
public struct PlanEvent: Codable, Sendable {
    public let sessionId: String
    public let plan: AgentPlan

    public init(sessionId: String, plan: AgentPlan) {
        self.sessionId = sessionId
        self.plan = plan
    }
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
    public let options: [PermissionOption]
}

// `PermissionOption` moved to GrokestratorCore (Models/GrokBuildConversation.swift)
// so the wire protocol can carry it directly.

/// Emitted when grok sends `_x.ai/ask_user_question`. `questionId` is the pending
/// request id (`respondToUserQuestion` resolves it); `questions` are mapped to the
/// UI-friendly Core shape. Parallels `PermissionRequestEvent`.
public struct UserQuestionEvent: Codable, Sendable {
    public let sessionId: String
    public let questionId: String
    public let questions: [UserQuestion]

    public init(sessionId: String, questionId: String, questions: [UserQuestion]) {
        self.sessionId = sessionId
        self.questionId = questionId
        self.questions = questions
    }
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
