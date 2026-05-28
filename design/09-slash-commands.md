# Slash Commands in Grokestrator

> Status: implemented (PR following PR #27). Reflects grok 0.2.3 behavior, verified by probing `grok agent stdio` directly and by inspecting real session logs.

Grok exposes slash commands from **two distinct sources** (see grok docs `~/.grok/docs/user-guide/04-slash-commands.md`):

| Source             | Handled by              | Reachable over ACP? |
| ------------------ | ----------------------- | -------------------- |
| **Shell builtins** | The agent backend (`xai-grok-shell`) | **Yes** — advertised in the `initialize` result `_meta.availableCommands` (and refreshed via `available_commands_update` session/update). |
| **Pager builtins** | grok's TUI frontend (`xai-grok-pager`) | **No** — they never reach the wire. Grokestrator replaces the pager, so these are simply not present in `availableCommands`. |
| **Skills** (`user_invocable: true`) | The agent backend | **Yes** — advertised alongside shell builtins. |

A naïve implementation only surfaces what's advertised. That misses useful commands users expect (`/imagine`, `/imagine-video`, `/new`, `/model`, `/plan`, `/btw`, …) because those are pager-side affordances, not wire commands.

## What we surface

The Instance Inspector and the composer slash-command popup show **the union of**:

1. `availableCommands` from `initialize._meta` (instance-specific; includes installed skills and plugins).
2. A curated **catalog of documented built-ins** (`GrokBuiltinCommands.catalog` in `GrokestratorMac/GrokBuild/AgentCapabilities.swift`).

Dedup is by name; the advertised entry wins for any collision (it's authoritative for that instance). The result is sorted alphabetically.

### Catalog (what's in `GrokBuiltinCommands.catalog`)

Session management: `/new`, `/load`, `/compact`, `/context`, `/session-info`, `/share`, `/rename`
Model & mode: `/model`, `/always-approve`, `/plan`
Memory (experimental): `/flush`, `/dream`
Plugins / hooks: `/plugins`, `/hooks`
Media: `/imagine`, `/imagine-video`
Scheduling: `/loop`
Other: `/mcps`, `/feedback`, `/btw`

### Deliberately excluded

Pure terminal-UI affordances that control grok's TUI (which Grokestrator replaces) are **not** in the catalog: `/exit`, `/quit`, `/home`, `/welcome`, `/theme`, `/multiline`, `/compact-mode`, `/vim-mode`, `/terminal-setup`, `/release-notes`.

## The `/imagine` reality check

`/imagine` is the most-asked-for command and a useful case study.

- Per the doc it's listed under "Media Generation" without a source label. It is **not** in `availableCommands`, so it's not a shell builtin we can invoke as a wire command.
- However, real session logs (`~/.grok/sessions/.../updates.jsonl`) show the agent invoking an **`imagine` tool** as a `tool_call_update` (`kind: "other"`, `title: "imagine: …"`). The agent *has* the tool; whether it's available in a given session depends on initialization succeeding.
- When grok is launched with a stripped environment (the Finder-launched `.app` case before PR #27), tool-call prerequisites can fail and grok degrades to bash. With PR #27's `LoginShellEnvironment`, the launched process gets the real shell environment, so the `imagine` tool is much more likely to be available.

**Practical takeaway:** `/imagine` in the popup is a discoverability hint — typing `/imagine <prompt>` lets the agent recognize the intent. Whether the underlying tool fires depends on the agent's session state, which the environment fix materially improves.

## Wire details

| Phase             | Where commands come from                                              |
| ----------------- | --------------------------------------------------------------------- |
| At init           | `initialize` result `_meta.availableCommands[].{name, description, input.hint?}` |
| At runtime        | `session/update` with `update.sessionUpdate = "available_commands_update"` and `update.availableCommands[]` (same shape) |

Both paths funnel through `GrokBuildSessionClient`, then `capabilities.commands = GrokBuiltinCommands.merged(advertised:)`, then `ConversationViewModel.slashCommands` for the popup, and `InstanceInspectorView` for the inspector list.

The composer popup applies a *prefix* filter on the typed token (the text after `/` up to the first space), so `/im` narrows to `/imagine` and `/imagine-video`. Up/Down navigates, Return inserts `/<name> ` (so the user keeps typing any argument), Esc dismisses.
