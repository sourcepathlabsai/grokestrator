# Grokestrator — Agent Orchestration

Status: **design exploration** — not yet implemented. This document proposes how
Grokestrator helps you stand up and run *teams of grok agents* — a coordinator
plus specialists (coder, reviewer, architect) that carry a feature from "design
it" through "code it" to "open and merge a PR."

It is grounded in the existing model (`ManagedConnection`, `GrokBuildManager`,
`GrokBuildConversation`, the broadcast/subscription plane) and — critically — in
**grok's own native subagent system**, which already does most of the
coordination we'd otherwise have to build. See `connection-semantics` (memory) for
the standing rule this respects: *GKSS owns the Connection registry + history; one
Connection is 1:1 with one grok instance; there are no nested chats.*

## The pivotal fact: grok already orchestrates

Grok ships a full subagent system (`~/.grok/docs/user-guide/16-subagents.md`).
The primary agent calls a **`task` tool** to spawn child sessions, each with its
own context window, a `subagent_type` (`general-purpose`, `explore`, `plan`), an
optional **persona** (bundled: `implementer`, `reviewer`, `researcher`,
`security-auditor`, `test-writer`, `design-doc-writer`, `design-doc-reviewer`), a
**capability mode** (`read-only`/`read-write`/`execute`/`all`), optional
**git-worktree isolation**, `resume_from` chaining, and a depth limit. It even
bundles **skills** that *are* our pipeline — `design`, `implement`, `review`,
`execute-plan`, `pr-babysit`.

Grok reads all of this **from disk**, not over ACP:

- agent definitions: `~/.grok/agents/*.md`, project `.grok/agents/*.md`
- roles + personas: `[subagents.roles.*]` / `[subagents.personas.*]` in
  `config.toml`, and `.grok/roles/*.toml` + `.grok/personas/*.toml`

This single fact reshapes the whole design. We do **not** need to build a
coordinator that spawns and routes worker processes — grok does that. The
opportunity is to be the **control panel for grok's native subagent system**:
author its config beautifully, standardize it into reusable teams, scope it to a
project or globally, and surface what it's doing.

The one hard limit to keep in view: grok's subagents run **in-process** and are
**not exposed over ACP**. From Grokestrator's vantage a parent that spawns three
subagents is still *one* ACP session; children appear only as `tool_call` activity
(grok stores them under `~/.grok/sessions/<cwd>/<id>/subagents/`, a side channel).
Subagents also *cannot interact with the user*. That limit is exactly what
separates the rungs below.

## The integration ladder

There are three increasingly ambitious ways to integrate, with sharply different
cost/value. We pick the middle rung for v1 and defer the top.

| Rung | What Grokestrator does | Cost | What you gain |
|---|---|---|---|
| **1 — Surface** | Read grok's task lineage; render in-process subagents inline | Low | Visibility into what native subagents are doing |
| **2 — Configure** ← **v1** | Connection dialogs author `.grok/` agent + role + persona files; reusable team templates; project/global scope | Low–med | Set up a team's roles/prompts once, reuse, share via the repo — and ride grok's tuned coordination |
| **3 — Hierarchy** | Separate Connections/processes coordinated via a Grokestrator-hosted `delegate` MCP tool | High | A persistent, cross-machine, **human-steerable** fleet |

