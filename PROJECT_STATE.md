# Grokestrator — Project State

This file is the canonical snapshot of where Grokestrator stands right now.

Update this file when any of the following change:
- Architecture decisions
- Scope / phasing
- Active constraints
- Immediate next steps
- Major risks or open questions

---

## Current Position (2026-05-25)

**Grokestrator** is a native desktop application designed to be a comfortable, high-quality control plane for Grok Build agents.

**Current focus**: Phase 1 — Fully local experience on a single machine.

We are deliberately starting with a local-only MVP so we can rapidly iterate on the actual user experience (sidebar, conversations, agent management, comfort) before adding the complexity of remote machines.

The long-term North Star remains: one comfortable UI to fluidly direct and orchestrate many Grok Build agents (local and remote) as if they were one coherent system.

### Key Decisions Made
- Local-first approach (single machine, one or more local `grok` agents)
- Remote/multi-machine support (via Tailscale + ACP) is Phase 2
- Strong emphasis on local conversation history ownership
- Use ACP (`grok agent serve` and stdio) as the integration point with Grok Build
- Follow Alexander-style process: design docs in `design/`, GitHub issues as source of truth, `PROJECT_STATE.md` for current reality

### Current State
- Project directory created at `~/dev/grokestrator/`
- Design documents completed:
  - `00-vision-and-north-star.md`
  - `01-architecture-and-components.md`
  - `02-ui-navigation-and-interaction.md`
  - `03-technology-and-build-strategy.md` (Svelte + Tauri + Rust backend locked for Mac-first)
  - `04-conversation-model.md`
  - `05-data-persistence-model.md`
- Tech stack locked: Tauri 2 (Rust backend + Svelte frontend), macOS-first
- Persistence approach decided: Start with simple file-based storage (JSON + directory structure). SQLite deferred unless full-text search or complex queries become real requirements.
- Design process active and well advanced

---

## What Is Working / Exists

- Strong North Star defined
- Local-first phased approach agreed
- Four core design documents written and aligned:
  - Vision & North Star
  - UI/Navigation & Interaction Model
  - Technology & Build Strategy (Svelte + Tauri + Rust locked)
  - Conversation Model
- Design documentation process established (following Alexander patterns)
- `gh` CLI is authenticated as `bobprofleet`

---

## Immediate Priorities (Pre-Go)

1. Create GitHub repo (`bobprofleet/grokestrator`) if desired (low effort)
2. Final light review / polish of the design docs (optional but recommended before "go")

Most major design work is now complete. The remaining work is lightweight.

---

## Open Questions (Pre-Go)

- Final project name (still a placeholder)
- Exact scope boundary between MVP and MVD (particularly around multi-instance conversations) — to be clarified during early implementation if needed

---

## Non-Goals (Current Phase)

- Remote agent connections
- Multi-machine orchestration
- Public demos or sharing
- Polished visual design (focus on experience and structure first)

---

## Tracking

- Design documents: `~/dev/grokestrator/design/`
- Work tracking: GitHub Issues (to be established)
- This file (`PROJECT_STATE.md`) is the single source of current truth

---

## Next Steps (Pre-Go Work)

- (Optional but recommended) Light final review of all design docs
- Create GitHub repo (`bobprofleet/grokestrator`) for tracking and eventual visibility play
- Declare "go" and begin implementation

Target: Move quickly into coding with the goal of delivering a usable MVD, then MVP shortly after.

---

*Last updated: 2026-05-25*