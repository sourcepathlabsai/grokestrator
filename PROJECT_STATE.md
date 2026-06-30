# Grokestrator — Project State

Canonical snapshot of where Grokestrator stands **right now**. Update when
architecture, phasing, shipped scope, or immediate priorities change.

**Tracking:** actionable work → [GitHub Issues](https://github.com/sourcepathlabsai/grokestrator/issues)
(milestone: **Canonical Backlog**). This file is the narrative snapshot; issues are the task queue.

---

## Current Position (2026-06-30)

**Grokestrator** is a native macOS + iOS application (Swift 6 + SwiftUI) that supervises
and orchestrates agent sessions — grok, Claude Code, and OpenAI-compatible API brains —
across devices over Tailscale.

| Layer | Role |
|-------|------|
| **GrokestratorMac** | Hybrid: UI + GKSS server + agent lifecycle + Orchestration MCP |
| **GrokestratoriOS** | Client-only remote companion |
| **GrokestratorCore** | Models, wire protocol, persistence, governance engine |

**Release:** v0.3.0-alpha (2026-06-30). Prior: v0.2.0-alpha (2026-05-31).  
**Engineering:** 153+ merged PRs; Core tests: 42/42 passing.

**Founder full-time** since 2026-06-05. Binding constraints: **sequencing, validation**, and
doc/corpus accuracy (OODA Orient axis) — not capacity.

### Product direction (unchanged since 2026-06-01)

Two tracks, kept separate:

1. **Grokestrator** — free supervision + orchestration for founder + solo devs. Heart =
   observable, answerable, native supervision (any domain).
2. **General-case AI** (`design/strategy-general-case-ai.md`) — separate monetization bet;
   must not redefine the free tool.

Committed architecture: **dual-path orchestration** (revised 2026-06-30):
- **ACP agents** (grok, Claude Code): harness subagents; Grokestrator supervises the
  parent (`10` rungs 0–2). No Grokestrator sub-sessions on these brains.
- **API/local brains**: **orchestrated fleet** — `parentID` tree + app-side
  `delegate` MCP (`10` orchestrated fleet, `11`).

**Agent operating doctrine:** OODA helix mandatory (`AGENTS.md` §0). Orient on this file +
`design/` + `design/oracle/` before substantial work.

---

## What Is Shipped

### Supervision UX (north star — mature for alpha)

- Mac hybrid + iOS client over Tailscale; live multi-device mirroring
- Token streaming, permission/question overlays, structured questions, plan checklist
- Multimodal inline; virtualized transcript; selectable/copyable messages
- Prompt queue during streaming (#125); file drag-and-drop (#126)
- Concurrent permission queue (#117); attention badges + Dock bounce (#149)
- Instance inspector; persistence + archive; transcript accumulators (#127)
- Mac code signing stabilized (#114)

### Model-agnostic runtime (`design/12` Phases A–C, E, F)

- `AgentSession` seam; `GrokBuildSessionClient` + `OpenAICompatSession`
- Brain catalog, tier map, per-Node brain/tools editors, host-local API keys
- Groq, Cerebras, Gemini, xAI; ACP Agent (grok, Claude Code, custom)
- MCP registry + per-Node grants; in-app MCP client for API brains
- `AutoApproval` for unattended delegation

### Orchestration platform (`design/11` Phase 1–2) — orchestrated fleet

- `role` + `parentID` tree; `OrchestrationMCPServer` + enriched `delegate`
- Team templates: Code Review, Implementation, Research (#124) — **intended for
  API/local brains**; ACP path not yet gated in UI/logic
- Per-Node role prompts, tool policy; live child transcripts during delegation

### Design oracle (`design/13` runtime slices 1–3)

- `design/oracle/invariants/` — three active invariants
- Shadow → persist → orient-on-read → active enforcement
- `OracleLedger` → `oracle-verdicts.jsonl`; inspector verdicts
- ACP permission verb mapping for Claude/non-grok brains (#153)

---

## What Is Not Shipped

| Area | Status | Reference |
|------|--------|-----------|
| First-class verb normalization layer | Open (#154) | `GovernanceEngine` adapters today |
| Dual-path orchestration enforcement (UI + logic) | Not built (#158 epic, #159–#167) | `design/10` §0, `11` §0 |
| Rung 1 — grok-native subagent surfacing (ACP path) | Not built (#131) | `design/10` |
| Rung 2 — `.grok/` config GUI (ACP path) | Partial (#132) | `TeamTemplate` only |
| Orchestration Phase 3 — SQLite | **Parked** (#133) | `feat/orchestration-db` |
| Run/DAG view | Not built (#134) | `design/11` |
| Oracle depth (verify-against-intent, corpus maintenance) | Open (#141–#142) | `design/13` |
| Signed/notarized Mac + TestFlight | Roadmap (#143) | README |

---

## Implementation vs. Design Doc Headers

| Doc | Header may say | Reality (2026-06-30) |
|-----|----------------|----------------------|
| `design/10` | "not implemented" | Rung 0 ✅, rung 3 substantially ✅ |
| `design/11` | "not started" | Phase 1–2 largely ✅ |
| `design/12` | "not started" | Phases A–C, E, F ✅ |
| `design/13` | "thesis only" | Runtime slices 1–3 ✅ |

**This file** and `RELEASE_NOTES.md` are the operational truth for "where we are."

---

## Immediate Priorities

[milestone: Canonical Backlog](https://github.com/sourcepathlabsai/grokestrator/milestone/1)

| Priority | Issue | Topic |
|----------|-------|-------|
| 1 | [#158](https://github.com/sourcepathlabsai/grokestrator/issues/158) | Dual-path orchestration epic (#159–#167) |
| 2 | [#131](https://github.com/sourcepathlabsai/grokestrator/issues/131) | ACP path: surface harness subagent lineage |
| 3 | [#134](https://github.com/sourcepathlabsai/grokestrator/issues/134) | Fleet: Run view — delegation DAG + oracle verdicts |
| 4 | [#133](https://github.com/sourcepathlabsai/grokestrator/issues/133) | Fleet: SQLite Phase 3 (parked) |
| 5 | [#143](https://github.com/sourcepathlabsai/grokestrator/issues/143) | Signed/notarized Mac + TestFlight |
| — | [#130–#154](https://github.com/sourcepathlabsai/grokestrator/issues?q=is%3Aissue+milestone%3A%22Canonical+Backlog%22) | Full backlog |

---

## Key Architectural Decisions (standing)

- Native Swift + SwiftUI; GKSS (Mac server) is source of truth
- 1 Connection = 1 agent instance; tree = soft `parentID` edge
- ACP + `ACPEvent` universal wire; coordination in app (`delegate` MCP)
- Governance unit = `ProposedAction`; verb normalization at harness boundaries
- File-based JSON persistence; SQLite deferred to orchestration Phase 3
- Every slice → PR → merge gate (`AGENTS.md` §4)

---

## Tracking

| What | Where |
|------|-------|
| Strategic goals | Obsidian vault (`4-Concepts/`, project folder) |
| Design intent + invariants | `design/*.md`, `design/oracle/` |
| Operational snapshot | **This file** |
| Actionable tasks | GitHub Issues (Canonical Backlog) |
| Shipped user-facing changes | `RELEASE_NOTES.md` |

---

*Last updated: 2026-06-30 — through PR #153. Supersedes 2026-05-27 snapshot.*