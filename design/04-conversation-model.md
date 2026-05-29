# Grokestrator — Conversation Model

## Overview

This document defines how conversations are modeled, scoped, and managed in Grokestrator. It is one of the foundational design documents because many UI, state, and architecture decisions flow from how conversations relate to Grok Build instances.

The model prioritizes:
- High fidelity to the existing Grok Build console experience
- Strong instance fidelity (each connection retains its own capabilities and behavior)
- Low cognitive load when working with multiple instances
- Practical scoping decisions that protect speed of delivery

---

## Core Principles

- A conversation in Grokestrator is the primary unit of user work and history.
- Conversations are strongly associated with specific Grok Build instances (connections).
- The model should feel like using the console, just with better orchestration and context management.
- History and context should survive switching between Grokestrator and the underlying instance.
- We will design for future power while keeping the initial scope focused.

---

## Relationship Between Conversations and Instances

### Current Position (MVP)

- Each conversation is tied to one active Grok Build instance at a time.
- Switching an existing conversation to a different instance is **not** part of the MVP. It is considered a nice-to-have for later.

### Rationale

Allowing free movement of conversations between instances adds significant complexity in both the model and the UI. Given the priority on speed of delivery for the initial version, this is deferred.

The underlying model will be designed in a way that does not make this future capability unnecessarily difficult.

---

## History and Context Ownership

### Current Position

Grokestrator will support a **hybrid model**:

- Conversation history is owned and persisted by Grokestrator.
- The user should be able to switch cleanly between the Grokestrator interface and the underlying Grok Build instance without losing context or history.

This means:
- When working inside Grokestrator, the user sees the full conversation history managed by the app.
- When the user interacts directly with a Grok Build instance (if they choose to), they should not experience loss of prior context.

The goal is fluid movement between the orchestrator layer and the agent layer without friction or data loss.

---

## Instance-Specific Capabilities

Each Grok Build instance can have its own set of:
- Slash commands
- MCP servers
- Skills / personas
- Other configuration and extensions

### Current Position

Access to these capabilities should be **as seamless as possible** within the context of the active instance.

Some friction is acceptable in the early versions, especially around remote instances, until Grok Build itself improves remote support.

Discovery of what is available on a given instance will primarily happen through:
- The right-side Instance Inspector panel (when open)
- Direct slash commands (e.g. `/capabilities`)
- Lightweight hover information in the sidebar

Persistent global lists of capabilities across all instances are discouraged in favor of on-demand access.

---

## Multi-Instance Conversations

### Current Position

The Conversation Model will be **designed to be capable** of supporting multi-instance conversations in the future.

However, the actual feature (allowing a single conversation to actively use multiple Grok Build instances, either sequentially or in parallel) will be **held until at least the Min Viable Demo (MVD)** stage.

This capability is viewed as powerful and potentially impressive (e.g., one instance handling UI work while another handles backend work on the same project). It is explicitly recognized as a valuable direction, but it is not in scope for the initial MVP.

---

## Persistence and State Restoration

### Current Position

Restarting Grokestrator should bring the user back to where they left off.

This includes:
- Reconnecting to previously active instances (where possible)
- Restoring open conversations
- Restoring the last active instance and conversation context

Strong state restoration is considered a core part of delivering a comfortable, low-friction experience.

---

## Open Questions

- How should context be passed when a user switches from Grokestrator into direct interaction with an instance?
- What level of UI support (if any) for multi-instance conversations should be considered even for the MVD?
- How should conversation titles and metadata be managed when an instance has its own internal history mechanisms?

---

## Relationship to Other Documents

- `00-vision-and-north-star.md`: Establishes the overall vision and local-first phasing.
- `02-ui-navigation-and-interaction.md`: Defines the sidebar hierarchy (Connections > Conversations) and right panel behavior.
- `05-data-persistence-model.md`: How conversation history is stored on disk.
- `06-project-structure.md`: Where the conversation/history model code lives in the repo.

---

*Created: 2026-05-25*