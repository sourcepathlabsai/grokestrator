# Client Control Plane Protocol — Design & Evolution

**Status**: Design v0.1 reviewed + key decisions locked (2026-06-04). Moving toward implementation.  
**Branch**: `feat/core-client-control-plane`  
**Related PRs**: #4 (Grok Build black box)

---

## Goals for This Phase

We are evolving the client ↔ server control plane (the protocol that flows over Tailscale / in-process for the hybrid Mac app) so that clients (iOS and Mac UI) can fully and ergonomically drive the Grok Build black box that now lives on the server.

Key objectives:
- Clients should be able to interact with remote Grok Build instances at roughly the same fidelity as the local black box (`GrokBuildConversation`).
- Support for streaming rich `ConversationUpdate` events (including progress notes, tool calls, permission requests).
- Bidirectional flow for tool results and permission responses.
- Reasonable history / state synchronization.
- Clean separation: Core owns the shared protocol + client-side implementation. Mac-only server implementation lives in `GrokestratorMac`.
- Versionable and evolvable.

---

## Current State (Post Core + Black Box PRs)

### Existing Pieces in GrokestratorCore

- **GrokestratorProtocol.swift**
  - Very basic `GrokestratorRequest`, `GrokestratorResponse`, `GrokestratorEvent` enums.
  - `sendPrompt(instanceID, conversationID?, text)` is the only prompt-related operation.
  - No rich streaming of agent activity.
  - No tool/permission roundtrip support.
  - Simple envelope (`GrokestratorMessage`).

- **GrokestratorTransport.swift**
  - Simple abstraction: `connect`, `disconnect`, `send(Data)`, `incomingData: AsyncStream<Data>`.

- **Connection.swift** + **MultiServerSession.swift**
  - Connection state machine and multi-server/tab management.
  - Mostly UI-oriented state (connected/disconnected, last error, etc.).

- **ServerState.swift**
  - Can carry `managedInstances: [ManagedInstance]`.
  - Already somewhat prepared for remote instance visibility.

- **ServerCapability** enum (in ServerInfo)
  - Currently has: `instanceManagement`, `conversationPersistence`, `autoRestart`, `multiClient`.

- Models (`ManagedInstance`, `Conversation`, `Message`, etc.) exist but are relatively lightweight.

### What Was Built in PR #4 (Server Side)

- Full production black box: `GrokBuildManager` + `GrokBuildConversation`
- Rich `ConversationUpdate` enum (message, thought, progressNote, activityNote, toolCallRequested, permissionRequested, etc.)
- `PromptResult`, `ToolCallInfo`, `PermissionRequestInfo`
- Automatic history (`AgentConversationHistory`)
- Bidirectional tool/permission handling
- Lifecycle events (`onDied`, etc.)

This richness currently only exists locally on the Mac server. Nothing in the control plane can yet expose it to remote clients.

---

## Key Gaps

| Area                        | Current Protocol                          | What the Black Box Provides                  | Gap |
|----------------------------|-------------------------------------------|----------------------------------------------|-----|
| Prompting                  | Simple `sendPrompt(text)`                 | `sendPrompt` → streaming `ConversationUpdate`, `sendPromptAndCollect` → `PromptResult` | Major |
| Agent Activity             | Only coarse `newMessage` events           | `progressNote`, `activityNote`, thoughts, tool calls, etc. | Major |
| Tool Use                   | None                                      | `pendingToolCalls()`, `sendToolResult()`     | Missing |
| Permissions                | None                                      | `pendingPermissions()`, `respondToPermission()` | Missing |
| Streaming / Correlation    | Basic envelope, no strong streaming model | Long-running agent turns with many updates   | Weak |
| History & State Sync       | `getMessages`, `getConversations`         | Structured `AgentTurn` + flattened history   | Insufficient |
| Lifecycle / Death          | Basic instance status                     | `onDied`, `isAlive`, process exit codes      | Incomplete |
| Capabilities               | Coarse `ServerCapability` set             | Need per-instance + per-turn capabilities?   | Evolving |

---

## Initial Design Direction (Starting Point)

We will evolve the protocol in two layers:

### 1. Control Plane Envelope (keep relatively stable)
- Keep `GrokestratorMessage` + request/response/event split.
- Add strong support for **streaming responses** and **server-initiated streams**.
- Introduce request correlation + cancellation.

### 2. Grok Build Domain Messages (new major area)

Proposed high-level request families:

