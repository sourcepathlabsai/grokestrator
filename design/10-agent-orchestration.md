# Grokestrator — Agent Orchestration

Status: **design exploration** — not yet implemented. This document proposes how
Grokestrator helps you stand up and **supervise** *teams of grok agents* — a
coordinator plus specialists — that carry a job from "figure out how" through
"do it" to "report back." The recurring example is coding (architect → code →
review → PR → merge), but the model is **deliberately domain-agnostic**: the same
machinery supervises a non-coding pipeline (e.g. a winery agent that pulls from a
POS, reconciles inventory, and emails a summary — pausing for a human answer when
it's unsure). This carries the north star's lead: general-purpose, observable,
answerable supervision — not a coding-only tool. See `00-vision-and-north-star.md`.

It is grounded in the existing model (`ManagedConnection`, `GrokBuildManager`,
`GrokBuildConversation`, the broadcast/subscription plane) and — critically — in
**grok's own native subagent system**, which already does most of the
coordination we'd otherwise have to build. See `connection-semantics` (memory) for
the standing rule this respects: *GKSS owns the Connection registry + history; one
Connection is 1:1 with one grok instance; there are no nested chats* — a rule that
holds through rungs 1–2 and is extended (not broken) by a soft `parentID` edge at
rung 3 (below).

**Direction (revised 2026-06-01).** The path is now stated as **both, sequenced**:
surface grok-native subagents first (cheap, partial), then graduate to
**real, steerable Connection children** as the explicit destination. Rung 3 is no
longer "deferred until some hypothetical need" — Grokestrator's heart is the
supervision UX (*watch a worker think live, and answer its question*), which
grok-native subagents structurally can't provide (see the limits below). This
supervision slice is built for the **free founder/solo-dev tool on its own
merits** — and it doubles as the **live prototype** for the separate monetization
bet in `strategy-general-case-ai.md` (which reuses the *concept*, not this app's
grok brain or local-Mac deployment).

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

**How they actually run** (authoritative, from `~/.grok/docs/user-guide/16-subagents.md`):
subagents are **parallel child sessions**, each with its own context window. The
parent keeps working and **receives each child's result (a summary) when the child
completes** — it does *not* fire-and-forget; delegation is "spin off, optionally
keep working, then collect." Children chain via `resume_from`, can be isolated in a
git worktree, and are depth-limited. **Two hard limits, straight from grok's docs:**

1. **A subagent cannot interact with the user.** "Tasks that require tight
   back-and-forth with the user" are an explicit anti-pattern — when a child needs
   help it works within its capability mode or fails; it has **no channel to ask
   you**. There is no native "the architect has a question for the human."
2. **Subagents are invisible over ACP** (see below) — their thinking is not on the
   wire.

Together these mean the headline flow — *watch the architect think live, and
answer its question from another conversation* — is **structurally impossible with
grok-native subagents**. Delivering it requires making each role a real,
observable Connection (rung 3).

Grok reads all of this **from disk**, not over ACP:

- agent definitions: `~/.grok/agents/*.md`, project `.grok/agents/*.md`
- roles + personas: `[subagents.roles.*]` / `[subagents.personas.*]` in
  `config.toml`, and `.grok/roles/*.toml` + `.grok/personas/*.toml`

This single fact reshapes the whole design. We do **not** need to build a
coordinator that spawns and routes worker processes — grok does that. The
opportunity is to be the **control panel for grok's native subagent system**:
author its config beautifully, standardize it into reusable teams, scope it to a
project or globally, and surface what it's doing.

The opacity limit, in detail (the "invisible over ACP" point above): grok's
subagents run **in-process** and are **not exposed over ACP**. From Grokestrator's
vantage a parent that spawns three subagents is still *one* ACP session; children
appear only as `tool_call` activity (grok stores them under
`~/.grok/sessions/<cwd>/<id>/subagents/`, a side channel). Together with "cannot
interact with the user," that opacity is exactly what separates the rungs below.

## The integration ladder

Increasingly ambitious ways to integrate, with sharply different cost/value. The
direction is **both, sequenced**: ship the cheap near-term wins (rung 0 + rung 1)
and the config GUI (rung 2), *while building toward* the steerable fleet (rung 3)
as the explicit destination — because rung 3 is the only rung that delivers the
headline vision (watch a worker live + answer it + non-coding supervision).

| Rung | What Grokestrator does | Cost | What you gain |
|---|---|---|---|
| **0 — Attention cue** ← near-term, no hierarchy | Badge a background Connection (and a global indicator) when it has a pending question/permission, so you click back to answer | Low | Human-in-the-loop across many conversations *today*; de-risks rung-3 UX |
| **1 — Surface** ← near-term | Read grok's task lineage; render in-process subagents inline | Low | Visibility into what native subagents *did* (not live, not answerable) |
| **2 — Configure** | Connection dialogs author `.grok/` agent + role + persona files; reusable team templates; project/global scope | Low–med | Set up a team's roles/prompts once, reuse, share via the repo — and ride grok's tuned coordination |
| **3 — Steerable fleet** ← **destination** | Each role = a real Connection (own ACP stream, own chat, own sidebar node), coordinated by a Grokestrator-hosted `delegate` MCP tool; soft `parentID` edge | High | **Watch a worker think live and grab the wheel from any device** — the one thing grok-native structurally can't do |

How the rungs relate:

- **Rung 0** is independent of everything else and serves the vision immediately —
  it works on **today's flat model** (every Connection is already an observable ACP
  session; the wire protocol already carries `promptState.pendingPermissions`). It's
  the cheapest possible down-payment on "answer the worker's question," and the UX
  it establishes (a question on a background worker pulling you back) is exactly
  what rung 3 needs at scale.
