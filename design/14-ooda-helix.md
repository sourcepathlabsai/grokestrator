# Grokestrator — OODA as a Helix (the substrate under 10/11/13)

Status: **conceptual foundation.** The canonical, project-agnostic write-ups live in
the Obsidian vault (`4-Concepts/OODA Is a Helix Not a Loop`, `Design Oracle
(Operational Form)`, building on `OODA Loop and Mission Orientation` and `AI-Native
Oracles`). This doc is the repo-local projection + the concrete build implications for
Grokestrator. See `AGENTS.md` for the orient-on-read / maintain-the-oracle duties.

## The substrate, in one paragraph

OODA is not a loop but an **n-dimensional helix**: **Orient is the displacement
operator** — each pass re-founds the frame from the last Act's results, so you never
return to the starting plane. It is **recursive** (every Act spawns a sub-helix → the
orchestration tree is a helix-of-helices) and **self-correcting** on the Observe →
re-Orient edge (a wrong Act *turns* the helix instead of breaking it). It converges iff
**Observe is honest** (oracles) and **Orient is grounded** (the design oracle) — which
is the formal reason *orientation beats model size*. The **design oracle is the
compressed Orient axis**; the raw helix (every iteration + spawned/abandoned sub-loop)
is provenance — full on disk, compressed in working context.

## What it changes in the build (Grokestrator)

1. **Orient becomes an enforced first step** of every turn and every delegation — not
   implicit. A node orients (design oracle + the specific task) *before* it Decides.
   Mechanism: per-repo `AGENTS.md` / orient-on-read; per-task this generalizes the
   role-prompt-on-first-turn we already inject.
2. **Record the helix, not just the transcript.** Extend the Run/DAG (`11`) into a
   helical provenance map: iterations, orientation deltas, spawned/abandoned sub-loops,
   outcomes. This is the dynamic complement to the static design oracle.
3. **Oracles sit on the Observe → re-Orient edge.** Verification isn't only a final
   gate; it's the per-loop honesty check that lets the helix self-correct (and the
   trigger for *evidence-driven escalation* in `12`, not pre-judged routing).

## Relationship to other documents

- `13-design-oracle.md` — the maintained Orient axis; this is the dynamic structure it
  advances along. Together: orient → act → verify (output + against-intent).
- `11-orchestration-platform.md` — the node tree *is* the helix-of-helices; the Run/DAG
  is the seed of the provenance map; oracles live on Observe→re-Orient.
- `12-model-agnostic-runtime.md` — why naive tier routing is wrong: orientation, not
  model size, keeps the helix converging.

---

*Created 2026-06-16. Conceptual foundation; canonical text in the Obsidian `4-Concepts`
layer. The immediate build implication to pull forward is an enforced Orient step
(orient-on-read) for delegation.*
