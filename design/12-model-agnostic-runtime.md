# Grokestrator — Model-Agnostic Runtime (brain-swap)

Status: **design / implementation plan** — not yet started. Captures the principle
that surfaced in review (2026-06-15) and the plan to realize it.

## The principle

A Node's **LLM is a swappable brain**; Grokestrator is the **body and nervous
system**. The brain *reasons and decides what it wants to do*; the app *decides what
it is actually allowed to do*, executes the permitted actions, observes everything,
and coordinates multiple brains. The brain can be grok, an OpenAI-compatible host
(Groq, Cerebras, together.ai, local llama.cpp / Ollama / LM Studio), Gemini, or an
onboard model. The durable, hard-to-copy value is the body — capability control,
guardrails, observability, orchestration, cross-device supervision. The brain is a
commodity you plug in.

Two decisions already align the codebase with this:

1. **Coordination lives in the app, not in any model.** We deliberately did *not*
   use grok-native subagents; delegation is the app's `delegate` tool + router, so a
   model only needs to *reason and call a tool*. "The app doesn't need to spawn
   anything in the model" — the app spawns/routes/awaits. (See `10`, `11`.)
2. **Capabilities are enforced at our boundary, not by trusting the model.** What a
   Node can do = *(the tools we expose)* + *(per-action permission gating)*. The
   model can't use what we don't grant, and even granted tools are gated per call.

**The mediation invariant** is what makes "any LLM" safe rather than scary: *a Node
acts only through tools we implement.* For a raw-API brain we own the entire
tool-execution loop, so enforcement is total — the guarantee is strongest exactly
where the model is least trusted.

## The seam: `AgentSession` + `ACPEvent`

The brain interface already exists implicitly. `GrokBuildConversation` (the per-Node
black box that normalizes a turn into the broadcast `ConversationUpdate` stream)
talks to its grok client through exactly this surface — extract it as a protocol:

```
protocol AgentSession: Sendable {
    func createSession(metadata: [String: String]?) async throws -> String
    func sendPrompt(sessionId: String, prompt: String) async throws -> AsyncStream<ACPEvent>
    func cancelCurrentPrompt() async
    func finishCurrentPrompt(for sessionId: String)
    func currentCapabilities() async throws -> AgentCapabilities
    func currentUsage() -> SessionUsage
    func sendToolResult(sessionId: String, toolCallId: String, result: String, isError: Bool) async throws
    func respondToPermission(permissionId: String, chosenOption: String, sessionId: String) async throws
    func respondToUserQuestion(questionId: String, questionIndex: Int, answer: String) async throws
    func terminateSession(sessionId: String) async
}
```

`GrokBuildSessionClient` already implements every one of these (ACP over `grok agent
stdio`). The key insight: **`ACPEvent` is the universal event language.** grok speaks
it natively; other backends *synthesize* it (`agent_message_chunk` → `.messageDelta`,
finalize → `.message`, a tool call → `.toolCall`, a gate → `.permissionRequest`,
end → `.done`). Everything above the seam — history, broadcast, transcript UI,
delegate router, role-prompt injection, permission/question overlays — is reused
verbatim, for every brain.

### Layering

```
UI ── ConversationDriver (Live / Remote)        [unchanged]
        └─ GrokBuildManager                       [unchanged: lifecycle, delegate, roles]
             └─ GrokBuildConversation (per Node)  [depends on AgentSession, not the grok type]
                  └─ AgentSession  ◄── the brain-swap seam
                       ├─ GrokBuildSessionClient        (grok over ACP/stdio)   — today
                       ├─ OpenAICompatSession           (Groq/Cerebras/local/Ollama/Gemini-compat)
                       ├─ GeminiSession                 (native Gemini, if needed)
                       └─ OnboardSession                (MLX / llama.cpp in-process)
```

## Capability control (the body)

App-owned, brain-independent:

- **Tool registry.** The set of tools the app can execute — `read_file`,
  `write_file`, `run_command`, a spreadsheet tool, the Orchestration MCP tools
  (`delegate`, …), and MCP-bridged tools. The app owns the implementations.
- **Per-Node grants.** Which tools a Node may call (allowlist) + capability mode
  (read-only / write / execute) + path/cwd scope + network policy. Rides the
  guardrails design in `11`.