```swift
// High-level sketch only — not final
enum GrokBuildRequest {
    case listInstances
    case getInstanceState(id: UUID)
    case startPrompt(instanceID: UUID, prompt: String, options: PromptOptions?)
    case cancelPrompt(instanceID: UUID, promptID: UUID)
    case sendToolResult(instanceID: UUID, promptID: UUID, toolCallId: String, result: String, isError: Bool)
    case respondToPermission(...)
    case getConversationHistory(instanceID: UUID, ...)
    case syncConversationState(...)
}
```

Events / streaming updates:

```swift
enum GrokBuildEvent {
    case conversationUpdate(instanceID: UUID, promptID: UUID, update: ConversationUpdate)
    case promptCompleted(...)
    case instanceDied(...)
    case pendingToolCallsChanged(...)
    case permissionRequested(...)
    ...
}
```

We will define:
- `ConversationUpdate` (or a wire-compatible version) needs to become part of the shared protocol surface.
- Clear prompt/session identifiers that survive across the network.
- Good support for partial / incremental updates.

### Transport Layer
- The current `GrokestratorTransport` abstraction is decent. We may enhance it with better framing, ping/keepalive, and backpressure handling for long agent streams.

---

## Open Questions

- How much of the rich `ConversationUpdate` / `AgentTurn` model should be re-exported in Core vs. kept as Mac-only?
- Do we want a higher-level `RemoteGrokBuildConversation` type in Core that feels similar to the local black box?
- How do we handle large histories or media attachments over the wire?
- Versioning strategy for the protocol?
- Should tool definitions / schemas flow over the protocol, or only results?
- Authentication / multi-user concerns (even if Tailscale is the only transport for v1)?

---

## Next Steps (on this branch)

**Current phase**: Moving from design to implementation.

Agreed first implementation slice (proposed):

1. Promote the core conversation model types into GrokestratorCore (`ConversationUpdate`, `AgentTurn`, `AgentMessage`, `ToolCallInfo`, etc.) with minimal changes.
2. Define the wire protocol shapes (`WireConversationUpdate` + request/response/event cases for prompts, tool results, etc.).
3. Implement basic client-side prompt streaming (start a prompt → receive `ConversationUpdate` stream, including progress notes).
4. Support sending tool results back over the wire.
5. Basic higher-level client facade sketch (`RemoteGrokBuildConversation` or equivalent) that hides the protocol details for the common case.

Permission handling and advanced history sync will be deferred or done in a follow-up slice within this branch.

Once this slice is done and working end-to-end (even if only against a mock server at first), we can expand.

---

## Concrete Protocol Proposal – First Draft (v0.1)

**Date**: 2026-06-04  
**Author**: Grok (on behalf of the session)  
**Status**: Strawman for discussion — nothing is locked in.

### Guiding Principles

- **Fidelity over the wire**: A remote client should be able to drive a Grok Build instance with close to the same experience as the local `GrokBuildConversation`.
- **Streaming first**: Most interesting work is long-running. Design the protocol around incremental updates rather than request/response pairs.
- **Explicit prompt lifecycle**: Every prompt has a stable ID that lives across the network boundary.
- **Minimal shared types**: We want to avoid duplicating the entire black box in Core. Prefer a small set of wire types + a higher-level client facade.
- **Forward compatible**: Use enums with associated values + versioned payloads where possible.
- **Tailscale-friendly**: Assume relatively high bandwidth, low-to-medium latency, but design for intermittent connectivity.

### Core New Concepts

#### PromptID
A stable identifier for a single user-initiated turn on a specific instance.

```swift
public struct PromptID: Hashable, Codable, Sendable {
    public let value: UUID
    public let instanceID: UUID
}
```

#### ConversationUpdate (Wire Version)
We will not send the exact same `ConversationUpdate` enum that lives in the Mac app. Instead we define a wire-compatible version.

```swift
public enum WireConversationUpdate: Codable, Sendable {
    case thought(String, metadata: [String: String]?)
    case message(String, metadata: [String: String]?)
    case progressNote(String, phase: String?, metadata: [String: String]?)
    case activityNote(String, kind: String?, metadata: [String: String]?)
    case toolCallRequested(WireToolCallInfo)
    case permissionRequested(WirePermissionRequestInfo)
    case toolResultRecorded(toolCallId: String, isError: Bool)
    case error(String)
    case turnComplete(finalAnswer: String?)
    case rawActivity(payload: Data)   // escape hatch for unknown shapes during discovery
}

public struct WireToolCallInfo: Codable, Sendable, Identifiable {
    public let id: String
    public let toolName: String
    public let arguments: [String: String]?
}

public struct WirePermissionRequestInfo: Codable, Sendable, Identifiable {
    public let id: String
    public let description: String
    public let options: [String]
}
```

