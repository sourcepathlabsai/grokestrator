# Grokestrator — Vision and North Star

## Project Name
**Working name**: Grokestrator (Grok + Orchestrator)

This is currently a placeholder. We can change it once the vision is solid.

---

## North Star

**A single comfortable native application that lets one person direct and _supervise_ many Grok agents — across any domain, local and remote — as if they were one coherent system.**

The user should feel like they have one high-quality interface and one source of truth for context and history, while the actual thinking, tool use, and execution can happen on whichever agent (or machine) is most appropriate. Critically, they can **watch an agent think and answer its questions** — supervise the work — without dropping into a console.

This is not "a nicer TUI" or "Grok in a window." It is a **control plane for supervisable agent work** — Grok agents that happen to be excellent at coding, but are equally capable of running any multi-step job a person would otherwise do by hand.

### Who it's for — and the one thing kept deliberately separate

**Grokestrator is a free, focused tool for the founder and fellow solo devs / power users — "use it if you want."** Its heart is the **supervision UX**: watch agents think, answer their questions, and steer them across your devices, in a GUI instead of a terminal. It's general-purpose *for the individual* — drive it for coding or for any multi-step job you'd otherwise do by hand — but it is **not** a product aimed at non-technical operators, and it doesn't try to be. It has a real place exactly as that: a comfortable, observable cockpit for one technical person's fleet of agents.

**The commercial idea lives elsewhere, on purpose.** The genuinely novel, transferable asset here is the **supervision/approval control plane** — and there *is* a case for monetizing it as a general-case AI tool for non-technical operators (a winery manager who says "pull the POS numbers, reconcile, email me" and supervises without a console). But that is a **separate bet**: different architecture (hosted, not your-Mac-is-the-server), a single narrow vertical, a far higher reliability/trust bar, a different brain (grok is a *coding* agent), and a services-led business model. It must not be allowed to quietly redefine this free tool into an unfocused everything-platform. It is captured — kept apart but linked — in **`strategy-general-case-ai.md`**.

**Differentiator both share:** observable, answerable, _native_ supervision. You see agents think and answer their questions in a GUI — instead of an opaque terminal that only a developer can drive. For Grokestrator that's the daily-driver delight; for the separate bet it's the wedge.

**So, scope discipline:** Grokestrator's near-term north star is the **supervision UX itself** — proven on the founder's own developer work (the rung-0 attention cue + a minimal rung-3 observable, answerable child; see `10-agent-orchestration.md`). That slice is useful to solo devs on its own merits *and* is the live prototype of the strategy doc's interaction model. The broad consumer product is downstream of proving it, lives in `strategy-general-case-ai.md`, and is out of scope here.

### Why This North Star Matters

The current state is painful for power users who want to use Grok seriously (the broader non-technical-operator pain is the separate bet's, in `strategy-general-case-ai.md`):

- The TUI is powerful but uncomfortable for long sessions.
- Copy/paste between the web/app experience and local machines is unsustainable.
- People who run multiple machines (or want to) have no good way to coordinate privileged agents across them.
- When an agent delegates work, **what its workers are doing is opaque** — you can't watch a sub-task think or answer its question (see `10-agent-orchestration.md`).
- Valuable conversation history and context is scattered across machines and sessions.

The goal is to remove the friction so that the limiting factor becomes the quality of the underlying Grok models and the user's own thinking — not the interface, the logistics of managing multiple agents, or being able to read a terminal.

---

## Core Principle (The Alexander Lesson)

Once the AI has a clear, stable North Star, it can generate real, working components that actually move the system toward the goal instead of just producing locally coherent output.

Everything we design and build should be evaluable against this North Star.

---

## Phased Approach

We are deliberately taking a **local-first** approach.

### Phase 1: Local (Current Focus)
- Fully local native desktop application.
- Manages one or more local Grok Build instances on a single machine.
- Excellent conversation management, sidebar, history, and agent targeting within the local machine.
- Rapid iteration on the actual user experience.

### Phase 2: Remote & Multi-Machine (Later)
- Add support for connecting to remote Grok Build agents (via Tailscale + ACP).
- Sidebar shows both local and remote agents.
- Ability to orchestrate work across multiple machines from one UI.
- Conversation and context model must support remote agents cleanly.

**Rationale**: The quality of the local UI/UX experience is critical. We need to get that right through fast iteration before adding the complexity of remote sessions. The local work will inform better decisions when we expand to multiple machines.

---

## What Success Looks Like (Phase 1 MVP)

For the first meaningful version (Phase 1), success is:

- A native desktop app (macOS first) with a clean, comfortable UI.
- A sidebar that shows:
  - Conversations / threads (with local persistent storage on the user's machine)
  - Local Grok Build agents/instances available on the current machine
- Ability to have conversations that can target specific local agents or work across multiple local agents.
- All conversation history owned and stored locally by the Grokestrator app.
- The experience feels meaningfully better than living in the TUI or doing copy/paste.
- Strong foundation for adding remote agents later without major rewrites to the core model.

Phase 1 MVP does **not** need to include:
- Remote machine connections
- Tailscale integration
- Cross-machine orchestration
- Beautiful/polished visual design
- Public demos

---

## Key Constraints & Realities

- **Full-time as of 2026-06-05** (the founder left a long career at Adobe to focus on Grokestrator, `~/dev/alexander`, and AI consulting). Capacity is no longer the binding constraint — the new realities are a **runway with an income clock** (no salary, so work that validates/earns sooner is favored) and the founder's own focus, not available hours.
- We will not rush to show this to other people. Demos are only valuable when we are close to a real MVP.
- The underlying power comes from existing `grok` agents running on each machine. Grokestrator is primarily the orchestration and experience layer on top.
- Conversation history and extended context should be a first-class strength of the system.
- We are using ACP (`grok agent serve` / stdio) as the integration mechanism with Grok Build agents.

---

## Non-Goals (for now)

- Building a new model or inference engine
- Replacing the core `grok` CLI/TUI/agent (we build on top of it)
- Supporting Windows or Linux as primary platforms in the first version
- Enterprise multi-user features
- Public release or open source (unless explicitly decided later)
- Remote/multi-machine support in Phase 1

---

## Next Documents Planned

- `PROJECT_STATE.md` (root of the project)
- 01-architecture-and-components.md (local-first)
- 02-conversation-model.md (local version — how conversations and local agents relate)
- 03-user-experience-principles.md
- 04-mvp-scope-and-phasing.md
- Future: Remote connection model, multi-machine orchestration, etc.

---

*Created: 2026-05-25. Revised 2026-06-01: positioned Grokestrator as a **free, focused tool for the founder + solo devs** whose heart is the supervision UX (observable, answerable agents in a GUI, any domain, across devices). The general-case "agentic AI for the rest of us" was split out as a **separate, linked monetization bet** in `strategy-general-case-ai.md` (different architecture/brain/business model) so it can't redefine the free tool. Orchestration path in `10-agent-orchestration.md`.*