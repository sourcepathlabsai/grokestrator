# Grokestrator — Project State

This file is the canonical snapshot of where Grokestrator stands right now.

Update this file when any of the following change:
- Architecture decisions
- Scope / phasing
- Active constraints
- Immediate next steps
- Major risks or open questions

---

## Current Position (2026-05-26)

**Grokestrator** is a native macOS + iOS application (Swift + SwiftUI) that acts as a high-quality control plane for orchestrating multiple Grok Build agents across devices.

**Mac app**: Hybrid — runs both the client UI *and* the server. The powerful stationary dev Mac owns:
- Direct lifecycle management of `grok` instances (launch, monitor, auto-restart on boot/crash — no tmux in v1)
- Conversation history and persistence
- Coordination for local UI + remote clients (iOS / other Macs over Tailscale)

**iOS app**: Client-only. Enables seamless experience including voice interaction while driving or away from the desk.

**Current focus**: Core foundation complete. Moving to Mac hybrid app target + actual server process management.

The long-term North Star remains: one comfortable interface to fluidly direct and orchestrate many Grok Build agents (local and remote) as if they were one coherent system.

### Key Decisions Made
- **Native Swift + SwiftUI** (Mac hybrid + iOS client) after evaluation of Tauri/Rust path. Chosen for true iOS client support, seamless multi-device (Tailscale), and avoiding local stdio + sandbox limitations.
- Mac server owns everything (instance lifecycle, persistence, client sessions).
- Direct `Process` management of `grok` binaries on the Mac (auto-restart, no tmux in MVP).
- Multi-server support via tabs (Mac) / panes (iOS).
- Strict branch → focused logical PR → merge discipline (no giant messy commits).
- GrokestratorCore (Swift Package) as the single source of truth for models, protocol, persistence, and shared logic.
- File-based persistence (JSON) for MVP, implemented and tested in Core.
- Explicit control-plane protocol (`GrokestratorProtocol`) between clients and the server component.

### What Exists Now (Post Core Foundation Commit)
- `Packages/GrokestratorCore/` — Fully implemented and building:
  - **Models**: ServerAddress (Tailscale + port), Conversation, Message, Agent, ConnectionState, ServerInfo, ManagedInstance, ServerConfiguration, ClientConfiguration.
  - **Networking**: GrokestratorTransport protocol, Connection, full GrokestratorProtocol (request/response/event shapes for the control plane).
  - **Client**: MultiServerSession, ClientConfiguration (multi-server/tab support).
  - **Server**: ServerState, ServerConfiguration (instance management data model).
  - **Persistence**: PersistenceProtocol + FilePersistence actor (JSON, actor-isolated, ready for app support containers).
  - **Common**: GrokestratorError.
  - Tests: 6 passing tests (models + persistence roundtrips).
- Branch: `feat/initial-core-package-structure`
- Commit: `cdb9a24` — clean, focused Core foundation (786 insertions).
- Design docs in `design/` (being brought current in this pass).
- All work follows the "create branch before any code + logical PR chunks" rule.

### Current State of Design Docs
- `06-project-structure.md`: Reflects the native structure (updated).
- `00-vision-and-north-star.md`: North Star and phasing still valid; technology notes updated for native pivot.
- `01-architecture-and-components.md` and `03-technology-and-build-strategy.md`: Marked historical (pre-pivot Tauri/Rust/Svelte direction that was evaluated and superseded).
- `PROJECT_STATE.md`: This file — now the live source of truth.

---

## Immediate Priorities
1. GrokestratorMac target (hybrid client + server app) — direct process management, UI shell, tabs for multiple servers.
2. Wire the Core protocol + persistence into the Mac server.
3. Basic iOS client shell (later).
4. Continue living doc updates as decisions are made.

---

## Non-Goals (Current Phase)
- Remote agent connections beyond Tailscale client access to the home Mac server (full multi-machine orchestration is later).
- Windows/Linux as primary platforms.
- Public release or open source.
- Polished visual design (structure and experience first).

---

## Tracking
- Design documents: `design/`
- Work tracking: GitHub Issues (to be established)
- This file (`PROJECT_STATE.md`) is the single source of current truth
- Strict process: Every chunk of work happens on a focused branch and lands via logical PR.

---

*Last updated: 2026-05-26 — Core foundation implemented and committed. Native Swift architecture locked in after pivot.*