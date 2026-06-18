# Agent guidance — Grokestrator

Read this first. It is the **orient-on-read** entry point for any intelligence
(Claude, Codex, grok, …) working this repo. The point of the project's design corpus
is that *any* capable model can orient on it and contribute correctly; these are the
two standing duties that keep that true.

## 1. Orient before substantial work

Before non-trivial work, orient on:
- **The project oracle** — `design/oracle/` (invariants this project must hold; one
  human+machine-readable markdown file each — see `design/oracle/README.md`). These are
  enforced at runtime by the governance engine *and* are yours to orient on directly.
- **Repo design docs** — `design/*.md`, especially `10` (orchestration rungs), `11`
  (orchestration platform), `12` (model-agnostic runtime), `13` (design oracle), `14`
  (OODA helix).
- **The canonical concept layer in the Obsidian vault** (`4-Concepts/`) — at minimum
  *OODA Loop and Mission Orientation*, *OODA Is a Helix Not a Loop*, *AI-Native
  Oracles*, *Design Oracle Operational Form*, and the *Context* notes.

Orientation — not raw model capability — is the lever. A change that contradicts a
stated design goal is a defect, even if it "works."

## 2. Maintain the strategic record in Obsidian — aggressively

**Obsidian is the first-level repository for strategic thought.** Maintain it
**proactively and aggressively**, not only when explicitly told to. This is the
*maintain-as-you-work* operation of the design oracle (see `design/13` and the vault's
*Design Oracle (Operational Form)*).

**Record in Obsidian** (the durable, cross-project Orient axis):
- strategic **goals** and direction (and shifts in direction, with the reasoning),
- **oracles** — what "correct"/"aligned" means, and why,
- key **reasoning, insights, and design intent** — the *why* behind decisions.

Prefer atomic, cross-linked notes: `4-Concepts/` for project-agnostic concepts, the
project folder for project-specific strategy. Agents **draft**; the human **curates**
the canonical corpus (never silently mutate established strategy — a wrong oracle heals
toward wrong).

**Do NOT put in Obsidian** the operational/tactical layer — implementation choices,
step-by-step plans, bug fixes, refactors. Those belong in code, commits, PRs, and the
repo's `design/` docs. The test: *would a fresh intelligence need this to understand
what the system is trying to do and why?* If yes → strategic → Obsidian. If it's just
how a particular change was carried out → operational → stays in the repo.

> Canonical cross-project convention: `~/dev/.agents/COMMON_STRATEGIC_RECORD.md`
> (shared by every project so the strategic record stays aligned across all of them).

## 3. The working rhythm

Talk → work out the details → write it down → maintain the low-level oracle of design
goals. That loop (a meta-OODA over the design corpus) is what has let multiple model
families contribute here without breaking things. Keep it running.
