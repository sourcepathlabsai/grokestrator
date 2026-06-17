# Grokestrator — The Design Oracle (orientation as the quality engine)

Status: **design thesis** — surfaced 2026-06-16 from a working observation, captured
as direction. It reframes what the product's core asset is.

## The observation

Three different model families — Claude, Codex, and grok — have all contributed to
Grokestrator and Alexander **without breaking things**, and each, when told to orient
on the project in a fresh session, independently remarks that the design is unusually
complete and well-thought-out. That convergence is the signal: what makes the work
contributable is **not any one model**. It's the **maintained, low-level corpus of
design goals + heavy documentation** — a model-independent specification of *intent*
dense enough that any capable model can **orient** and converge on correct
contributions.

Call that corpus the **design oracle**: the standing, curated, low-level record of
*what the system is trying to do and why*, maintained as the work proceeds.

## The thesis

**Orientation, not model capability, is the lever we control — and it compounds.**

> Quality in agentic work ≈ **orientation × capability × verification.**

- **Capability** (the model) you rent; it's a commodity and improving on its own.
- **Verification** (oracles over outputs) you've already designed (`11`).
- **Orientation** (the design oracle) is the term **you uniquely own**, it is
  **model-portable**, and it **accumulates** across every session and every brain.

The practical consequences:

- **A smaller model *with* the design oracle routinely beats a bigger model
  *without* it.** This is the real rebuttal to "route by task size" (`12`): reach for
  orientation before you reach for a bigger brain.
- **The moat is the orientation corpus, not the brain.** Brain-swap (`12`) says the
  model is a commodity and the *body* is the value; this sharpens it — the most
  valuable part of the body is the design oracle that orients the brain. Tool-gating
  keeps a brain *safe*; orientation makes it *good*.
- **The durable "context" is the curated design corpus, not the transcript.**
  Transcript compaction (`12` Context management) is plumbing; the design oracle is
  the asset.

## Why it works (the loop you already run by hand)

The discipline that produced this: *talk → work out the details → write heavy
documentation → maintain a long-standing low-level oracle of system design goals.*
That loop keeps intent explicit and coherent, so contributions from any model don't
drift. Productizing it means making three things first-class:

1. **Orient-on-read.** Every Node/agent loads the relevant design-oracle corpus at
   session start — the automated form of "tell a fresh session to orient." (Today's
   role-prompt injection is the per-Node version of this; the design oracle is the
   project-level version.)
2. **Maintain-as-you-work.** The corpus is *living*: as agents learn or decisions are
   made, they **propose updates** to the oracle, **human-curated** before they land,
   so it stays trustworthy. Agents help carry the discipline that is currently
   manual — draft, you approve.
3. **Verify-against-intent.** Generalize `11`'s oracle from *"is this output
   correct?"* to *"does this change honor the design goals?"* — an **orientation
   oracle** alongside the output oracle. A change that contradicts a stated design
   goal is flagged like any other violation.

This is also exactly the OODA **Orient** step (`11`): orient on design goals + current
state *before* deciding. The instinct you encoded in the agent tree and the design
oracle are the same instinct at two scales.

## Is this the product?

Plausibly the center of it. Read one way, Grokestrator's value is increasingly: **a
system for building and maintaining the design oracle that lets any model contribute
correctly — then orchestrating models against it, safely and observably.** Under that
read, orchestration (`10`/`11`) and brain-swap (`12`) are the *delivery vehicle*; the
orientation corpus + the discipline to keep it true is the *engine*. (Flagged as a
strategic thread to confirm, not yet a settled scope decision — see Open questions.)

## Honest tensions / risks

- **Maintaining a low-level oracle is real work** — it's the diligence currently
  supplied by hand. If agent-assisted maintenance isn't ergonomic and trustworthy, the
  thing that works because the founder is diligent won't scale. Make drafting cheap and
  curation fast; never let agents mutate the oracle unreviewed.
- **A wrong oracle heals toward wrong, confidently** (same hazard as `11`'s output
  oracles). The corpus must be curated with cathedral-grade care precisely because
  everything orients on it.
- **Over-documentation / staleness.** Keep it *low-level and intent-focused* (goals,
  constraints, decisions, rationale), not a mirror of the code. Stale orientation is
  worse than none. Prefer a small, dense, current corpus over an exhaustive one.