- **Per-action gating.** Even a granted tool's call is checked against policy →
  auto-allow / ask-the-user (the existing permission overlay) / deny.

For the **grok backend**, some tools run inside grok; we gate via ACP
`request_permission` (what we already mediate). For **API/onboard backends** we run
the loop ourselves, so the tool registry + policy are enforced directly and totally —
the cleaner case. Long-term, prefer app-implemented tools over model-native ones so
enforcement is uniform.

## Brain binding: pinned vs dynamic (tier routing)

A Node's brain can be bound two ways:

- **Pinned (hard-wired).** The Node always runs on one backend. Deterministic,
  predictable cost, the default for a Node you've tuned to a specific model.
- **Dynamic (tiered).** The brain is chosen *per task*, so an agent runs on a model
  **commensurate with the work** — the orchestrator sizes the job and routes a
  trivial step to a fast/cheap brain and a hard step to a deep/expensive one.

### Tiers, not model strings

The orchestrator reasons about **level of work, not API endpoints.** Define abstract
tiers — e.g. `fast` / `balanced` / `deep` — and a deployment-level **tier map**
resolving each tier to a concrete `AgentBackend`. The user configures *which model
backs each tier*; the orchestrator just picks a tier. This keeps an orchestrator's
choices portable across deployments and is itself a guardrail surface (the app
decides what `deep` costs).

```
enum Tier: String, Codable { case fast, balanced, deep }      // extensible
typealias TierMap = [Tier: AgentBackend]                       // host/server config
```

### How the orchestrator switches a child's brain

Extend the `delegate` tool with an optional tier:

```
delegate(child, task, tier?)     // tier omitted ⇒ the child's default brain
```

The orchestrator's role prompt instructs it to **assess effort and pass a tier**
("simple lookup → fast; multi-file reasoning or final decision → deep"). The router:
1. resolves `tier` → backend via the tier map,
2. **clamps to the child's `allowed` tiers** (a Node can't be escalated past its
   policy — model selection is a *guarded capability*, and a cost ceiling applies),
3. switches the child's `AgentSession` to that backend for the task (and onward until
   changed), then runs the turn as today.

A standalone `set_child_model(child, tier)` can exist too, but routing per-`delegate`
is the ergonomic path. An **app-side auto-policy** (default tier, caps, optional
heuristic by task size) backstops or overrides the orchestrator's pick.

### Switch mechanics (cheap vs heavy)

Because `AgentSession` is per-Node and `ACPEvent` is universal, switching a brain =
swapping the Node's `AgentSession`:

- **API / onboard backends: near-instant.** We hold the conversation context
  app-side and pass it on each call, so a switch is just a new session object hitting
  a different endpoint with the same messages. Mid-conversation switching is trivial —
  this is the case that makes dynamic routing practical.
- **grok (stateful process): heavier.** Switching means a new `grok agent stdio`
  process; the new session is re-primed from persisted history (and `/compact` for
  long ones). Fine for occasional escalation, not per-turn flapping. Lean toward
  pinning grok Nodes, and toward API backends for the dynamically-routed ones.

### Observability

Record the brain (tier + concrete model) that ran each turn, surfaced in the
transcript and the Run view ("Decide · ran on **deep** / cerebras-…"), so cost and
behavior are legible and a misroute is visible.

## Config

Add to `ManagedConnection`:

```
enum AgentBackend: Codable {
    case grokACP(command: String, args: [String])        // today's default
    case openAICompatible(baseURL: String, model: String, apiKeyRef: String?)
    case gemini(model: String, apiKeyRef: String?)
    case onboard(modelPath: String)
}
enum BrainBinding: Codable {
    case pinned(AgentBackend)                             // hard-wired
    case dynamic(default: Tier, allowed: [Tier])         // orchestrator/app routes per task
}
var brain: BrainBinding              // default .pinned(.grokACP(...)) — nothing regresses
var toolGrants: ToolPolicy           // allowlist + capability + scope (rides `11` guardrails)
```

The **tier map** (`Tier → AgentBackend`) is host/server-level config, not per-Node,
so all dynamic Nodes share one notion of what `fast`/`deep` mean. Secrets
(`apiKeyRef`) reference the Keychain, never inline in `connections.json`.

## Phased roadmap