Rung 2 is the best value-per-effort: it makes Grokestrator a coherent, shippable
product (a GUI for grok's subagents) without re-implementing coordination, and the
role/prompt definitions it produces are exactly the seeds rung 3 would later
consume. Rung 1 folds in for free as we render the orchestrator's transcript.
Rung 3 is the only rung that delivers something grok structurally can't —
cross-device steerability — and is deferred until that need is real (see
*Deferred: the steerable fleet*).

## Why not the process hierarchy (rung 3) now

It's tempting to model "a dev lead owns three developers" as a tree of separate
Grokestrator Connections coordinated by a hosted `delegate` MCP tool. For the
stated use case — *one feature, one repo, architect→code→review→PR→merge,
autonomous* — that's **strictly more work for a worse result**: we'd hand-roll
spawning, routing, worktree isolation, depth limits, and persona prompts that grok
already ships and has tuned. The hierarchy only earns its cost on axes grok-native
genuinely can't reach (persistence, cross-machine, human-in-the-loop on a child).
We capture those later, deliberately, not by default.

## v1 — Configure grok's subagents (rung 2)

The shape: **two dialogs**, mirroring how the app already separates "Add
Connection" (fast) from per-connection editing (deep). The setup dialog gets you a
running connection with a named team; the settings dialog is the full surface.
Both ultimately do one thing — **author the `.grok/` files grok reads** — with a
GUI, validation, templates, and scope control instead of TOML archaeology.

### Setup dialog — the 80% fast path

Stays nearly as light as today's Add Connection. The only addition is a **team
template** picker:

```
Name:          [ ship-feature                    ]
Working dir:   [ ~/dev/myrepo            ] [Pick] [✓ exists]
Command:       [ ~/.grok/bin/grok ] [ agent stdio ]
Team template: ( Plain ▾ )   Plain · Feature team · Research team · Custom…
[ Cancel ]                                        [ Add ]
```

- **Plain** = today's behavior, no roles authored — nothing regresses.
- **Feature team** = one click seeds an agent + role/persona set for
  coordinator + implementer + reviewer (mapped onto grok's bundled
  personas/skills).
- **Custom…** opens the settings dialog directly.

Rule we hold the line on: *Setup gets you a running connection with a named team
template; everything tunable lives in Settings.* If a field isn't needed to
start, it is not in Setup.

### Settings dialog — the full surface, tabbed

Tabs keep the richness from becoming a wall, and map onto grok's own "Agents vs
Personas" split:

| Tab | Configures | Writes |
|---|---|---|
| **Connection** | name, command, args, cwd, autoRestart, shared *(today's fields)* | `connections.json` |
| **Agent** | this session's model, system prompt, prompt mode, enabled skills, role | `~/.grok/agents/<name>.md` or `.grok/agents/<name>.md` |
| **Team** | the subagent library the `task` tool draws on — per-role persona, capability mode, model, prompt | `.grok/roles/*.toml` + `.grok/personas/*.toml` (or `config.toml` `[subagents.*]`) |
| **Advanced** | scope toggle, raw file preview / escape hatch | — |

The **Agent** tab matters because grok agent definitions apply to the *primary*
session (personas can't) — so this configures the connection you actually talk to,
which is *not* redundant with the subagent library. The **Team** tab defines the
roster its `task` subagents draw from.

### The highest-leverage control: scope toggle

On the Agent and Team tabs, a prominent:

```
Apply to:  ( ◉ This project  .grok/ )   ( ○ My defaults  ~/.grok/ )
```

- **Project** → files land in the repo's `.grok/`, are committable, travel with
  the repo, and are shared with teammates. *This is what turns the feature from
  "my personal setup" into "the repo ships its own agent team."*
- **My defaults** → `~/.grok/`, your personal baseline across all projects.

This one toggle is the difference between a personal convenience and a
collaboration primitive. It's the feature to get right.

### Authoring discipline (build in from day one)

Because these dialogs write real files grok reads, two non-negotiables:

1. **Show the diff; write real, inspectable files.** Before saving, preview
   exactly which files will be created/overwritten (e.g. "write `.grok/agents/
   coordinator.md`, `.grok/roles/coder.toml`, `.grok/personas/reviewer.toml`").
   No black box. The corollary: a hand-authored `.grok/` is **importable** — the
   dialog reads existing files into its fields so we round-trip, not clobber.
2. **Never clobber silently.** If a target file already exists, detect it and
   offer merge / overwrite / keep — the same confirm-before-destructive discipline
   used for connection deletion. Authoring config must be as safe as deleting a
   server.

### Team templates

A team template is a named bundle of (agent definition + role/persona set) that
the Setup picker and Settings "load template" both draw on. Ships with a couple of
sensible ones (Feature team, Research team), mapped to grok's bundled
personas/skills so we ride tuned prompts:

| Our role | grok mapping |
|---|---|
| coordinator | agent definition w/ `design` + `pr-babysit` skills enabled |
| coder | `implementer` persona, `execute` capability mode |
| reviewer | `reviewer` persona |
| architect | `design-doc-writer` persona / `plan` agent type |

A connection records which template it was minted from but owns its own copy, so
tweaking one connection's team never disturbs the template.

### Rung 1 surfacing, folded in

While a connection runs, grok's `task`-tool spawns appear as `tool_call` activity
in the one ACP stream. We render them inline using the existing
**`ThoughtProcessView`** disclosure pattern (chevron + animated reveal), collapsed
under the turn that spawned them, optionally labeled from the on-disk
`subagents/` lineage. No new transport — just nicer rendering of what's already
on the wire.

```
You ▸ Build a rate-limiter and ship it.

✦ grok (coordinator)
  Planning, then delegating to subagents…
  ▸ 🏛 architect (design-doc-writer) — wrote the plan
  ▸ ⌨ coder (implementer, worktree) — implemented on feat/rate-limiter
  ▸ ✓ reviewer — 2 findings, resolved
  Opened PR #123. Merged. Done.
```

One narrative, sub-steps as progressive disclosure — directly answering the
"separate chats would be confusing" concern without any process hierarchy.

## What's new vs. reused (v1)

| Concern | Reuse | New |
|---|---|---|
| grok subagent spawning, routing, worktrees, personas, skills | **grok-native** (`task` tool) | — |
| Connection process/session | `GrokBuildManager`, `GrokBuildConversation` | — |
| Persistence of the connection | `ConnectionStore` (connections.json) | optional `teamTemplate` field on `ManagedConnection` |
| **`.grok/` authoring** | — | file writers for `agents/*.md`, `roles/*.toml`, `personas/*.toml` + `config.toml` `[subagents.*]`; diff preview; import/round-trip; no-clobber merge |
| Team templates | grok bundled personas/skills | a small template catalog (Core) mapping our roles → grok personas/skills |
| Setup UI | `AddConnectionView` | team-template picker |
| Settings UI | per-connection edit sheet | tabbed Connection/Agent/Team/Advanced; scope toggle |
| Subagent surfacing | `ThoughtProcessView`, broadcast plane | inline rendering of `task` `tool_call` activity (+ optional `subagents/` lineage read) |

Note what's **absent** from v1 versus the earlier draft: no MCP host, no
`delegate` tool, no `delegate` router, no role-seeding injection, no `parentID`
tree, no sidebar nesting. Those all belong to rung 3.

## Non-goals (v1)

- **Re-implementing coordination.** grok's `task` system does the spawning and
  routing; we configure and surface it, full stop.
- **A process hierarchy of Connections.** Deferred to rung 3.
- **Driving sub-agents directly / human-in-the-loop on a child.** Not possible
  with grok-native subagents; deferred to rung 3.
- **Changing the standalone single-connection experience.** "Plain" remains the
  default and is completely unchanged.

## Deferred: the steerable fleet (rung 3)

The one thing grok-native subagents structurally cannot do is let a human **watch
and grab the wheel of an individual worker, from any device**. When that need is
real — long-lived role agents, multiple repos/machines, answering a specific
worker's permission prompt from your iPad — rung 3 applies:

- Each role becomes a **real Connection** (own grok process, own ACP stream, own
  sidebar node, own chat) so it rides the existing broadcast/subscription plane
  and is visible + steerable on every device.
- A Grokestrator-hosted **MCP server** (feasible — `MediaHTTPServer` already
  proves we can bind an in-app server, and grok supports `http`-transport MCP)
  exposes a `delegate(role, task)` tool the coordinator calls; Grokestrator routes
  it to the right Connection and returns the result.
- Connections gain a soft `parentID` edge (no nested objects — the 1:1 instance
  rule holds) and the sidebar gains one disclosure level.
- The role/prompt definitions authored in **v1 become the seeds** fed to these
  real connections — so rung 2 is a genuine stepping stone, not a throwaway.

First-stab calls already made for rung 3 (kept here so the path is concrete):
PR-merge is a thin Grokestrator-gated action (reviewer-green **or** human-confirm)
while `pr-babysit` does the PR/CI work; one shared MCP host routed by coordinator
ID; role seeds capped + `/compact`-summarized; workers spun up per-feature and
archived (opt-in keep-warm); `delegate` returns structured errors for the
coordinator to retry, escalating to the human after repeats; orchestration is
host-local (remote devices view + prompt, host drives).

## Open questions

- **Config-file format coverage.** Author via the discrete files
  (`.grok/roles/*.toml`, `.grok/agents/*.md`) or via `config.toml`
  `[subagents.*]`? The discrete files are cleaner to diff and round-trip; lead
  with those, treat `config.toml` as import-only.
- **How much subagent lineage to surface (rung 1).** Rendering every `task` child
  inline could get noisy. Start collapsed under the owning turn; revisit if users
  want full lineage / the `subagents/` read is worth the disk coupling.
- **Template authority + updates.** When we ship a better "Feature team" template,
  do existing connections that minted from it get offered an update, or stay
  frozen? (Lean: stay frozen; offer a manual "re-apply template.")

## Relationship to other documents

- `04-conversation-model.md` — the conversation/instance 1:1 rule this preserves;
  multi-instance was deferred there and stays deferred (it's rung 3).
- `07-client-control-plane-protocol.md` — the broadcast plane rung 1 surfacing and
  any rung-3 work would ride on.
- `09-slash-commands.md` — `/compact` and the command catalog; relevant to seed
  budget at rung 3 and to driving agents generally.
- `connection-semantics` (memory) — GKSS owns the registry; v1 adds only a
  `teamTemplate` field and authored `.grok/` files, leaving the 1:1 instance rule
  fully intact.

---

*Created: 2026-05-30. Status: design exploration; no implementation yet. v1 scope
= rung 2 (configure grok's native subagents); rung 3 (steerable fleet) deferred.*
