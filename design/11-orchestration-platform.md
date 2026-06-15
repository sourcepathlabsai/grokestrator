# Grokestrator — Orchestrated Agent Platform (Implementation Plan)

Status: **design / implementation plan** — a deliberate scope expansion. Grokestrator
becomes a heavy-duty **orchestrated multi-agent platform**: a tree of grok
Connections where some are **orchestrators** (coordinate children) and some are
**agents** (do the work), exchanging data rigorously, backed by an embedded database
the orchestrators manage, and kept honest by **oracles** that detect, flag, and
isolate violating cells.

This is the **convergence** of three threads already in the repo/vault:
- `10-agent-orchestration.md` — the "rungs"; this plan commits to **rung 3 (the
  steerable fleet)** and goes well past it.
- `~/dev/AI/01-ai-native-software-architecture.md` — the **immune-system / oracle**
  thesis. This platform *is* the human-facing console of an immune system.
- `00-vision-and-north-star.md` — the supervision UX (watch agents think, answer
  them) is the load-bearing asset; it's exactly what an orchestration platform needs.

> **The standing rule still holds** (`connection-semantics`): one Connection = one
> grok instance, **no nested chats**. The tree is a *soft `parentID` edge* between
> sibling Connections, not nested objects. Every node remains its own observable,
> steerable Connection. That is *why* Grokestrator (not grok-native subagents) can
> build this: grok subagents are invisible over ACP and can't talk to the user;
> real Connections can be watched and answered.

---

## 1. The vision, decomposed (domain model)