Each phase ships value and de-risks the next; stop after any phase with a strictly
more capable tool.

- **Phase A — formalize the seam (no behavior change).** Extract `AgentSession`;
  conform `GrokBuildSessionClient`; make `GrokBuildConversation` depend on the
  protocol. Add `backend` to `ManagedConnection` defaulting to `.grokACP`. Pure
  refactor + config field; grok path unchanged. Proves the seam.
- **Phase B — one non-grok brain (the 80/20): `OpenAICompatSession`.** Implement the
  agent loop against an OpenAI-compatible `/chat/completions` with tool calling —
  which **Groq, Cerebras, together.ai, Ollama, LM Studio, llama.cpp, and Gemini's
  compat endpoint all speak**, so one adapter unlocks most of "any LLM." Emit
  `ACPEvent`s; execute a minimal tool set (`read_file`/`write_file`/`run_command`)
  through the app, gated by a basic policy. Per-Node config picks backend + model +
  key. A Node can now be a Groq/Cerebras/local model.
- **Phase C — app-owned tool registry + capability policy.** Formalize the registry,
  per-Node grants, and per-action gating (the `11` guardrails). Bridge MCP tools
  (including `delegate`) into it so API-model Nodes orchestrate too.
- **Phase D — dynamic tier routing.** Add `Tier` + the host tier map + `BrainBinding`
  (pinned vs dynamic). Extend `delegate(child, task, tier?)`; the router resolves +
  clamps to allowed tiers + swaps the child's `AgentSession`. Record the brain per
  turn. Cheapest over API/onboard backends (app-held context); pin grok Nodes. This
  is "switch an agent to a model commensurate with the task."
- **Phase E — more brains.** Native Gemini shape if its compat endpoint is limiting;
  an onboard runtime (MLX / llama.cpp) for fully-local Nodes.
- **Phase F — UI.** Per-Node binding editor (pinned model **or** dynamic: default +
  allowed tiers), the host tier map, and the capability/permission editor in the Node
  settings sheet.

## Risks / notes

- **Mediation is load-bearing.** App-enforced capability control holds only if the
  brain acts *solely* through channels we mediate. A brain with its own un-mediated
  tools/network leaks around policy. API/onboard backends are airtight (we own the
  loop); grok is mostly mediated via ACP permission. Keep the invariant.
- **Tool-calling fidelity varies by model.** Smaller/local models call tools less
  reliably; the role-prompt injection and a strict tool schema help. Keep a model's
  job scoped to its competence (cheap local model for Observe, stronger model for
  Decide, etc. — a natural fit for the OODA roles and for tier routing).
- **Dynamic routing needs guardrails.** Model selection is a *guarded capability*:
  clamp to a Node's `allowed` tiers and apply a cost ceiling so an orchestrator can't
  escalate everything to the most expensive brain. Avoid per-turn tier flapping on
  grok Nodes (process rebuild cost) — prefer pinning grok and routing API backends.
  Record the chosen brain per turn so misroutes and cost are visible.
- **Not grok-only, but grok stays default.** The standalone single-grok experience
  is unchanged; multi-model is opt-in per Node.
- This is the technical substrate the separate monetization bet
  (`strategy-general-case-ai.md`) would ride — but it serves the founder's own
  orchestration first; don't let the bet pull scope.

## Relationship to other documents

- `11-orchestration-platform.md` — the orchestration platform this generalizes; the
  mediation principle and guardrails are shared. This doc promotes `11`'s "keep ACP
  generic so the runtime isn't grok-locked" footnote to a first-class plan.
- `10-agent-orchestration.md` — the rungs; app-side coordination (not grok-native
  subagents) is what makes brain-swap possible.
- `connection-semantics` (memory) — 1 Connection = 1 instance; a "brain" is the
  instance's runtime, selected per Node.

---

*Created 2026-06-15. Revised 2026-06-15: added **brain binding** (pinned vs dynamic)
and **tier routing** — a Node can be hard-wired to one LLM, or run dynamic so the
orchestrator routes each task to a model commensurate with the work (Phase D). Status:
implementation plan; not started. Phase A (formalize the seam) is the first,
behavior-preserving step; Phase B (OpenAI-compatible backend) is the first real
brain-swap and the biggest single unlock; Phase D adds dynamic, task-sized routing.*
