# Agent guidance — Grokestrator

Read this first. It is the **orient-on-read** entry point for any intelligence
(Claude, Codex, grok, …) working this repo. The point of the project's design corpus
is that *any* capable model can orient on it and contribute correctly.

**You must work in the OODA helix** (§0). Orientation — not raw model capability — is
the lever. The standing duties below are how that loop is made operational here.

## 0. Mandatory mode of operation: the OODA helix

Every intelligence working this repo **must** run Boyd's loop — **Observe → Orient →
Decide → Act** — as the actual rhythm of work, not as decorative vocabulary. Canonical
concept notes: Obsidian `4-Concepts/OODA Loop and Mission Orientation`, `OODA Is a Helix
Not a Loop`, `Design Oracle (Operational Form)`; repo projection: `design/14-ooda-helix.md`.

### Why we enforce this here (two purposes)

1. **Backlog in the best order we can divine — and re-divine.** The loop exists so we
   move through work (`PROJECT_STATE.md`, GitHub milestone *Canonical Backlog*, open
   issues) in the order that best serves **goals, design, and intent at this moment** —
   not a frozen roadmap. **Orient** grounds that ordering; **Decide** commits to the
   next slice; **Act** produces evidence. New observations **re-Orient** and may
   legitimately **reorder** what comes next. Priority is fluid, not arbitrary: when
   order shifts, say what you learned and which goal it serves.
2. **A teachable thought process for any LLM.** This file is how a fresh intelligence
   (Claude, Codex, grok, …) learns *how to think here* — not just what to build. Make
   the loop visible: what you observed, how you oriented, what you decided and why,
   what you acted on. The corpus + this discipline are what let model families hand off
   without losing the plot.

### The four stations (each is required)

| Station | What it is | Failure mode if skipped |
|---------|------------|-------------------------|
| **Observe** | Take in the instruction, repo/system state, side effects, constraints, and what already happened (git, issues, PRs, runtime). | Under-observe → act on stale or partial reality. |
| **Orient** | **Load-bearing.** Synthesis: filter observation through doctrine, memory, and design intent. Derive the *real mission*, not a proxy reading of the instruction. Where proxy-vs-mission lives. | **Barreling** — Observe straight to Act on the literal token. |
| **Decide** | Commit to an approach aligned with the oriented mission (scope, sequencing, what *not* to do). | Timidity — cycling Observe→Orient forever, never closing the loop. |
| **Act** | Execute decisively; feed results back into the next Observe. | A loop that never Act's loses tempo and never learns. |

When behavior goes wrong, diagnose **which station broke** — not a vague caution↔boldness dial.

### Helix, not loop

Orient is not a station you return to unchanged — it is the **displacement operator**.
Each Act's results re-found the frame (re-Orient); you advance along an axis of
accumulated orientation change, not a flat circle. Delegation spawns **sub-helices**
(orchestrator Act → child OODA → …). Convergence requires **honest Observe** (oracles,
verification) and **grounded Orient** (the design oracle / maintained corpus) —
formal reason orientation beats model size.

The design oracle (`design/oracle/`, `design/13`, Obsidian strategic record) is
**institutionalized Orient** — the compressed axis agents read; PRs, commits, and issue
comments are provenance on the helix.

### What this means in practice (every session, every slice)

1. **Observe** — read the ask, current `main`, open PRs, relevant code/docs, and constraints
   before proposing or editing.
2. **Orient** — before substantial work, load the corpus (§1). State what mission you
   derived and which design goals/invariants govern the slice. **Do not skip this step.**
3. **Decide** — pick the **next slice** and its place in the backlog: scope, approach,
   what is out of scope, and **why this now** (goals/design/intent). Re-decide when
   Observe changes the picture.
4. **Act** — implement; land via PR (§4).
5. **Observe → re-Orient** — after Act: tests/build, PR handoff, on merge report update
   issues; if strategic intent shifted, draft Obsidian updates (§2).

Meta-loop over the corpus itself: talk → work out details → write it down → maintain the
oracle — that is OODA over the design record (§3).

## 1. Orient before substantial work (the Orient station, made concrete)

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

## 3. The working rhythm (meta-OODA over the design corpus)

Talk → work out the details → write it down → maintain the low-level oracle of design
goals. That is the **re-Orient** pass after each Act on the strategic record — the
meta-helix that keeps the Orient axis true so any model family can contribute without
breaking things. Keep it running.

## 4. Delivery: every slice lands via PR — then stop

**All work merges through pull requests.** No direct commits to `main`, no "I'll merge
later," no starting the next slice while a PR is open.

When you complete a slice:

1. **Branch** — focused `feat/` or `fix/` branch from current `main`.
2. **PR** — open a pull request before declaring the slice done.
3. **Description** — list every GitHub issue fixed/closed (e.g. `Fixes #122, #147,
   #148`). Include a short summary of what changed and why.
4. **Hand off** — give the human the **PR link** and explicitly **await merge**.
5. **Gate** — **do not start another slice** until that PR is merged. If the human
   asks for more work while a PR is open, warn them: *merge the open PR first* (or
   confirm they want to stack/revise scope).
6. **On merge reported** — when the human confirms a PR is merged, **comment on each
   fixed issue** with which PR resolved it (link + one-line summary) and **close the
   issue** if it is still open. Do not assume issues auto-closed from the PR body
   alone — verify and leave an audit trail.

This is standing policy — re-read it at session start so it does not need to be
re-prompted every time.