- **Rung 1** folds in for free as we render the orchestrator's transcript — but it
  is **explicitly partial**: you see what a child *did* (a `task` tool-call,
  optionally labeled from the on-disk `subagents/` lineage), never live thinking,
  and you cannot answer it. It is "read-only history of opaque workers."
- **Rung 2** is the best value-per-effort for *configuring* a team without
  re-implementing coordination, and the role/persona files it authors are **the
  literal seeds rung 3 consumes**. It's a genuine stepping stone, not a throwaway.
- **Rung 3** is the destination. It is *more work* than riding grok-native
  coordination, and for a fully-autonomous single-repo coding flow grok-native is
  still the better tool. But rung 3 is the **only** rung that reaches the axes the
  north star now leads with — **live observability, human-in-the-loop on a child,
  and cross-device steering** — which a non-technical operator supervising a
  general-purpose job fundamentally needs. We build toward it deliberately, seeded
  by rung 2, with rung 0's UX already proven.

### When grok-native is still the right answer

For a *fully autonomous* job where the human does **not** need to watch or answer a
specific worker — "ship this one feature in this one repo, architect→code→review→
PR→merge, don't bother me" — grok's in-process `task` system is **strictly better**:
it already does spawning, routing, worktree isolation, depth limits, and tuned
personas. Rung 3 is not a replacement for that; it's the path for the *supervised*,
*cross-device*, *general-purpose* work grok-native structurally can't surface.
Both coexist: a rung-2 Connection running grok-native subagents, with rung-0/1
making them legible; rung-3 Connections when a worker must be watchable and
answerable.

## Near-term: the cross-conversation attention cue (rung 0)

The cheapest, highest-leverage step toward "supervise the work" — and it needs
**no hierarchy and no new transport**. Today, when a background Connection raises a
permission or question, you only see it if that conversation is selected
(`pendingPermission` / `pendingUserQuestion` live on `ConversationViewModel`, and
the overlay renders only for the foreground conversation). So an agent quietly
waiting for an answer is invisible until you happen to click in.

The cue closes that gap:

- **Sidebar badge.** A Connection with something pending gets a distinct indicator
  (e.g. an amber pulse / "?" badge on its row) — visually louder than the plain
  status dot, so a waiting worker stands out across a long sidebar.
- **Global indicator.** An app-level count ("2 agents need you") so you notice even
  when the sidebar group is collapsed or you're on another server.
- **Click-through.** Selecting the badged Connection lands you on the pending
  overlay, ready to answer.

This is already supported by the data the system has: every Connection is an
observable ACP session, and the control-plane protocol already carries
`promptState.pendingPermissions` for remote instances — the model just needs to be
read across *all* Connections (not only the selected one) and surfaced in the
sidebar. It directly answers "*if the architect has a question, a visible cue gets
me to click back to answer*," works for one flat Connection or a future tree, and
the interaction it establishes is exactly the one rung 3 leans on. Cross-reference
`02-ui-navigation-and-interaction.md` (sidebar + out-of-thread prompts).

## Configure grok's subagents (rung 2)

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

The same rendering is **domain-agnostic** — a non-coding pipeline reads identically:

```
You ▸ Pull today's sales from the POS, reconcile against inventory, email me the summary.

✦ grok (coordinator)
  ▸ 📥 puller (read-only) — exported 142 sales rows from the POS
  ▸ 🧮 reconciler — matched against inventory; 3 variances flagged
  ▸ ✉️ sender — drafted the summary email
  Sent the summary to you. Done.
```

