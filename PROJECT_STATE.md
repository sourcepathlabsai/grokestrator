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

**Current focus**: Grok Build communication layer (black box) on the Mac. Core foundation complete. Mac hybrid app + real `grok` process management in progress.

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

**Grok Build Integration Layer** (current work on `feat/mac-grok-build-plumbing`)
- Full black-box communication layer for real `grok` build instances via the Agent Client Protocol (ACP) over stdio.
- `GrokBuildManager`: Primary facade. Owns instances, provides high-level conversation handles.
- `GrokBuildConversation`: The main black-box object callers use. Exposes:
  - `sendPrompt(...)` → `AsyncStream<ConversationUpdate>`
  - `sendPromptAndCollect(...)` → `PromptResult`
  - Structured progress/activity notes (the "little notes" from real agents)
  - `pendingToolCalls()` / `pendingPermissions()` + ergonomic response methods
  - Automatic history accumulation + file-based persistence
  - Lifecycle: `onDied`, `isAlive`, clean error states
- Supporting types: `ConversationUpdate`, `ToolCallInfo`, `PermissionRequestInfo`, `AgentConversationHistory`, `AgentTurn`/`AgentMessage`.
- `GrokBuildSessionClient` + `ACPMessageReader` handle raw ACP framing, request correlation, and event routing.
- Temporary raw ACP payload logging enabled for protocol discovery (marked clearly for removal).
- Process launching, monitoring, and death handling via `GrokBuildInstanceLauncher` + `GrokBuildServer`.
- All ACP details are encapsulated — the rest of the Mac app should only talk to `GrokBuildManager` and `GrokBuildConversation`.

- Current branch: `feat/mac-grok-build-plumbing`
- All work follows the strict "focused branch + logical PR" rule.

### Current State of Design Docs
- `06-project-structure.md`: Reflects the native structure (updated).
- `00-vision-and-north-star.md`: North Star and phasing still valid; technology notes updated for native pivot.
- `01-architecture-and-components.md` and `03-technology-and-build-strategy.md`: Marked historical (pre-pivot Tauri/Rust/Svelte direction that was evaluated and superseded).
- `PROJECT_STATE.md`: This file — now the live source of truth.

---

## Immediate Priorities
1. **Grok Build black box** (largely complete on current branch):
   - Production-ready `GrokBuildManager` + `GrokBuildConversation`
   - Full ACP handling + progress notes + history + lifecycle
2. GrokestratorMac target (hybrid client + server app) — UI shell, tabs, wiring the black box into real UI/ServerState.
3. Wire Core control-plane protocol + persistence into the Mac server for multi-device sync.
4. Basic iOS client shell (later).
5. Remove temporary raw ACP logging once protocol shapes are stable.
6. Continue living doc updates as decisions are made.

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

*Last updated: 2026-06-04 — Grok Build communication layer completed as production black box (GrokBuildManager + GrokBuildConversation + progress notes + history). Work on branch `feat/mac-grok-build-plumbing`.*