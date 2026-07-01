# Grokestrator — Project State

Canonical snapshot of where Grokestrator stands **right now**. Update when
architecture, phasing, shipped scope, or immediate priorities change.

**Tracking:** actionable work → [GitHub Issues](https://github.com/sourcepathlabsai/grokestrator/issues)
(milestone: **Canonical Backlog**). This file is the narrative snapshot; issues are the task queue.

---

## Current Position (2026-07-01)

**Grokestrator** is a native macOS + iOS application (Swift 6 + SwiftUI) that supervises
and orchestrates agent sessions — grok, Claude Code, and OpenAI-compatible API brains —
across devices over Tailscale.

| Layer | Role |
|-------|------|
| **GrokestratorMac** | Hybrid: UI + GKSS server + agent lifecycle + Orchestration MCP |
| **GrokestratoriOS** | Client-only remote companion |
| **GrokestratorCore** | Models, wire protocol, persistence, governance engine |

**Release:** v0.3.1-alpha (2026-07-01). Prior: v0.3.0-alpha (2026-06-30).  
**Engineering:** 175+ merged PRs; Core tests: 71/71 passing.

**Founder full-time** since 2026-06-05. Binding constraints: **sequencing, validation**, and
doc/corpus accuracy (OODA Orient axis) — not capacity.

### Product direction (unchanged since 2026-06-01)

Two tracks, kept separate:

1. **Grokestrator** — free supervision + orchestration for founder + solo devs. Heart =
   observable, answerable, native supervision (any domain).
2. **General-case AI** (`design/strategy-general-case-ai.md`) — separate monetization bet;
   must not redefine the free tool.

Shipped architecture: **dual-path orchestration** (revised 2026-06-30, implemented 2026-07-01):
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

### Orchestration platform (`design/11` Phase 1–3) — dual-path

- `OrchestrationMode` — ACP supervision vs orchestrated fleet; UI + logic gated (#158)
- `role` + `parentID` tree; `OrchestrationMCPServer` + enriched `delegate`
- Team templates: Code Review, Implementation, Research (#124) — fleet/API brains only
- Per-Node role prompts, tool policy; live child transcripts during delegation
- Run view — delegation DAG + active runs in sidebar (#134)
- Orchestration Phase 3 — embedded SQLite + `db.*` MCP tools (#133)
- Verb normalization layer at harness boundaries (#154)

### Dual-path ACP path (`design/10` rungs 1–2, epic #158)

- Rung 1 — harness subagent lineage surfaced in transcript tool groups (#131)
- Rung 2 — `.grok/` config GUI: `GrokConfigEditorView`, `GrokConfigWriter`, sidebar
  **Grok Config…** entry (#132)

### Team template editors (#172, #174)

- **Fleet:** `TeamTemplateEditorView` — Settings → Teams; create/edit custom fleet
  templates with grok-assisted prompt drafting (#173)
- **Harness/ACP:** `GrokHarnessTemplate`, `HarnessTemplateRegistry`,
  `HarnessTemplateEditorView` — Settings → Teams Harness section; grok-assisted
  agent/role/persona drafting (#175)

### Orchestration MCP extensions (#135)

- **`task.report`** — child agents report progress; updates active delegation runs + ledger
- **`node.configure`** — orchestrator sets child `ToolPolicy` (capability + allowlist)
- **`trigger.schedule`** — interval (`every 1h`) or event subscription (`event:name`); persisted
- **`trigger.fire`** — wakes subscribed children via `delegate`; skips overlap when child is busy
- Host interval scheduler (60s tick) for standing agents

### Role transition gist (tier 0, #177)

- **`SessionGist.tier0`** — lossless per-turn extract (user prompt + final outcome;
  tool noise collapsed; char budget) for working-context seeding
- **Edit Role** default: restart Node + inject compact gist (not full transcript replay);
  alternatives: re-prime only, fresh restart
- Display transcript preserved; marker turn recorded on role change

### Design oracle (`design/13` runtime slices 1–3)

- `design/oracle/invariants/` — three active invariants
- Shadow → persist → orient-on-read → active enforcement
- `OracleLedger` → `oracle-verdicts.jsonl`; inspector verdicts
- ACP permission verb mapping for Claude/non-grok brains (#153)

---

## What Is Not Shipped

| Area | Status | Reference |
|------|--------|-----------|
| Orchestration MCP extensions (`task.report`, `node.configure`, `trigger.*`) | Shipped (#135) | `design/11` |
| Multi-level tree + parallel delegate fan-out | Open (#136) | `design/11` |
| ContextManager (fast-tier summarization, retrieval, gist oracle) | Partial (#177 tier 0; #137) | `design/12` Phase E |
| Oracle depth (verify-against-intent, corpus maintenance, INV detectors) | Open (#140–#142) | `design/13` |
| Signed/notarized Mac + TestFlight | Roadmap (#143) | README |
| Headless Linux GKSS server | Open (#144) | — |
| Per-Connection MCP server overrides | Open (#146) | — |

---

## Implementation vs. Design Doc Headers

| Doc | Header may say | Reality (2026-07-01) |
|-----|----------------|----------------------|
| `design/10` | "not implemented" | Rungs 0–2 ✅, rung 3 substantially ✅ |
| `design/11` | "not started" | Phase 1–3 largely ✅ |
| `design/12` | "not started" | Phases A–C, E, F ✅ |
| `design/13` | "thesis only" | Runtime slices 1–3 ✅ |

**This file** and `RELEASE_NOTES.md` are the operational truth for "where we are."

---

## Immediate Priorities

[milestone: Canonical Backlog](https://github.com/sourcepathlabsai/grokestrator/milestone/1)

| Priority | Issue | Topic |
|----------|-------|-------|
| 1 | [#136](https://github.com/sourcepathlabsai/grokestrator/issues/136) | Multi-level tree + parallel delegate fan-out |
| 2 | [#143](https://github.com/sourcepathlabsai/grokestrator/issues/143) | Signed/notarized Mac + TestFlight |
| 3 | [#141](https://github.com/sourcepathlabsai/grokestrator/issues/141) | Oracle: verify-against-intent orientation |
| 4 | [#142](https://github.com/sourcepathlabsai/grokestrator/issues/142) | Oracle: agent-proposed corpus maintenance |
| 5 | [#137](https://github.com/sourcepathlabsai/grokestrator/issues/137) | ContextManager tier 1 (gist summarization) |
| — | [#140](https://github.com/sourcepathlabsai/grokestrator/issues/140), [#137–#139](https://github.com/sourcepathlabsai/grokestrator/issues/137), [#144](https://github.com/sourcepathlabsai/grokestrator/issues/144), [#146](https://github.com/sourcepathlabsai/grokestrator/issues/146) | Oracle detectors, runtime depth, infra |
| — | [#135–#146](https://github.com/sourcepathlabsai/grokestrator/issues?q=is%3Aissue+milestone%3A%22Canonical+Backlog%22) | Full backlog |

---

## Key Architectural Decisions (standing)

- Native Swift + SwiftUI; GKSS (Mac server) is source of truth
- 1 Connection = 1 agent instance; tree = soft `parentID` edge
- ACP + `ACPEvent` universal wire; coordination in app (`delegate` MCP)
- Governance unit = `ProposedAction`; verb normalization at harness boundaries
- File-based JSON persistence; per-Mac orchestration SQLite via `db.*` MCP (#133)
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

*Last updated: 2026-07-01 — through PRs #170, #173, #175. Supersedes 2026-06-30 snapshot.*