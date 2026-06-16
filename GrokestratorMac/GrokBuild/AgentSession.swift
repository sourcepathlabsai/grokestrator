import Foundation
import GrokestratorCore

/// The **brain interface** — the seam that makes a Node's LLM swappable
/// (`design/12-model-agnostic-runtime.md`). It is exactly the surface
/// `GrokBuildConversation` needs to drive one turn, with **`ACPEvent` as the
/// universal event language**: grok speaks it natively (`GrokBuildSessionClient`),
/// and future backends (OpenAI-compatible, Gemini, onboard) *synthesize* it from
/// their own APIs. Everything above this seam — history, broadcast, transcript,
/// the delegate router, role-prompt injection, permission/question overlays — is
/// reused unchanged for every brain.
///
/// Phase A introduces the protocol and routes `GrokBuildConversation` through it
/// without changing behavior; `GrokBuildSessionClient` is the only conformer today.
public protocol AgentSession: Sendable {
    /// Create (or return) the underlying agent session, yielding its id.
    func createSession(metadata: [String: String]?) async throws -> String

    /// Capabilities (model, MCP servers, slash commands) for the inspector.
    func currentCapabilities() async throws -> AgentCapabilities

    /// Token / context usage for the session.
    func currentUsage() async -> SessionUsage

    /// Fire a prompt; the turn streams back as `ACPEvent`s until it ends.
    func sendPrompt(sessionId: String, prompt: String) async throws -> AsyncStream<ACPEvent>

    /// Return a tool result the agent is waiting on.
    func sendToolResult(sessionId: String, toolCallId: String, result: String, isError: Bool) async throws

    /// Best-effort stop of the in-flight turn.
    func cancelCurrentPrompt() async

    /// Answer a pending permission request with the chosen option.
    func respondToPermission(permissionId: String, chosenOption: String, sessionId: String) async throws

    /// Answer a pending user question.
    func respondToUserQuestion(questionId: String, questionIndex: Int, answer: String) async throws

    /// Mark the current turn finished (unwinds the stream so `turnComplete` rides out).
    func finishCurrentPrompt(for sessionId: String) async

    /// Tear down the session.
    func terminateSession(sessionId: String) async
}

/// grok over ACP/stdio is the first brain. It already implements every member of
/// the contract, so this is a pure declaration of conformance.
extension GrokBuildSessionClient: AgentSession {}