Note the ceiling of rung 1 here: if the reconciler is unsure about a variance, a
grok-native subagent **cannot ask** — it guesses or fails. Making "pause and ask
the operator" possible mid-pipeline is precisely the rung-0 cue (for the
coordinator's own questions) and rung 3 (for a *child's* questions).

## What's new vs. reused (config slice)

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

## Non-goals (config slice)

- **Re-implementing coordination.** grok's `task` system does the spawning and
  routing; we configure and surface it, full stop.
- **A process hierarchy of Connections.** Belongs to rung 3 (the committed
  destination), sequenced after the near-term wins — not in the config-GUI slice.
- **Driving sub-agents directly / human-in-the-loop on a *child*.** Not possible
  with grok-native subagents; it's the whole point of rung 3 and arrives there.
  (Human-in-the-loop on a *coordinator* — answering its own questions across
  conversations — arrives earlier, via the rung-0 attention cue.)
- **Changing the standalone single-connection experience.** "Plain" remains the
  default and is completely unchanged.

## The destination: the steerable fleet (rung 3)

The one thing grok-native subagents structurally cannot do is let a human **watch
and grab the wheel of an individual worker, from any device**. Because that
supervision UX is Grokestrator's heart — and the live prototype of the separate
monetization bet (`strategy-general-case-ai.md`) — this is the **committed
destination** the roadmap builds toward (seeded by rung 2, with rung 0's UX already
proven), not an open-ended "maybe later." It's still sequenced *after* the cheap
wins, and grok-native remains the right tool for fully-autonomous jobs (above) —
but the direction is settled. The shape:

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
- **Shared base "house-rules" agent file + per-agent override.** One overarching
  agents file (the shared base) that other agents *reference* and selectively
  *override*, rather than duplicating config per agent. Maps onto grok's existing
  `~/.grok/agents/` (global) + project `.grok/agents/` layering and the rung-2
  scope toggle; the GUI could make "inherit from base, override here" first-class
  (resolve + diff the effective config). *(Surfaced when grok, mid-test, proposed
  a `[[REFERENCE: path]]` priming convention — the marker mechanism was discarded
  as a no-op; the inherit/override config concept is the part worth keeping.)*
- **How much subagent lineage to surface (rung 1).** Rendering every `task` child
  inline could get noisy. Start collapsed under the owning turn; revisit if users
  want full lineage / the `subagents/` read is worth the disk coupling.
- **Template authority + updates.** When we ship a better "Feature team" template,
  do existing connections that minted from it get offered an update, or stay
  frozen? (Lean: stay frozen; offer a manual "re-apply template.")
- **Child question roll-up (rung 3).** When a real-Connection child raises a
  question, how does it surface? It's both its *own* badged Connection (rung-0 cue)
  *and* something the parent's narrative should reflect ("waiting on reviewer"). How
  do the two views stay consistent without double-prompting?
- **Orchestration locality (rung 3).** Where does the `delegate` routing live —
  host-local (the Mac that owns the Connections drives; remote devices view +
  answer), matching today's "GKSS is the source of truth"? First-stab: yes,
  host-local; remote devices observe and answer, they don't host routing.
- **Non-coding capability surface.** Coding rides MCP + shell tools that mostly
  exist. A winery-style pipeline (POS export, email) needs those integrations as
  MCP servers/skills — is standing those up a Grokestrator concern, a template
  concern, or purely the operator's `.grok/` config?

## Relationship to other documents

- `00-vision-and-north-star.md` — the (revised) north star this serves: lead with
  general-purpose, observable, answerable supervision; coding is one instance.
- `04-conversation-model.md` — the conversation/instance 1:1 rule this preserves;
  multi-instance is sequenced to rung 3 (a soft `parentID` edge, not nested chats).
- `07-client-control-plane-protocol.md` — the broadcast plane rung 1 surfacing and
  any rung-3 work would ride on.
- `09-slash-commands.md` — `/compact` and the command catalog; relevant to seed
  budget at rung 3 and to driving agents generally.
- `connection-semantics` (memory) — GKSS owns the registry; the config-GUI slice
  adds only a `teamTemplate` field and authored `.grok/` files, leaving the 1:1
  instance rule fully intact. Rung 3 extends it with a **soft `parentID` edge**
  (still no nested objects — one Connection stays 1:1 with one grok instance).

---

*Created: 2026-05-30. Revised 2026-06-01: direction is now **both, sequenced** —
near-term = rung 0 (cross-conversation attention cue) + rung 1 (surface
grok-native subagents); rung 2 = the config GUI; **rung 3 (steerable fleet) is the
committed destination**, not indefinitely deferred — because the north star now
leads with observable, answerable, general-purpose supervision, which only rung 3
delivers. Status: design exploration; no implementation yet.*
