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

## Brain binding: pinned vs dynamic (evidence-driven escalation)

A Node's brain can be bound two ways:

- **Pinned (hard-wired).** The Node always runs on one backend. Deterministic,
  predictable cost, the default — and the right choice for most quality work.
- **Dynamic.** The brain *can* change per task. But **not** by an automatic
  task-sizer (see the correction below); only by conservative, evidence-driven
  escalation.

### Why "route by task size" is wrong (correction, 2026-06-16)

The earlier framing — *the orchestrator sizes the job and routes trivial→fast,
hard→deep* — sacrifices quality for management convenience, which is backwards:

- **You can't cheaply know when a task needs more capability**, and a weaker model
  handed a task beyond it doesn't fail loudly — it produces *confident, plausible
  wrong*, exactly where you can least afford it.
- **Escalation is a quality move; downgrade is a management move.** Conflating them
  is the error.
- **The dominant quality lever is *orientation*, not model size.** A smaller model
  *with* the project's design oracle (see `13-design-oracle.md`) routinely beats a
  bigger model *without* it. Spend the effort there before reaching for a bigger
  brain.

So dynamic binding survives only in this disciplined form:

1. **Default to the capable model.** Never downgrade a Node by guessing a task is
   easy.
2. **Downgrade only for explicitly narrow, mechanical work** the operator has marked
   as such (fetch, format, run-tests-and-report) — "earn the cheap model," don't
   assume it.
3. **Escalate on *evidence*, not pre-judgment:** an output oracle rejects the result,
   tests fail, or the model itself signals uncertainty → re-run the step on a more
   capable backend. Try-then-escalate, never assume-then-downgrade.

### Tiers + map (kept, for the escalation case)

Tiers stay abstract (`fast`/`balanced`/`deep`) resolved by a host-level tier map, so
escalation targets are portable and the app caps cost. `delegate(child, task, tier?)`
carries an *explicit* hint when the operator/orchestrator knows a step is cheap; the
router resolves it, **clamps to the child's `allowed` tiers**, and swaps the
`AgentSession`. The default path passes no tier and uses the child's pinned brain.

```
enum Tier: String, Codable { case fast, balanced, deep }      // extensible
typealias TierMap = [Tier: AgentBackend]                       // host/server config
```

There is **no automatic task-size router.** Escalation is triggered by failure/oracle
signals; downgrade is explicit and narrow.

### Switch mechanics (cheap vs heavy)

Because `AgentSession` is per-Node and `ACPEvent` is universal, switching a brain =
swapping the Node's `AgentSession`:

- **API / onboard backends: near-instant.** We hold the conversation context
  app-side and pass it on each call, so a switch is just a new session object hitting
  a different endpoint with the same messages. Mid-conversation switching is trivial —
  this is what makes *evidence-driven escalation* cheap (re-run a failed step on a
  bigger brain with the same context).
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
so all dynamic Nodes share one notion of what `fast`/`deep` mean. Secrets: a Node's
`apiKeyRef` stores only the *name* of a key; the value is resolved at launch by
`Secrets` from the process env or a gitignored, host-local
`~/Library/Application Support/Grokestrator/.env.local_llm` — never inline in
`connections.json`, never committed. (Keychain is a later hardening.)

## Context management (working context vs display)

A stateless online LLM has no server-side memory: continuity is the harness re-sending
the accumulated history each call. With grok we don't own this (grok's process holds
session state and self-compacts); with any non-grok backend **we become the harness**,
so we must keep the resent context small without losing the gist.

The architecture that makes this **invisible to the user** is two separate contexts:

- **Display transcript** — what the user sees. Always complete, persisted on disk,
  never lossy. The customer manages nothing and never hits a "context full" wall.
- **Working context** — what we actually send the model. Aggressively, automatically
  optimized. Compaction touches *only* this; the human-facing record is untouched.

A budget-driven `ContextManager` targets ≤ a fraction of *that backend's* window and
applies a ladder, escalating only as far as needed:

1. **Lossless first.** Prime scaffolding once (not per turn); **externalize large tool
   outputs** (keep a reference + head/tail snippet, full output on disk, re-read on
   demand — the biggest single win for coding); diffs not whole files; dedup repeated
   reads; coalesce tool-call bursts; drop chain-of-thought from the resend (keep
   conclusions).