> Decision point: Should `WireConversationUpdate` live in Core, or do we just send a JSON blob + a type discriminator and let the client decode?

#### Prompt Lifecycle Messages

**Client → Server**

```swift
case startPrompt(
    instanceID: UUID,
    prompt: String,
    promptID: PromptID?,           // client can supply or server generates
    context: [String: String]?     // optional prior context / instructions
)

case cancelPrompt(instanceID: UUID, promptID: UUID)

case sendToolResult(
    instanceID: UUID,
    promptID: UUID,
    toolCallId: String,
    result: String,
    isError: Bool
)

case respondToPermission(
    instanceID: UUID,
    promptID: UUID,
    permissionId: String,
    chosenOption: String
)
```

**Server → Client (Events / Streaming)**

These would typically arrive over a long-lived stream associated with a `startPrompt` request.

```swift
case promptStarted(instanceID: UUID, promptID: UUID)
case conversationUpdate(instanceID: UUID, promptID: UUID, update: WireConversationUpdate)
case promptCompleted(instanceID: UUID, promptID: UUID, result: PromptCompletion)
case promptCancelled(instanceID: UUID, promptID: UUID)
case pendingToolCallsChanged(instanceID: UUID, promptID: UUID, calls: [WireToolCallInfo])
case permissionRequested(instanceID: UUID, promptID: UUID, info: WirePermissionRequestInfo)
case instanceDied(instanceID: UUID, exitCode: Int32)
```

`PromptCompletion` could be:

```swift
public struct PromptCompletion: Codable, Sendable {
    public let finalAnswer: String?
    public let turnCount: Int
    public let hadToolActivity: Bool
    public let hadPermissionActivity: Bool
}
```

### Streaming Model (High Level)

We will likely need two patterns:

1. **Request-scoped streams** — A `startPrompt` opens a logical stream. All subsequent `conversationUpdate` events for that `promptID` flow on that stream until `promptCompleted` or `promptCancelled`.
2. **Server push events** — General events (`instanceDied`, global state changes, etc.) that are not tied to a specific prompt.

The transport layer will need to support multiplexing multiple logical streams over one connection.

### State Synchronization

New requests:

```swift
case getInstanceState(instanceID: UUID)
case getPromptState(instanceID: UUID, promptID: UUID)   // current status + pending items
case syncConversationHistory(instanceID: UUID, since: Date?)
```

These return richer payloads than today (including `WireConversationUpdate` arrays or full `AgentTurn` snapshots).

### Proposed Changes to Existing Enums

- `GrokestratorRequest` will grow a new case: `.grokBuild(GrokBuildRequest)`
- `GrokestratorEvent` will grow: `.grokBuild(GrokBuildEvent)`
- `GrokestratorResponse` will gain corresponding response variants.

This keeps the envelope stable while isolating the new domain.

### Decisions Locked (2026-06-04)

Based on review feedback:

- **ConversationUpdate / AgentTurn model**: Promote as much of the rich model as possible into GrokestratorCore (ConversationUpdate, AgentTurn, AgentMessage, ToolCallInfo, PermissionRequestInfo, etc.). The intent is for clients to work with high-fidelity structured types rather than raw wire forms where practical.
- **Higher-level abstraction**: Yes — we will design toward a higher-level client abstraction (likely something resembling `RemoteGrokBuildConversation` or a client-side `GrokBuildSession`). We accept that we may need to iterate on the exact ergonomics.
- **Tool support**: Full roundtrip implementation is preferred ("within reason").
- **Permission support**: Lower priority for the initial implementation. Since all connectivity goes through Tailscale, permission requests are considered protected by the network boundary.

Remaining open decisions (streaming/multiplexing details, fire-and-forget vs always-streamed prompts, tool schema representation, backpressure, exact shape of the higher-level facade, etc.) will be resolved during implementation.

---

*This section will be updated as we discuss and refine the design. Once we reach rough consensus on a slice, we move to implementation on this branch.*

---

*Records will continue to be kept in this document and PROJECT_STATE.md as decisions are made.*