## Open questions

- **Structure of the corpus.** The `design/*.md` docs + this kind of intent record are
  the seed. Is there value in a *structured* design-goals index (goals ↔ constraints ↔
  decisions ↔ the code/docs they govern) that agents query, vs. prose docs they read
  whole? Lean: start with the prose corpus that already works; add structure only
  where retrieval/verification needs it.
- **The orient-on-read mechanism.** Per-project corpus injected at session start —
  how is "relevant subset" chosen (whole corpus for small projects; retrieval for
  large)? Ties to `12` Context management (local embeddings).
- **Maintenance workflow.** What's the lightest ritual that keeps the oracle current
  without becoming a chore — agent-proposed diffs to `design/` on each substantial
  change, surfaced for one-click human review?
- **Is the orientation corpus *the* product** (engine), with orchestration/brain-swap
  as vehicle? Strategic; confirm before it reshapes scope.

## Runtime governance form — first code contact (2026-06-17)

The thesis above crystallized into a concrete runtime form and a first shadow-mode
slice. Full reasoning lives in the Obsidian note *Design Oracle (Operational Form)*;
the load-bearing decisions, projected here:

- **Unit of governance is a proposed Action** (verb, args, payload, context,
  provenance) — *not* a git diff. Domain-general: "run this shell command", "send this
  email", "call this MCP tool" all reduce to one shape. The oracle sits at the mediated
  tool boundary the app already owns.
- **The corpus is one graph, two media, joined at the invariant.** Prose (goals,
  decisions, rationale) authored in Obsidian; structure (classifications, detectors,
  side-effect taxonomy) authored in the repo. The **invariant** is Janus-faced — a
  prose `statement` that grounds a judge, a structured `detector` that runs as a check.
  Runtime is a rebuildable materialized view, authoritative over nothing, fail-closed.
- **Detectors are `(Action) → [Finding]`** with two grades: `definitive` (precise,
  deterministic — decides; ~10–20%) and `suspect` (high-recall regex/heuristic — flags
  and defers to a grounded judge; ~80%). Each declares a `minimumFidelity` and abstains
  below it.
- **Pipeline:** Action → classify (key index) → detectors → severity → escalation
  outcome (allow / escalate / block). Unknown classification fails closed.

Shipped (`Packages/GrokestratorCore/Sources/GrokestratorCore/Governance/`,
`GovernanceEngine.shadow`), wired in **shadow mode** (observe + log, no enforcement) at
both boundaries. What first contact corrected:

- **Boundary fidelity asymmetry.** The API tool loop (`executeTool`) gives fully
  structured args (`.structured`, total mediation, app executes); the ACP permission
  boundary gives a coarse `kind` + a command/title string (`.semiStructured`, grok
  executes, we only gate). The same invariant (cwd-confinement) is enforceable on the
  API boundary but **abstains** on ACP — the precise/recall split is partly *forced by
  the boundary*, not freely chosen.
- **The agent pre-classifies, untrusted.** grok's ACP `kind` is the agent classifying
  its own action — captured as an untrusted hint (raise suspicion, never clear). The
  existing `AutoApproval.autoApproves(kind:)` is literally this oracle's v0.
- **Mediation has an ACP-side hole.** We see only what grok *asks* permission for;
  high-assurance governance favors the app-executed boundary.

## Relationship to other documents

- `11-orchestration-platform.md` — the oracle thesis there guards *outputs*; this
  guards *orientation/intent*. Together: orient → act → verify-against-intent +
  verify-output. OODA's **Orient** is this at runtime.
- `12-model-agnostic-runtime.md` — brain-swap makes the model a commodity; this names
  the most valuable part of the body. It's also why naive tier routing is wrong:
  orientation beats size.
- `00-vision-and-north-star.md` — supervision UX; orientation is what a supervised
  fleet must share to stay coherent.

---

*Created 2026-06-16. Updated 2026-06-17: runtime governance form specified and a
first shadow-mode slice landed (`GrokestratorCore/Governance/`, observe-only at both
tool boundaries). Captures that the maintained low-level design oracle — model-portable
orientation — is the project's core quality engine, possibly its core product. The
immediate change it forces remains the tier-routing correction in `12`.*
