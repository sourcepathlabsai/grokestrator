# Grokestrator — Project State

This file is the canonical snapshot of where Grokestrator stands right now.

Update this file when any of the following change:
- Architecture decisions
- Scope / phasing
- Active constraints
- Immediate next steps
- Major risks or open questions

---

## Current Position (2026-06-04)

**Grokestrator** is a native macOS + iOS application (Swift + SwiftUI) that acts as a high-quality control plane for orchestrating multiple Grok Build agents across devices.

**Mac app**: Hybrid — runs both the client UI *and* the server. The powerful stationary dev Mac owns:
- Direct lifecycle management of `grok` instances (launch, monitor, auto-restart on boot/crash — no tmux in v1)
- Conversation history and persistence
- Coordination for local UI + remote clients (iOS / other Macs over Tailscale)

**iOS app**: Client-only. Enables seamless experience including voice interaction while driving or away from the desk.

**Current focus**: Client control-plane protocol and shared client comms layer in GrokestratorCore (to allow iOS and Mac clients to drive the remote Grok Build black box over Tailscale). Grok Build black box on the Mac is complete.

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

### What Exists Now

**Core (GrokestratorCore package)**
- Fully implemented and building (see previous state for details).
- Branch: `feat/initial-core-package-structure` (merged).

**Grok Build Integration Layer** (completed on `feat/mac-grok-build-plumbing`, merged in PR #4)
- Full black-box communication layer for real `grok` build instances via the Agent Client Protocol (ACP) over stdio.
- `GrokBuildManager` and `GrokBuildConversation` as the stable high-level API (no raw ACP leakage).
- Rich `ConversationUpdate` support including progress/activity notes.
- Tool and permission roundtrips, structured history (`AgentTurn`/`AgentMessage`), lifecycle management.
- All ACP details encapsulated.

**Client Control Plane & Shared Client Comms Layer** (current work on `feat/core-client-control-plane`)
- Evolving the control-plane protocol (`GrokestratorProtocol`) so clients can drive remote Grok Build instances with high fidelity.
- `GrokestratorClient`: Top-level actor for managing server connections and higher-level sessions.
- `GrokBuildClientSession`: Higher-level client abstraction (remote equivalent of `GrokBuildConversation`).
- `InMemoryGrokestratorTransport` for testing the client flow end-to-end.
- Rich model types (`ConversationUpdate`, `AgentTurn`, `ToolCallInfo`, etc.) promoted into Core.
- Design document: `design/07-client-control-plane-protocol.md` (v0.1 reviewed + decisions locked).
- Focus on prompt streaming, tool roundtrips, event routing, and connection lifecycle.

- Current branch: `feat/core-client-control-plane`
- All work follows the strict "focused branch + logical PR" rule.

### Current State of Design Docs
- `06-project-structure.md`: Reflects the native structure (updated).
- `07-client-control-plane-protocol.md`: New design doc for the client-side control plane evolution (v0.1 reviewed, key decisions locked).
- `00-vision-and-north-star.md`: North Star and phasing still valid.
- `01-architecture-and-components.md` and `03-technology-and-build-strategy.md`: Marked historical.
- `PROJECT_STATE.md`: This file — now the live source of truth.

---

## Immediate Priorities
1. **Client Control Plane** (active on `feat/core-client-control-plane`):
   - Finish core client comms layer (`GrokestratorClient`, `GrokBuildClientSession`, protocol extensions).
   - Solidify prompt streaming, tool roundtrips, and event routing over the control plane.
   - Enable iOS + Mac clients to drive remote Grok Build instances.
2. GrokestratorMac target (hybrid client + server app) — UI shell, tabs, wiring the black box + client comms layer.
3. Server-side handling of new `GrokBuildRequest` messages in the Mac app.
4. Basic iOS client shell that exercises the new remote Grok Build sessions.
5. Continue living doc updates (`design/07-client-control-plane-protocol.md` and this file).

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

*Last updated: 2026-06-04 — Client control plane work active on `feat/core-client-control-plane`:
- `GrokestratorClient`, `GrokBuildClientSession`, `InMemoryGrokestratorTransport`, and protocol extensions in progress.
- Rich conversation models promoted into Core.
- In-memory transport + end-to-end tests for prompt flow.
- Design doc `07-client-control-plane-protocol.md` maintained.
- `PROJECT_STATE.md` updated.