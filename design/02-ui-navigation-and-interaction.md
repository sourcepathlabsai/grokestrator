# Grokestrator — UI Navigation and Interaction Model

## Overview

This document describes the core navigation and interaction patterns for Grokestrator, with a strong emphasis on:

- High fidelity to the existing Grok Build console experience
- Minimal persistent chrome
- Reducing cognitive load when working with multiple Grok Build instances
- Keeping the main working surface clean and console-like

The design prioritizes **instance fidelity** — each connected Grok Build instance should feel like a distinct, powerful environment rather than a homogenized abstraction.

---

## Core Philosophy

- The main conversation area should feel as close as possible to the current TUI (thinking traces, tool calls, scrollback density, and general style).
- Grokestrator’s primary value is **orchestration and context management**, not reinventing the core interaction model.
- Chrome and persistent UI elements should be kept to a minimum. Information should be available on demand rather than always visible.
- The user should feel like they are “using the console, just through a better interface,” rather than using a completely new application.

---

## Left Sidebar — Hierarchical Navigation

The left sidebar is the primary navigation surface.

### Structure
- **Top level**: Connections (Grok Build instances)
- **Under each connection**: Conversations scoped to that specific instance

Example structure:
```
▼ Local Grok 1 (heavy MCPs)
    Conversation: Refactor auth system
    Conversation: Debug parser drift
▼ Local Grok 2 (clean research)
    Conversation: Design review notes
    Conversation: Query eval baseline
▼ Remote Neo (demo freeze)
    ...
```

### Behavior
- Connections can be expanded/collapsed to show their conversations.
- Selecting a conversation automatically selects its parent connection (the active instance).
- Selecting a connection (without a specific conversation) can either:
  - Show a list of its recent conversations, or
  - Start a new conversation in that instance.

This model makes the relationship between instances and their conversations explicit and reduces the feeling of “which console am I in?”

---

## Connection Identity and Naming

A core part of making multiple Grok Build instances usable in one application is giving them clear, human-friendly names.

### Approach

Grokestrator will use **client-side naming** as the primary mechanism:

- When a new connection is added (especially remote connections via Tailscale or similar), Grokestrator should **actively prompt** the user to name the connection.
- A reasonable default should be suggested automatically (examples: hostname, “Remote on <host>”, “Local Grok”, port-based names, etc.).
- Naming is **entirely optional**. The user can accept the suggested default or provide any name they prefer.
- The chosen name is stored locally within Grokestrator and used throughout the UI (sidebar, right panel, conversation headers, etc.).

This approach avoids forcing the user through any mandatory steps while still making it easy and natural to give instances meaningful names like “Alexander”, “Grokestrator”, or “Neo-Demo”.

### Future Enhancement

If Grok Build later gains the ability for an instance to advertise its own name (e.g. via a `--name` flag on `grok agent serve`), Grokestrator should be able to use the advertised name as the suggested default, while still allowing the user to override it locally.

---

## Main Conversation Area

The main pane is the highest-fidelity area and should preserve the console experience as much as possible:

- Rich rendering of thinking traces
- Tool calls and their results
- File diffs, command output, etc.
- General scrollback density and style

The goal is that the primary reading and interaction surface feels familiar to existing Grok Build users.

---

## Right Panel — Instance Inspector

A right-hand panel can be opened to inspect the currently selected instance in more detail.

### Content
The panel surfaces instance-specific information such as:
- Available slash commands
- Active MCP servers
- Loaded skills / personas
- Configuration details
- Other capabilities

### State Behavior (Current Decision)
- The right panel follows the current selection.
- When you switch instances, the panel (if open) remains open and repopulates with the new instance’s information.
- There is no per-instance memory of whether the panel was open or closed in the initial design.

This approach was chosen for predictability and simplicity. The panel acts as an “inspector” that reflects whatever instance is currently active.

Future evolution (e.g., pinning the panel per instance) can be considered after real usage.