| Concept | Definition |
|---|---|
| **Node** | A Connection in the orchestration tree. Still 1:1 with one grok process, one chat, observable on every device. |
| **Role** | A Node is an **agent** (leaf — does work, no children) or an **orchestrator** (has children — plans, delegates, aggregates, runs oracles). Multi-level: orchestrators may have orchestrator children → a tree. |
| **Role prompt/config** | The system prompt + settings that make a Node *behave* as an orchestrator vs. an agent (plan-and-delegate vs. execute-and-return). Authored as grok agent/role files (rides `10`'s rung-2 config) and/or injected by Grokestrator. |
| **Tools + isolation** | Each Node gets the tool set it needs (its MCP servers + the **Orchestration MCP**, below). *Optional* isolation: own working dir / git worktree, capability mode (read-only / read-write / execute), scoped filesystem. Not required. Tool provisioning is **both, sequenced**: a parent first *grants/scopes existing* tools to a child (Phase 2), and later *synthesizes new* tools — an oracle-gated **cell** the child can call (Phase 4+). |
| **Trigger** | What *activates* a Node. A parent `delegate` (pull) is one path; a **schedule or event** (push) is the other — cron, a file/webhook, a parent signal, or (once the DB lands) a row appearing. Triggers turn a child from a request/response delegate into a **standing agent** — the "run periodically or on an event" capability. |
| **Guardrail** | A **pre-action** bound on what a Node may *attempt*, enforced by the mediation layer: tool allowlist, cwd/path scope, capability mode, resource budget (tokens/turns/time). Distinct from an **oracle**, which checks *outputs* after the fact. Guardrails bound the blast radius; oracles catch bad results. Defense in depth. |
| **Embedded DB** | A Grokestrator-owned database. Orchestrators **create schemas** for task data that must persist during a run. The shared state / workflow system-of-record. |
| **Data exchange** | Bidirectional, **rigorous** (typed/validated) flow between orchestrators and agents — inputs down, results up — mediated through the Orchestration MCP + DB, never ad-hoc. |
| **Cell** | A unit an agent produces that must be correct — typically a **script/function** it writes to perform a step. The thing oracles guard. |
| **Oracle** | A registered, checkable definition of *correct* for a cell, a DB write, or an agent result. The platform **detects** violations, **flags** them, and **isolates** (quarantines) the offending cell so its output can't propagate. |

The platform is, precisely, the immune system from the vault thesis: **agents
generate cells; oracles are the recognition boundaries; detect→flag→isolate→repair
is the immune response; the DB is the shared memory; orchestrators are the
coordination; the human supervises the exceptions.**

---

## 2. Architecture

### 2.1 Reuse vs. net-new

| Concern | Reuse (exists today) | Net-new |
|---|---|---|
| Per-node agent process + ACP | `GrokBuildManager`, `GrokBuildConversation`, `GrokBuildSessionClient` | — |
| Observability on every device | broadcast/subscription plane, `ConversationViewModel` | — |
| Human supervision surface | sidebar, permission/question overlays, **attention badge**, inspector | tree (nested) sidebar; run/oracle views |
| In-app server precedent | `MediaHTTPServer` (proves we can bind an in-app server; grok speaks http-MCP) | **Orchestration MCP server** |
| Tree edge + nesting | (designed in `10` rung 3) | `role` + `parentID` on the Connection model; one+ sidebar disclosure level |
| Role/prompt authoring | (`10` rung 2 config GUI) | orchestrator/agent templates |
| — | — | **embedded DB + schema manager**, **oracle engine**, **delegation router + run state** |

### 2.2 The spine: a Grokestrator-hosted Orchestration MCP server

Everything an orchestrator or agent does *beyond talking to the user* goes through
**one in-app MCP server** every Node connects to (http transport, like
`MediaHTTPServer`). This is the single most important design decision: **mediated,
not ad-hoc.** Because all delegation and all data access flow through tools
Grokestrator implements, Grokestrator can validate, log, oracle-check, quarantine,
and surface everything. This is the thesis's *oracle-contracts at the edges*: nodes
don't wire into each other; they call tools whose outputs are checked.

Tool surface (grown across phases):

```
delegate(child, task, inputs)        → route task to a child Node; return its result
task.report(status, result)          → an agent reports progress/result up
node.configure(child, policy)        → grant/scope a child's tools + guardrails (allowlist, cwd, capability, budget)
trigger.schedule(child, when, task)  → wake a child on a cron/event spec (standing agent)
trigger.fire(event, payload)         → emit an event that may wake subscribed children
db.createSchema(name, schema)        → orchestrator defines a task table (schema = data oracle)
db.insert / db.query / db.update      → typed, schema-validated DB access
oracle.register(target, check)        → attach an oracle (golden/invariant/shape/recon) to a cell/result
oracle.check(target, output)          → run the oracle; returns pass | violation
cell.submit(name, code, oracleRef)    → submit a script/function for oracle-gated acceptance
```

### 2.3 The mediation principle (why this stays buildable)

Per the immune-system thesis: **make the small core correct, make everything else
disposable.** The durable, must-be-right core here is *small and well-bounded*:

- the **Orchestration MCP server** (the tool contracts),
- the **DB + schema validator** (the data oracle),
- the **oracle engine** (detect/flag/isolate),
- the **delegation router + run state**.

Everything the agents *produce* — scripts, intermediate data, even whole agent
sessions — is **disposable and regenerable**. The plan's job is to keep that core
small and trustworthy and push all the generation outside it. Do **not** let the
core sprawl into a cathedral.

---

## 3. Component designs (sketch-level)

**Node / role model.** Extend `ManagedConnection` / `InstanceItem` with: `role`
(`agent` | `orchestrator`), `parentID: UUID?`, `rolePromptRef`, `tools` (which MCP
servers), `capability` (read/write/execute), `isolation` (none | cwd | worktree).
The "1 Connection = 1 instance, no nested chats" rule is intact; this is just edges
+ config on existing Connections.

**Orchestration MCP server.** An in-app actor binding an http MCP endpoint (model
`MediaHTTPServer`). Registers itself into every Node's `.grok/` MCP config so grok
can call it. Routes tool calls to the router / DB / oracle engine. Host-local
(Grokestrator on the owning Mac drives; remote devices observe + answer — matches
"GKSS is the source of truth").

**Delegation router + run state.** `delegate(child, task, inputs)` → look up the
child Node, send it a prompt assembled from `task` + `inputs` (which it reads from
the DB), track the delegation in a **Run** (a DAG of delegations with status,
inputs, outputs, oracle verdicts), `await` the child's `task.report`, return the
result to the caller. Handles: parallel fan-out (multiple `delegate` in flight),
a child raising a **question** (rolls up via the existing attention badge — the
human answers, the child resumes), failure/retry/escalation.

**Embedded DB + schema manager.** SQLite (embedded, zero-ops). `db.createSchema`
defines a task table from a JSON-schema-ish spec; the spec **is the data oracle** —
every `db.insert/update` is validated against it and *rejected* on violation. A DB
inspector view in the UI. Orchestrators own schema lifecycle; agents read/write
through tools (mediated, so nothing corrupts state directly).

**Oracle engine (the immune system).** `oracle.register(target, check)` attaches a
check to a cell/DB-write/result. Check kinds, cheapest first: **schema/shape**
validation, **invariants/property** tests, **reconciliation/round-trip**,
**golden-example** tests, **redundancy/voting** (N agents must agree), **sampled
human review**. When a cell produces output: run its oracle → **pass** propagates;
**violation** → flag + **quarantine** the cell (its output is blocked), surface to
the human, and ask the producing agent to regenerate (`detect→flag→isolate→repair`).
Semantic oracles (did the *meaning* survive) are the hard frontier — **out of early
scope**; start with the cheap, objective ones. (See `~/dev/AI/03`.)

**Triggers & standing agents.** Delegation (above) is *pull* — an orchestrator calls
`delegate` and awaits. The second activation model is *push*: a child runs
**periodically or on an event**, with no parent blocking on it. This is what makes a
child a **standing agent** rather than a one-shot worker — the "agentic capability
built in." A host-local **scheduler/event-bus** in GKSS owns it (matching "GKSS is
the source of truth"; remote devices observe, the host fires):

- **Sources.** cron/interval; a filesystem watch; an inbound webhook; a **parent
  signal** (`trigger.fire`); and — once Phase 3 lands — **a DB row appearing**
  (`db.insert` on a watched table). The DB-as-event-source is the elegant unifier:
  one orchestrator's `db.insert` result *is* the next agent's trigger, so the
  data-exchange spine and the trigger system are the same mechanism.
- **Activation.** A trigger wakes the child Connection with a prompt assembled from a
  task template + payload (same machinery as `delegate`, minus the awaiting caller).
  The run is tracked like any delegation (status, oracle verdicts), so a scheduled
  agent is just as observable + answerable as a delegated one.
- **Lifecycle (the questions to get right).** keep-warm vs. spawn-per-fire;
  **idempotency** (a fire that re-runs must not double-write — the DB schema/oracle is
  the backstop); **overlap** (a fire arriving while the prior run is in flight —
  coalesce, queue, or skip); **backpressure** (a hot event source must not spawn
  unboundedly — rate-limit + the resource guardrails below).
- **Safety coupling.** A standing agent is the highest-risk Node (it acts without a
  human in the immediate loop), so triggers are **only** as safe as the guardrails on
  the triggered child. Triggers and guardrails ship together.

**Child guardrails (defense in depth).** Three layers, cheapest/earliest first.
Together they bound *what a child can attempt*, *what it can emit*, and *how much it
can consume* — the safety the operator wants on autonomous children:

1. **Pre-action (permission policy).** GKSS already mediates ACP
   `request_permission`; for a child that becomes **policy-driven auto-decisioning**:
   a tool allowlist, cwd/path scope, capability mode (read-only/execute), no-network.
   The child *cannot* attempt a disallowed action — it's denied at the wire, not asked.
   This is the cheapest, strongest guardrail and rides infrastructure that exists.
2. **Pre-output (oracle gate).** Before a child's result propagates to the parent or
   the DB, its registered oracle runs; **violation → quarantine** (output blocked,
   human flagged, regenerate). This is the oracle engine above, applied to *child
   results*, not just cells.
3. **Resource caps.** Per-child token / turn / wall-clock budgets; **kill-on-breach**
   (grok exposes `kill_command_or_subagent`; a Connection is killable). Bounds runaway
   cost and loops — essential for standing/triggered agents.

The architectural guardrail underneath all three is **mediation** (§2.3): a child
never touches shared state or a peer directly — only through the Orchestration MCP —
so every action *is* interceptable, policy-checkable, and loggable. An oracle may
itself be a **separate Connection** (a judge agent doing runtime adversarial
verification), which composes with all of the above.

**UI (the console of the immune system).** The sidebar becomes the **orchestration
tree** (nesting). New surfaces: a **Run view** (the live delegation DAG + per-node
status + oracle verdicts), **oracle-violation / quarantine** flags inline and in a
dedicated list, the **DB inspector**, and per-Node **config** (role, prompt, tools,
capability, isolation). Reuse: watch-it-think (the thinking indicator), answer-its-
question (overlays + attention badge), grab-the-wheel (select any Node).

---

## 4. Phased roadmap (sequenced; each phase ships value)

This is a large build (now that the founder is **full-time**, faster — but still
substantial). The plan's real value is the sequence: each phase is independently
useful and de-risks the next, so you can stop after any phase with a strictly more
capable tool. **Still don't build it all at once** — but now for *learning and
focus*, not capacity: each phase should be **used** before the next is built, so the
design is shaped by reality and the oracle core stays small.

### Phase 1 — The tree + one real delegation *(the core loop; biggest unlock)*
- Add `role` + `parentID`; sidebar shows one level of nesting (orchestrator → children).
- Stand up the **Orchestration MCP server** with exactly **one** tool: `delegate(child, task)`.
- An orchestrator Node (real Connection, orchestrator role-prompt) calls `delegate`
  → router sends the task to a child Node → awaits its final answer → returns it.
- Watch both think live; answer either's questions (all existing UX).
- **No DB, no oracles yet.** This proves rung 3 end-to-end on today's stack and is
  the single highest-leverage milestone. Demoable.

### Phase 2 — Roles, prompts, tools, guardrails & optional isolation
- Orchestrator vs. agent **role prompts/config** (ride `10`'s rung-2 `.grok/`
  authoring; ship 2-3 templates: orchestrator, implementer-agent, reviewer-agent).
- Per-Node **tool set** (grant/scope *existing* tools — the first half of "create
  tools for the child"), **capability mode**, and **optional isolation** (own cwd /
  git worktree). Configurable in the Node settings via `node.configure`.
- **Pre-action guardrails** (guardrail layer 1) + **resource caps** (layer 3): policy-
  driven auto-decisioning over the ACP `request_permission` GKSS already mediates, plus
  per-child token/turn/time budgets with kill-on-breach. Cheap, rides existing
  infrastructure, and is the prerequisite for trusting triggered/standing agents.

### Phase 3 — Embedded DB + schemas + rigorous data exchange
- Embed SQLite; Orchestration MCP gains `db.createSchema`, `db.insert/query/update`.
- Orchestrators create task schemas; agents read inputs / write results through the
  DB → the **bidirectional, validated** exchange. Schema = the **first oracle**
  (malformed writes rejected). DB inspector in the UI.

### Phase 4 — The oracle engine *(the immune system)*
- `oracle.register` + `cell.submit`: agents submit scripts/functions; the engine
  runs the attached oracle; on violation it **flags + quarantines** the cell and
  triggers regeneration; the human is notified.
- Start with **cheap, objective** oracles (schema/shape/invariant/golden/recon).
  Oracle-violation + quarantine surfaces in the UI.
- This is where Grokestrator becomes genuinely novel — *agents kept honest by
  machine-checked contracts, with violations isolated, not propagated.*

### Phase 5 — Triggers, scale & robustness *(standing agents + homeostasis)*
- **Triggers / standing agents**: the host-local scheduler/event-bus. Cron + parent-
  signal triggers need only Phase 1's tree and can land as soon as Phase 2's guardrails
  make them safe; **DB-row triggers** unlock here because they need Phase 3's DB
  (`db.insert` on a watched table = the next agent's wake). This is the "run
  periodically or on an event" capability — gated on guardrails being in place.
- Multi-level trees; **parallel** delegation + result aggregation.
- **Homeostasis**: re-verification cadence, drift detection, retry/escalation policy,
  quarantine management.
- **Aggregate observability** (health of N nodes/cells, not N chats) — the
  dashboard for an immune system at scale.

---

## 5. Honest risks & guardrails (read before committing)

- **Scope is enormous.** Full-time makes it feasible, but sequencing is still the
  right discipline — now for **learning, focus, and an income clock**, not survival.
  **Phase 1 alone** (tree + one delegation) is a real, demoable platform and validates
  the whole thesis cheaply. Resist building Phases 3-5 before 1-2 are *used* — and
  remember there's no salary, so something that demos/earns sooner beats a perfect
  Phase 5 nobody's seen.

- **The oracle engine is the small must-be-correct core** — and the thing that has
  to be right (a broken oracle "heals toward wrong" confidently). Keep it small;
  build it with cathedral-grade care; keep everything it guards disposable.
- **Semantic oracles are unsolved** (`~/dev/AI/03 §A`). Scope Phase 4 to *cheap,
  objective* oracles. "Bounded, measured error rate" > "provably correct."
- **grok is a coding brain.** For coding orchestration it's ideal; for general
  (non-coding) orchestration the brain may need swapping later — **keep ACP as the
  generic wire** so the orchestrator/agent runtime isn't grok-locked.
- **Mediate everything.** The moment a Node writes shared state or calls a peer
  *without* going through the Orchestration MCP, you've created a coupling-contract
  and lost the ability to oracle-check it. The discipline *is* the architecture.
- **This is a separate concern from the SMB monetization bet** (`strategy-general-
  case-ai.md`). This platform serves the founder's own orchestration use first; it
  *could* later be the substrate that bet rides, but don't let that pull scope now.

---

## 6. Where the near-term UX items fit

Two small features were queued just before this pivot — they aren't lost; they're
*part of* the supervision UX this platform leans on harder than ever:

- **Busy / "thinking" indicator** — per-Node "watch it think" liveness. Directly
  useful in a tree (which nodes are active right now). Good **quick win, do
  before/with Phase 1**; surface it per-Node in the sidebar too.
- **Pretty markdown rendering in chat** — general polish; the orchestration views
  will render a lot of agent output, so it pays off more, not less. Quick win
  anytime.

---

## 7. First concrete steps (the literal next PRs)

1. **Model:** add `role` + `parentID` to `ManagedConnection` / `InstanceItem`
   (+ persistence); render one level of sidebar nesting. *(No behavior yet — pure
   model + UI.)*
2. **Orchestration MCP, v0:** an in-app http MCP server (model `MediaHTTPServer`)
   exposing only `delegate(child, task)`; auto-register it into each Node's `.grok/`
   MCP config.
3. **Router, v0:** route `delegate` → child Node prompt → await final answer →
   return. Track a minimal Run. Land Phase 1.
4. *(Quick wins in parallel:)* the thinking indicator; markdown rendering.

---

## 7b. The brain is swappable (model-agnostic Nodes)

A Node's LLM is a **swappable brain**; this platform is the **body** — it decides what
the brain may *do*, executes it, observes it, and coordinates many brains. The brain
can be grok, an OpenAI-compatible host (Groq, Cerebras, local llama.cpp/Ollama),
Gemini, or onboard. Two choices here already enable this: coordination lives in the
app (the `delegate` tool, not grok-native subagents), and capabilities are enforced at
our boundary (granted tools + per-action gating), not by trusting the model. The seam
is `AgentSession` (the ~10-method contract `GrokBuildConversation` already uses) with
`ACPEvent` as the universal event language: grok speaks it natively, other backends
synthesize it. This promotes the "keep ACP generic so the runtime isn't grok-locked"
footnote to a first-class plan — see **`12-model-agnostic-runtime.md`** for the seam,
capability model, and phased roadmap (Phase A: formalize the seam; Phase B: an
OpenAI-compatible backend — the 80/20 unlock).

## 8. Relationship to other documents

- `10-agent-orchestration.md` — this **commits to and extends rung 3**; the rungs
  there (attention cue ✅, surfacing, config GUI) are the on-ramp.
- `~/dev/AI/01-ai-native-software-architecture.md` — the **immune-system / oracle**
  thesis this operationalizes (oracles, detect-and-repair, mediated contracts, the
  small durable core).
- `00-vision-and-north-star.md` — supervision UX as the asset; this is its most
  ambitious expression.
- `strategy-general-case-ai.md` — kept **separate**; this platform is not the SMB
  product, though it may one day underpin it.
- `connection-semantics` (memory) — preserved: 1:1 Connection, no nested chats; the
  tree is a soft `parentID` edge.

---

*Created 2026-06-05. Revised 2026-06-09: added **Triggers / standing agents** (push
activation — cron/event/DB-row, the "run periodically or on an event" capability) and
**child guardrails as defense in depth** (pre-action permission policy → pre-output
oracle gate → resource caps); clarified tool provisioning as **both, sequenced**
(grant existing in Phase 2, synthesize oracle-gated cells in Phase 4+). Status:
implementation plan; not yet started. Phase 1 (tree + one delegation) is the first
milestone and the biggest single unlock.*
