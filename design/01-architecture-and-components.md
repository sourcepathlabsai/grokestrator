# Grokestrator — Architecture and Components (Phase 1)

## Overview

This document describes the high-level architecture and major components for the initial Mac-first version of Grokestrator.

The architecture is designed to support the principles established in the other design documents:
- High fidelity to the Grok Build console experience
- Strong instance fidelity
- Low persistent chrome
- Fast iteration and delivery
- Clean boundaries to enable future extension (including multi-instance conversations and remote support)

## Guiding Principles for the Architecture

- The Rust layer owns all orchestration, connection management, and privileged operations.
- The Svelte frontend owns presentation and user interaction.
- Communication between layers is explicit and narrow (via Tauri's command system).
- The design should allow us to move quickly on a high-quality Mac MVP while leaving doors open for later work.
- Complexity is pushed down where possible (especially around multi-instance conversations, which are deferred past MVP).

## High-Level Architecture

```
+-----------------------------+
|        Svelte Frontend      |
|  (UI, Stores, Commands)     |
+-------------+---------------+
              | Tauri IPC (commands + events)
+-------------v---------------+
|       Rust Backend          |
|  (Tauri App + Orchestrator) |
|                             |
|  +------------------------+ |
|  |  Connection Manager    | |
|  +------------------------+ |
|  |  ACP Client Layer      | |
|  +------------------------+ |
|  |  State & Persistence   | |
|  +------------------------+ |
|  |  Instance Registry     | |
|  +------------------------+ |
+-----------------------------+
              |
    Local Grok instances (stdio)  +  Remote instances (WebSocket via Tailscale)
```

**Layers**:

1. **Svelte Frontend** — Presentation layer only. No direct knowledge of ACP or process management.
2. **Rust Backend (Tauri)** — The core of the application. Owns all connections, state, and orchestration logic.
3. **Grok Build Instances** — External processes (local or remote). Grokestrator is a client to them via ACP.

## Major Components

### 1. Rust Orchestration Layer (Core)

**Responsibilities**:
- Manage the lifecycle of multiple Grok Build connections (local and, later, remote).
- Maintain a registry of active instances.
- Route user actions (prompts, commands) to the correct instance.
- Handle incoming ACP updates and forward them to the frontend.
- Own all persistence decisions.
- Enforce instance isolation where appropriate.

**Key Sub-components** (to be detailed during implementation):
- `ConnectionManager`
- `InstanceRegistry`
- `AcpClient` (wrapper around the `agent-client-protocol` crate)
- `State` (in-memory representation of connections + conversations)
- `Persistence` layer

### 2. ACP Integration Layer

- Uses the official Rust ACP client library (`agent-client-protocol`).
- Supports both stdio transport (for local `grok` processes) and WebSocket transport (for `grok agent serve` instances, local or remote).
- Responsible for:
  - Session creation / loading
  - Streaming `session/update` events (messages, thoughts, tool calls)
  - Handling permission requests
  - Sending user prompts and slash commands

### 3. Svelte Frontend

**High-level component structure** (initial view):

- `App.svelte`
  - `Sidebar`
    - `ConnectionList`
    - `ConversationList` (per connection)
  - `MainConversationView`
    - Rich rendering area (high fidelity to TUI output)
    - Input area
  - `RightPanel` (Instance Inspector) — follows current selection
- Stores (Svelte 5 runes or stores):
  - `connections`
  - `activeConnection`
  - `conversations`
  - `activeConversation`

**Communication with Rust**:
- All backend interaction happens through Tauri's `invoke()` for commands and event listeners for streaming updates.
- The frontend should remain as "dumb" as reasonable — it renders state and sends user intent.

### 4. Persistence Layer

**Current open question** (see PROJECT_STATE.md):
- Do we need SQLite for concrete value (e.g., full-text search across conversations)?
- Or is a simpler file-based approach (JSON + directory structure) sufficient for MVP/MVD?

This decision should be made before or early in implementation.

## Connection Management

- Each "Connection" in the UI represents one Grok Build instance (local or remote).
- Connections have stable identifiers and user-assigned friendly names (client-side).
- The Rust side maintains open ACP sessions where possible.
- Local instances may be started on demand or connected to existing processes.

## State Management

- The Rust backend is the source of truth for all application state.
- The Svelte frontend holds a synchronized view (via commands + events).
- Conversations and their messages are the primary persistent units.

## Key Boundaries & Invariants

- The frontend never talks directly to Grok Build instances.
- All ACP protocol knowledge lives in the Rust layer.
- Instance-specific capabilities (slash commands, MCPs, skills) are discovered through the active connection.
- Multi-instance conversations are explicitly out of scope for the initial implementation (model should allow for it later).

## What This Architecture Enables

- Fast iteration on the Mac UI (Svelte side).
- Strong isolation and control over agent connections (Rust side).
- Clear path for future remote support and multi-instance work.
- Good testability of the orchestration logic.

## Open Questions / Items to Resolve Before or During Early Implementation

- Exact persistence strategy (SQLite vs. simpler storage).
- Level of abstraction between Rust and Svelte (how much state is pushed to the frontend).
- Error handling and connection recovery strategy.
- How slash commands and instance-specific features are presented in the UI.

## Relationship to Other Documents

- `00-vision-and-north-star.md`: Provides the overall goals and phasing.
- `02-ui-navigation-and-interaction.md`: Defines the user-facing patterns this architecture must support.
- `03-technology-and-build-strategy.md`: Justifies the Tauri + Rust + Svelte choice.
- `04-conversation-model.md`: Defines the conceptual model this architecture must implement.

---

*Created: 2026-05-25*  
*Status: Lightweight draft — sufficient to support early implementation.*