2. **Windowing.** Pinned head (role, goal, constraints, decisions, open TODOs) +
   verbatim recent tail + compactable middle. Maintain a dense **state object**
   (goal / decisions / facts / files touched / plan / open questions) rather than
   replaying turns.
3. **Summarize the middle** with a **cheap (`fast`-tier) model** — compaction is itself
   a delegated job; recursive/hierarchical as it grows.
4. **Retrieval** for very long sessions: store everything, embed the current task, pull
   back only relevant snippets (local `nomic-embed` via LM Studio = zero-cost
   embeddings). Working context = anchors + retrieved + recent tail; scales unbounded.

**Orchestration is itself compaction:** each single-purpose child works in its own
small context and the `delegate` router returns only its distilled result, so the
orchestrator never holds children's internal turns.

**Gist safeguards:** a never-compacted **session contract** (goal/constraints/decisions/
plan); compaction prompts that must preserve decisions, facts, state changes, open
questions, and user "remember this" notes; an **oracle check** that the summary still
names the key entities/decisions (redo if it dropped one); pin-on-demand.

### When does this rise to the top of the list?

It is **deliberately low while everything is grok** — grok self-manages context, which
is why we've shipped this far without it. It **rises to the top the moment a non-grok
brain does real, multi-turn, or tool-heavy work** (i.e. as soon as Phase B is used for
more than toy turns), because we then own the resend and small windows fill fast.
Promotion signals: a backend with a small window in the tier map; large tool outputs
(a single file read can blow a 3B model's window); length-rejected/truncated requests;
rising cost/latency from re-sending; and **dynamic tier routing (Phase D)**, where the
working context must fit the *smallest* allowed model. Practically: the **lossless
subset (#1) + windowing (#2) + pinned contract ride into Phase B** as part of "usable,"
while **summarization (#3) and retrieval (#4) land as Phase B′** once sessions actually
run long.

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
  key. A Node can now be a Groq/Cerebras/local model. **Includes the lossless context
  subset** (externalized tool outputs, windowing, pinned contract) — needed for B to be
  usable on small-window models.
- **Phase B′ — full context management.** The budget-driven `ContextManager`:
  cheap-tier summarization + local-embedding retrieval + the gist oracle, behind the
  display/working split (see Context management). Triggered once sessions run long;
  raises in priority with small-window tiers and Phase D.
- **Phase C — app-owned tool registry + capability policy.** Formalize the registry,
  per-Node grants, and per-action gating (the `11` guardrails). Bridge MCP tools
  (including `delegate`) into it so API-model Nodes orchestrate too.
- **Phase G — host-owned MCP registry (model-agnostic tool servers).** Grokestrator
  owns the MCP server list (`mcp.json`, `MCPRegistry`) rather than relying on grok's
  config — `MCPServerConfig {id, name, transport: stdio|http}` curated in Settings ▸
  MCP. Each Node carries a **grant** (`grantedMCPServerIDs`, `nil`=all) over the
  registry, edited from its "MCP Access…" menu. *Slice 1 (done):* grok Nodes get
  their granted servers injected into `session/new` (reusing the existing path), so
  grok connects to them like any MCP server. *Slice 2 (done):* `MCPStdioClient` — a
  minimal in-app MCP client (`initialize` → `notifications/initialized` →
  `tools/list` → `tools/call`, newline-delimited JSON-RPC over stdio) — connects to
  an `OpenAICompatSession`'s granted servers, advertises their tools (namespaced
  `mcp__server__tool`) into the chat-completions loop, and proxies calls/returns. So
  **API brains use MCP too**; the per-Node grant is the gate (no separate
  permission overlay — API brains are airtight because we own the loop). Subprocesses
  spawn lazily, are reused across turns, and are torn down on stop. This completes
  Phase C's "bridge MCP tools so API-model Nodes orchestrate too" beyond `delegate`.
  *Remaining:* the registry's `http` transport for API brains (grok already gets it).
- **Phase D — evidence-driven escalation** (not a task-size router; see the
  correction above). Add `Tier` + host tier map + `BrainBinding`; default capable,
  downgrade only for explicitly-marked mechanical work, **escalate on failure/oracle
  signals**. `delegate(child, task, tier?)` carries an explicit hint; the router
  clamps to allowed tiers + swaps the `AgentSession`. Record the brain per turn.
  Lower priority than the design oracle (`13`), which is the real quality lever.
- **Phase E — more brains.** **Done for the cloud providers via the OpenAI-compatible
  path + host-local secrets:** Groq (`api.groq.com/openai/v1`), Cerebras
  (`api.cerebras.ai/v1`), and **Gemini via its `/v1beta/openai` compat endpoint**
  (tool-calling works — no native adapter needed), plus xAI (`api.x.ai/v1`). Verified
  live (each returns through the same seam). Remaining: an **onboard** runtime (MLX /
  llama.cpp) for fully in-process local Nodes — the only genuinely new backend.
- **Phase F — UI. Done.** Per-Node **brain editor** ("Edit Brain…": pinned backend
  via the shared `BackendEditor`, **or** dynamic — default tier + allowed tiers) and
  **tool/capability editor** ("Edit Tools…": capability tier + per-tool allowlist,
  mirroring `OpenAICompatSession.isPermitted`) in the sidebar row menu; the **host
  tier map** editor in **Settings ▸ Brains** (`Tier → AgentBackend`, persisted
  host-local in `tiermap.json`). Saving a change restarts a running Node so it
  rebinds (`GrokBuildManager.restartInstance` ends the old broadcast streams;
  `LiveConversationDriver` re-subscribes — the live UI follows without a reopen). A
  `dynamic` binding now resolves its **default tier** through the host map at
  (re)start; per-task tier *selection/escalation* across the allowed set is still
  Phase D.
- **Brain catalog (the model is config, not code).** Brains are a curated host-local
  library (`brains.json`): a `BrainProfile {id, name, backend}` — provider + model +
  key *name* — with **several per service** so a Node/tier picks the model fit for the
  task. Everything references brains **by id**: `BrainBinding` is now
  `grok | profile(id) | dynamic`, and the tier map is `Tier → BrainRef` (`grok |
  profile(id)`). Resolution flows through the catalog (a dangling id ⇒ grok). Models
  are never hardcoded — the catalog editor (**Settings ▸ Brains**) curates them and a
  **"Fetch models"** button lists each provider's live `/v1/models`. Presets are just
  one-click seeds. Keys are entered in-app and written host-locally to `.env.local_llm`
  (`0600`, gitignored) via a writable `Secrets`; created with a template on first run.
  Legacy inline-pinned API brains migrate into catalog profiles at load
  (`BrainBinding.inlineLegacy` → `migrateBrainsIfNeeded`). This catalog is the
  substrate the tier map + design oracle (`13`) route over.
- **ACP agents are a first-class brain type.** The command-based binding (`.grok`)
  isn't grok-specific — it launches *any* ACP-over-stdio agent and drives it through
  `GrokBuildSessionClient`. So **grok and Claude Code are two ACP agents that differ
  only by launch command** (Claude Code via the `claude-code-acp` adapter; see the
  "Add Claude Code Agent" setup). The UI presents this honestly: the brain type is
  **"ACP Agent"**, and the specific agent (grok / Claude Code / custom) is detected
  from the command (`acpAgentLabel`) and shown in Edit Brain / Add Connection / Edit
  Tools. **Auth is surfaced:** `initialize` captures the agent's `authMethods`, and a
  failed `session/new` for an unauthenticated agent reports the actionable hint (e.g.
  Claude Code → "Run `claude /login`") instead of a silent timeout. ACP carries the
  agent's tool-permission requests, so a self-equipped agent (Claude with its own MCP
  servers) stays mediated by the body — vendor-neutral, verified live.

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
and **tier routing**. Revised 2026-06-16: corrected dynamic routing — *no automatic
task-size router*; default to the capable model, downgrade only for explicitly narrow
mechanical work, and **escalate on evidence** (oracle reject / test fail / model
uncertainty). The real quality lever is **orientation**, not model size — see the new
`13-design-oracle.md`. Status:
implementation plan; not started. Phase A (formalize the seam) is the first,
behavior-preserving step; Phase B (OpenAI-compatible backend) is the first real
brain-swap and the biggest single unlock; Phase D adds dynamic, task-sized routing.*