### Opening the Panel
The panel is opened on demand rather than being persistently visible. Primary mechanisms:
- Clicking on a connection in the sidebar
- An explicit “Inspect” or “Details” action
- Potentially a slash command (e.g. `/capabilities`) as a fallback

---

## Hover Behavior

Hovering over a connection in the left sidebar provides lightweight, at-a-glance information.

- Hover content should be minimal and non-intrusive.
- The hover information disappears when the mouse leaves (no sticky behavior).
- Hover is intended for quick orientation, not deep inspection.

Deep details belong in the right panel or via slash commands.

---

## Discovery of Instance Capabilities

Because capabilities (MCP servers, skills, slash commands, etc.) can vary significantly between instances, discovery must be available but should not clutter the interface.

Preferred approaches (in rough priority):
1. Right panel (Instance Inspector) when the panel is open
2. Slash commands within the conversation (e.g. `/capabilities`)
3. Hover tooltips in the sidebar for very high-level signals

Persistent lists of every available capability across all instances are discouraged.

---

## Interaction Principles

| Principle                    | Description |
|-----------------------------|-----------|
| **High Fidelity**           | The main chat surface should feel like the console experience. |
| **Low Chrome**              | Minimize always-visible UI elements. Information on demand. |
| **Instance Fidelity**       | Each connection retains its own identity, tools, and behavior. |
| **Predictable Navigation**  | The sidebar makes it obvious which instance and conversation you are in. |
| **On-Demand Inspection**    | Deep instance details live in the right panel or via commands, not permanent UI. |
| **Follow Selection**        | The right panel (when open) reflects the currently active instance. |

---

## Agent Prompts (Questions & Permissions) — Out of Thread

The agent frequently needs a decision *from the user mid-turn*:
- **Permission requests** (ACP `session/request_permission`) — a set of options to choose (allow once / allow always / reject), often tied to a tool call.
- **Clarifying questions** — the agent asks the user something and offers likely answers, but the user may want to say something else.

**Decision:** these are **not rendered inline in the transcript**. Instead they appear in a **lightweight overlay anchored over the thread at the spot they occur** (a popover/callout near the relevant message), so the user can resolve them in place without the answer becoming a permanent, scroll-away transcript line.

### Behavior
- The overlay **lists the suggested answers/options as click targets** (the ACP `options`, or the agent's suggested replies).
- It always provides a **free-text override** — the user can type a custom answer instead of picking a suggestion.
- It is **modal to that prompt** (the turn is waiting on it) but visually a floating layer over the transcript, not a new row.
- Once answered, the overlay dismisses; a compact, non-intrusive record (e.g. "Approved: run X" / "Answered: …") may remain in the thread for history, but the *interaction* happens out of thread.
- Keyboard-friendly: options are selectable by key; the text field is focusable for an override.

### Why
Keeps the transcript clean and console-like (low chrome), keeps the *decision* visually distinct from the conversation flow, and matches how a user expects to be interrupted for a choice — a prompt at the point of action, not a buried message.

### Notes
- This is the home for the real permission UI that currently auto-approves inline (see the ACP client). It is also the mechanism for agent-initiated questions.
- Plumbing exists today: `ConversationUpdate.permissionRequested(PermissionRequestInfo)` carries the options; the client currently auto-approves. This overlay replaces auto-approve when implemented.

---

## Open Questions / Future Considerations

- Should the right panel support pinning or “keep open for this instance” behavior later?
- How should we handle visual differentiation between instances (icons, colors, short labels) without adding clutter?
- Will there be a need for a “global” view that shows activity across multiple instances simultaneously?
- How much instance metadata should be visible in the sidebar at a glance vs. only on hover?

---

## Relationship to Other Documents

This document focuses on navigation and surface-level interaction. Related documents:

- `00-vision-and-north-star.md` — Overall direction and phasing
- `01-architecture-and-components.md` (planned) — How the app connects to and manages instances
- `02-conversation-model.md` (planned) — How conversations are owned, scoped, and persisted

---

*Written: 2026-05-25*