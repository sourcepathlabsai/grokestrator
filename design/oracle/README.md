# Design Oracle — the project's runtime intent

This directory is the **project-owned design oracle**: the maintained, low-level record of
this project's intent that any agent or tool can orient on, and that the runtime governance
engine verifies actions against. It lives in the repo *on purpose* — so it survives swapping
brains and works outside any single app (a standalone Claude Code, Codex, or a human all read
the same files). See `design/13-design-oracle.md` and the Obsidian *Design Oracle (Operational
Form)* note for the full thesis.

## What's here

- `invariants/*.md` — one **invariant** per file. The body's first paragraph is the prose
  `statement` (what must hold); the rest is rationale. Frontmatter:
  - `id` — stable identifier (e.g. `INV-no-destructive-shell`); detectors/findings reference it.
  - `severity` — `info | low | medium | high | critical`.
  - `state` — `proposed | active | retired`.
  - `detector` *(optional)* — a named runtime detector ID (the precise, deterministic checks —
    e.g. `DET-path-escape` — implemented per-runtime and keyed by this ID).
  - A `## Detect` body section *(optional)* — a **human-named** list of regex rules
    (`- <name>: \`<regex>\``). A portable high-recall detector ANY runtime can run against an
    action's command/payload; a match → *suspect* (escalate), never a silent block. Named so a
    person reads the intent and the machine reads the pattern from the same line — no
    machine-only artifact (see *No Cognitive Gap*).
  - An invariant with neither `detector` nor a `## Detect` section is **grounding-only**: it
    shapes classification + escalation and grounds a judge, without a check of its own.

Every file here is **human-first and machine-equal**: a person and an agent read, edit, and
act on the same artifact, and the runtime can write proposals back in this same format. That's
the point — the oracle is the shared human↔machine workspace, not a doc *about* one.

## How it's loaded

The runtime loads `<project>/design/oracle/` from the node's working directory, merged over a
small built-in universal baseline (verb → side-effect classifications like `shell` = execute).
No `design/oracle/` ⇒ baseline only. Editing an invariant here changes governance on the next
session — the oracle is **curated by humans, never auto-mutated**.
