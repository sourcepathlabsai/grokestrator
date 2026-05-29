# Grokestrator — Vision and North Star

## Project Name
**Working name**: Grokestrator (Grok + Orchestrator)

This is currently a placeholder. We can change it once the vision is solid.

---

## North Star

**A single comfortable native desktop application that lets one person fluidly direct and orchestrate many Grok Build agents — local and remote — as if they were one coherent system.**

The user should feel like they have one high-quality interface and one source of truth for context and history, while the actual thinking, tool use, and execution can happen on whichever machine (or set of machines) is most appropriate.

This is not "a nicer TUI" or "Grok in a window." It is a **control plane** for distributed Grok agents.

### Why This North Star Matters

The current state is painful for power users who want to use Grok seriously for development and research work:

- The TUI is powerful but uncomfortable for long sessions.
- Copy/paste between the web/app experience and local machines is unsustainable.
- People who run multiple machines (or want to) have no good way to coordinate privileged agents across them.
- Valuable conversation history and context is scattered across machines and sessions.

The goal is to remove the friction so that the limiting factor becomes the quality of the underlying Grok models and the user's own thinking — not the interface or the logistics of managing multiple agents.

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

- The user has a day job. Work happens in focused early morning blocks.
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

*Created: 2026-05-25.*