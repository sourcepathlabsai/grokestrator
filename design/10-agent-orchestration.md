# Grokestrator — Agent Orchestration

Status: **partially implemented** (2026-06-30) — rung 0 ✅, orchestrated-fleet
(formerly rung 3) substantially ✅ for API brains; rungs 1–2 not built for ACP
agents. **Direction revised 2026-06-30:** dual-path orchestration — ACP agents
use harness subagents (supervision only); API/local brains use Grokestrator
sub-sessions (`delegate`). This document proposes how
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

**Direction (revised 2026-06-30).** Stop fighting harness subagents on ACP brains.
The product splits on **who owns the tool loop**:

| Path | Brain | Who coordinates helpers | What Grokestrator does |
|------|-------|-------------------------|------------------------|
| **Supervised agent** | ACP (grok, Claude Code, …) | The harness (`task` / native subagents) | **Supervise the parent** — stream, permissions, attention, oracles |
| **Orchestrated fleet** | API / local (Cerebras, Groq, OpenAI-compat, onboard, …) | Grokestrator (`delegate` MCP + child Connections) | **Orchestrate** — tree of purpose-built sub-sessions, tool policy, runs |

For ACP agents we do **not** offer Grokestrator sub-sessions or app-side `delegate`
orchestration — that path fights control-plane capture and cannot be enforced at
the ACP boundary (see `12` §ACP vs API). For API/local brains there is no harness;
Grokestrator's mediated fleet **is** the orchestration layer.

Grokestrator's heart remains **observable, answerable supervision** on every
path. On ACP that means the *parent* Connection (rung 0 attention, rung 1 lineage
surfacing, rung 2 harness config). On API brains it additionally means *each child*
is its own watchable, answerable Connection (orchestrated fleet).

The orchestrated-fleet path is the substrate for the separate monetization bet in
`strategy-general-case-ai.md` (general-case workflows on headless/API workers).
ACP supervision serves the free founder/solo-dev tool on its own merits.

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

Two ladders, one product — chosen by brain binding (see direction above).

### ACP path — supervised agent (grok, Claude Code, …)

Ride the harness. Grokestrator does not spawn sub-sessions for these brains.

| Rung | What Grokestrator does | Cost | What you gain |
|---|---|---|---|
| **0 — Attention cue** ✅ | Badge a background Connection (and a global indicator) when it has a pending question/permission | Low | Human-in-the-loop across many conversations *today* |
| **1 — Surface** | Read grok's `task` lineage; render in-process subagents inline in the parent transcript | Low | Visibility into what harness helpers *did* (not live per-child, not answerable) |
| **2 — Configure** | Connection dialogs author `.grok/` agent + role + persona files; harness team templates; project/global scope | Low–med | Set up harness roles/personas once; ride grok's tuned `task` coordination |

ACP agents stay **flat** in the sidebar (one Connection). No `parentID` tree, no
Orchestration MCP `delegate` on the parent.

### API path — orchestrated fleet (Cerebras, Groq, local, …)

No harness subagents — Grokestrator owns coordination.

| Phase | What Grokestrator does | Cost | What you gain |
|---|---|---|---|
| **Fleet core** ✅ (was rung 3) | Each role = a real Connection; soft `parentID` edge; Orchestration MCP `delegate`; team templates | High | **Watch each worker live, answer each worker, steer from any device** |
| **Fleet + DB** | Schema-validated case file (`db.*` tools) | Med | Rigorous data exchange between orchestrator and children |
| **Fleet + triggers** | Standing agents, cron/webhook/row triggers | Med | Push activation for headless workflows |

Orchestrated-fleet is the **only** path where `role` + `parentID` tree nesting,
`delegate`, Run/DAG views, and fleet team templates (Research, Code Review,
Implementation) apply.

How the paths relate:

- **Rung 0** applies to **all** Connections (ACP and API) — any observable session
  can raise a permission/question that pulls the human back.
- **Rungs 1–2** are the **ACP supervision path** — make harness subagents legible
  and configurable. They do **not** graduate into orchestrated fleet; they are the
  complete ACP orchestration story.
- **Orchestrated fleet** is the **API/local path** — for brains without harness
  subagents, and for general-case workflows that need every step watchable and
  gateable. Fleet team templates pin API/local brains on orchestrator + children.

### When each path is the right answer

| Job shape | Right path | Why |
|-----------|------------|-----|
| Coding with grok/Claude; harness `task` does the team work | **Supervised agent** (ACP) | Harness coordination is tuned; fighting it loses |
| Headless/API worker; no harness; each step must be visible | **Orchestrated fleet** | Grokestrator is the only coordinator |
| General-case SMB (quote → approve → send) on headless models | **Orchestrated fleet** | Mediated `delegate`, gates, case file |
| "Ship this feature, don't bother me" on grok | **Supervised agent** + harness | Strictly better than app-side fleet on ACP |

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
- **A process hierarchy of Connections on ACP agents.** Belongs to orchestrated
  fleet (API/local brains only) — not the ACP supervision path.
- **Driving sub-agents directly / human-in-the-loop on a harness *child*.** Not
  possible with grok-native subagents; orchestrated fleet provides per-child HITL
  on API brains only.
  (Human-in-the-loop on a *coordinator* — answering its own questions across
  conversations — arrives earlier, via the rung-0 attention cue.)
- **Changing the standalone single-connection experience.** "Plain" remains the
  default and is completely unchanged.

## Orchestrated fleet (API / local brains only)

Grok-native subagents cannot let a human **watch and grab the wheel of an individual
harness helper** — but we no longer try to replicate harness coordination on ACP
brains. Orchestrated fleet is **only for API/local brains**, where Grokestrator
*is* the coordinator and every worker is a first-class Connection.

Shape (largely shipped for API brains; see `11`, `PROJECT_STATE`):

- Each role is a **real Connection** (own process/session, own chat, own sidebar
  node) on the broadcast/subscription plane — visible + steerable on every device.
- A Grokestrator-hosted **Orchestration MCP** exposes `delegate(child, task)`;
  the router sends work to a named child and returns its result.
- Soft `parentID` edge + sidebar tree nesting — **only** for orchestrated-fleet
  Connections.
- Fleet **team templates** (Research, Code Review, Implementation) create
  orchestrator + children with **API/local brains** — not ACP agents.

First-stab calls (unchanged):

- PR-merge as a thin Grokestrator-gated action while workers do the PR/CI work.
- `delegate` returns structured errors for retry; human escalation after repeats.
- Orchestration host-local (GKSS drives; remote devices observe + answer).
- Child results should use a **structured finding envelope** (not prose-only) so
  synthesis and gates are mechanical (`11` Phase 2+).

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

- `11-orchestration-platform.md` — **the implementation plan that commits to and
  goes past rung 3**: orchestrator/agent Nodes, an in-app Orchestration MCP, an
  embedded DB, and a built-in oracle engine. Rung 3 below is its on-ramp.
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

*Created: 2026-05-30. Revised 2026-06-01: both, sequenced — rungs 0–2 for ACP
harness integration; rung 3 as steerable fleet. **Revised 2026-06-30: dual-path
orchestration** — ACP agents use harness subagents (supervision path, rungs 0–2);
API/local brains use orchestrated fleet (`delegate` + tree). Do not offer Grokestrator
sub-sessions on ACP agents. See `PROJECT_STATE.md`, `11` §0, `12` §ACP vs API.*
