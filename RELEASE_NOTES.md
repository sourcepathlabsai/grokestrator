# Grokestrator — Release Notes

## v0.3.5-alpha — 2026-07-01

### Role restart + clear history (#185)

- **Transition barrier** — role-save restarts and `clearHistory` / `sendPrompt` no longer race;
  ACP `initialize` + `session/new` complete during restart before the Connection accepts prompts.
- **Gist preserved** — clearing the display transcript no longer drops a pending session gist
  before the first reprimed turn.

### Signed distribution pipeline (#143)

- **Paid Apple Developer enrollment live** — team `GS8DPK5RPN` wired in `project.yml`.
- **`scripts/release-preflight.sh`** — verifies Developer ID cert, notarization creds, and App Store Connect API key before release.
- **`scripts/build-release.sh`** — one command for signed Mac DMG + TestFlight iOS upload.
- **API-key notarization** — `build-mac-release.sh` supports App Store Connect API keys (CI) in addition to local `notarytool` keychain profiles.
- **`.github/workflows/signed-release.yml`** — tag/manual workflow for Gatekeeper-clean Mac GitHub Releases + TestFlight upload when repository secrets are set.

## v0.3.4-alpha — 2026-07-01

### ContextManager (#137)

- **Budget ladder** — `ContextManager` escalates from tier-0 lossless extraction to tier-1
  compaction when history exceeds the ~12k working-context budget.
- **Fast-tier LLM summarization** — `FastTierSummarizer` via `/chat/completions` when the
  host `fast` tier is OpenAI-compatible.
- **Local-embedding retrieval** — `EmbeddingRetriever` pulls relevant middle-history
  snippets via `/embeddings` (`nomic-embed-text`); `KeywordRetriever` when offline.
- **Gist oracle** — `GistOracle` verifies compacted gists still name key files, decisions,
  and "remember" notes; pins missing anchors before injection.
- **Deterministic fallback** — `SessionGist.tier1` bullet summary when LLM paths fail.

## v0.3.3-alpha — 2026-07-01

### Multi-level tree + parallel delegate (#136)

- **Recursive fleet sidebar** — arbitrary-depth nesting on Mac; iOS mirrors the host tree.
- **Nested orchestrators** — sub-orchestrators under top-level orchestrators; cycle-safe
  parent assignment.
- **Parallel `delegate`** — orchestrators may fan out to multiple descendants concurrently;
  each delegation is tracked as its own run in the sidebar.
- **API fleet brains** — parallel `delegate` tool calls in one model turn execute concurrently
  (not sequentially).

## v0.3.2-alpha — 2026-07-01

### Orchestration MCP extensions (#135)

- **`task.report`** — fleet child agents report progress or completion; active delegation
  runs in the sidebar update live.
- **`node.configure`** — orchestrators push `ToolPolicy` to a named child (capability +
  optional tool allowlist).
- **`trigger.schedule`** — standing agents on interval (`every 30m`, `every 1h`) or event
  subscription (`event:pr-merged`); schedules persist across restarts.
- **`trigger.fire`** — emit an event to wake subscribed children; skips when a child is
  already mid-delegation.

### Role transition with compact context (#177)

- **Edit Role → Restart with compact context (default).** Changing a Connection's role
  restarts the agent with a fresh session so the old role cannot linger in multi-turn
  memory. Prior work is carried forward as a **tier-0 session gist** — user prompt and
  final outcome per turn, not the full transcript — injected once in the hidden preamble.
- **Alternatives:** re-prime only (legacy behavior) or fresh restart with no carry-forward.
- **Transcript marker** when context is carried or restarted, so the UI shows where the
  role change happened.

---

## v0.3.1-alpha — 2026-07-01

Incremental alpha on v0.3.0. **Dual-path orchestration is now enforced in the app** —
ACP brains supervise harness subagents; API/local brains use the orchestrated fleet —
plus first-class editors for both team-template paths.

### Dual-path orchestration (ACP + fleet)

- **Two coordination paths, gated in UI.** grok and Claude Code Connections use the
  **supervised ACP path** (harness `task` / native subagents). API and local brains use
  **Create Fleet Team** — child Connections coordinated via `delegate` MCP. The app
  picks the path from the brain binding; legacy mixed trees get a migration hint.
- **Harness subagent lineage in the transcript.** When grok delegates via `task`, tool
  groups show `▸ subagent …` rows enriched from on-disk lineage — type, description, and
  status — so parallel subagent work is visible without opening grok's files.
- **Grok Config editor.** Sidebar → **Grok Config…** on an ACP Connection opens a
  tabbed `.grok/` writer (Connection, Agent, Team, Advanced). Pick a harness template,
  preview the file diff, and apply to project or user scope — agents, roles, personas,
  and TOML land where grok expects them.

### Team template editors

- **Fleet team templates (Settings → Teams).** Create and edit custom orchestrated-fleet
  blueprints — title, summary, members, role prompts, auto-approval. **Draft with grok**
  and **Draft all prompts** turn plain member descriptions into role prompts in place.
- **Harness templates (Settings → Teams → Harness).** Built-in presets (Plain, Feature
  Team, Research Team) plus custom ACP harness templates for **Add Connection** and
  **Grok Config**. Edit agent, roles, and personas; grok-assisted drafting for each
  section. Custom templates write `.grok/` files when you apply them.

### Platform / hardening (from dual-path slice)

- **Run view** — sidebar delegation DAG lists active and finished `delegate` runs with
  status and quick jump to child Connections.
- **Orchestration SQLite** — per-Mac workflow DB; orchestrators register schemas and
  read/write via `db.*` MCP tools (inspector shows registered tables).
- **Verb normalization** — API tool loops and ACP permission adapters map into one
  canonical governance vocabulary before oracle enforcement.

---

## v0.3.0-alpha — 2026-06-30

Third alpha. Grokestrator is no longer a grok-only Mac client — it is a **multi-brain
orchestration control plane** with a runtime design oracle, team delegation, and polished
supervision UX. Includes everything from v0.2.0-alpha below.

### Platform

- **Model-agnostic runtime.** Swap brains per Connection: grok, Claude Code (ACP), Groq,
  Cerebras, Gemini, xAI — via brain catalog, host-local API keys, and per-Node editors.
- **Orchestration spine.** Tree of Connections (`parentID`), Orchestration MCP with
  `delegate(child, task)`, team templates (Code Review / Implementation / Research).
- **Design oracle (active).** Project invariants in `design/oracle/`; shadow → enforce on
  permission boundary; orient-on-read preamble; verdicts in inspector + `oracle-verdicts.jsonl`.
- **MCP infrastructure.** Host-owned MCP server registry; per-Node grants; API brains reach
  granted servers via in-app MCP client.

### Supervision UX

- **Prompt queue** — messages typed during streaming queue instead of dropping.
- **File attachments** — drag-and-drop into the composer.
- **Markdown rendering** — VS Code-style assistant messages; full-message copy on Mac and iOS.
- **Dock bounce** — alerts when a permission/question arrives and the app isn't frontmost.
- **Sidebar busy state** — live activity status on background Connections.
- **Transcript accumulators** — long tool-use turns collapse to summary rows (layout stability).
- **Concurrent permissions** — Claude parallel tool use no longer freezes the session.

### Fixes / hardening

- ACP permission verb mapping for Claude Code (oracle no longer shows `unknown` for every action).
- Session cwd shown correctly in inspector; agents never run at filesystem root.
- Stable Mac code signature (fewer repeated TCC prompts).
- Selectable transcript messages; grok-generated images render in chat.

### Agent / contributor docs

- `AGENTS.md` / `CLAUDE.md`: OODA helix operating mode, PR-per-slice delivery gate,
  post-merge issue hygiene. See repo — not user-facing in the app.

### Install

Same as v0.2.0-alpha: build from source via XcodeGen, or unsigned DMG on version tags.
Signed/notarized distribution and TestFlight remain on the roadmap.

---

## v0.2.0-alpha — 2026-05-31

Second alpha. A round of conversation-surface and remote fixes on top of the
first alpha — the transcript is calmer, the composer behaves, and a turn that
asks you something now has real UI for it. Includes everything from the
(untagged) v0.1.1-alpha remote fixes below.

### New

- **Structured questions.** When grok asks you something mid-turn
  (`_x.ai/ask_user_question`), it now renders as a native question card — labelled
  options plus a free-text field — instead of falling back to a parsed text hack.
  Works across devices (answer on the Mac or a remote iPhone/iPad; first to answer
  wins). The old `[[CHOICES]]` parsing stays as a safety net.
- **Live task checklist.** grok's plan renders as a single in-place checklist that
  updates as it works (pending → in-progress → done), mirroring its TUI plan view,
  instead of re-printing the whole list on every change.

### Fixed / improved

- **The prompt box wraps correctly.** The composer is now backed by a real text
  view, so a long line soft-wraps to the box's width — including when the inspector
  panel shrinks it, and for a freshly typed line in the narrow box. (The old field
  let text run off-screen on one line.)
- **The chat respects your scroll.** While grok streams a reply, the transcript
  only auto-scrolls if you're already at the bottom — like a log console. Scroll up
  to read and new text appends quietly without yanking you back down; return to the
  bottom to re-arm the follow.
- **Tool calls fold away.** A finished turn's `🔧 tool(...)` rows collapse into one
  expandable "N tool calls" group — the same treatment as the thought process — so
  completed turns aren't buried under tool noise. They still show live while the
  turn runs.

## v0.1.1-alpha — 2026-05-30

Bug-fix release for the remote-client path (a Mac/iPad/iPhone driving another
Mac's grok over Tailscale). All issues surfaced in alpha testing.

### Fixed

- **Remote video now plays on the Mac client.** The Mac was pulling the whole
  file through the control channel (which could deadlock and never start); it now
  streams over HTTP from the host's media server — progressive and seekable — the
  same path iOS already uses.
- **The host Mac updates live when a turn is driven from another device.** A
  prompt sent from a remote client now streams onto the host's own screen in real
  time. Previously the host showed nothing unless that conversation was already
  open — it only subscribed to the live broadcast when the view appeared.
- **Remote servers can always be removed.** Each remote-server row now has a
  visible **Remove** (trash) and **Edit** (pencil) button in its header, with a
  confirm step — no more hunting for a right-click menu. Removal works regardless
  of connection state (connecting / failed / offline) and persists across restart.
- **A stuck "Connecting…" server can recover.** An interrupted connect attempt no
  longer wedges the link in `connecting` forever (which had blocked every retry);
  reconnects and the LAN→Tailscale fallback now proceed reliably.

## v0.1.0-alpha — 2026-05-29

First alpha. Grokestrator is a control console for **grok agents** (`grok agent stdio`):
launch and drive agents on your Mac, and pick up the same live session from another
device over your Tailscale network.

### Highlights

**Orchestrate grok agents**
- Launch local grok connections on the Mac (`grok agent stdio`), with a working-directory
  picker + validation (blocks a non-existent cwd; expands `~`).
- One connection = one grok instance, with persisted history that survives restarts.
- Archive (reversible) or permanently delete a connection in one step.

**Remote & multi-device (Tailscale)**
- Turn on **Settings → Server → "Run server on this Mac"** to share the Mac's connections.
- Drive the same session from an **iPhone/iPad** or another Mac — the host is the source of
  truth, so every device sees an identical transcript (prompts, thinking, answers) in real time.
- **LAN-first dual-address**: a connection stores a Local IP *and* a Tailscale address and
  tries the LAN first (full speed) before falling back to Tailscale; the sidebar shows which
  path is active ("· LAN" / "· Tailscale").
- Add / **edit** / remove remote servers on either platform; connections auto-reconnect.

**Conversation**
- Slash-command popup (type `/`) that fills in **live as grok's MCP servers finish loading**.
- Agent thinking streams live, then is erased when the final answer lands (ephemeral thoughts).
- Quick-reply buttons for multiple-choice asks; permission prompts surfaced over the thread.
- Clear a connection's chat history (syncs to every connected device).

**Media**
- Inline images; **video plays via native HTTP streaming** (progressive, scrubbable) from the
  Mac's media server — works on LAN and Tailscale.

**Instance Inspector (right panel)**
- Model + context window, **live context-usage meter** (ticks up during a turn),
  **MCP server load state** ("connecting 2/4… → 4/4 connected · 18 tools"), and the
  slash-command catalog.

**App**
- SourcePath-branded **About** and **Help** windows (⌘?).

### Install

- **Mac — two ways:**
  - **Clone & build from source** (recommended if you have Xcode): `git clone`, then
    `xcodegen generate && open Grokestrator.xcodeproj` and run the **GrokestratorMac** scheme —
    no Gatekeeper hoops because it's your own local build. See the README's *Getting Started*.
  - **Unsigned `.dmg`** (`Grokestrator-0.1.0-unsigned.dmg`, no Xcode needed): first launch needs a
    one-time Gatekeeper override — see *"How to open Grokestrator.txt"* inside the DMG
    (System Settings → Privacy & Security → "Open Anyway", or
    `xattr -dr com.apple.quarantine /Applications/Grokestrator.app`).
- **iOS — build & deploy yourself:** there is no downloadable iOS build yet. You must
  **build from source in Xcode and deploy to your own device** as a developer (the
  **GrokestratoriOS** scheme + a free Personal Team gives a 7-day cert; an Apple Developer
  account gives a longer one). A public **TestFlight** build will come once the paid Apple
  Developer enrollment clears.

### Known limitations

- **iOS distribution** is sideload-only until the paid Apple Developer enrollment clears (then TestFlight).
- **Remote audio / file preview / large-image fullscreen** still use the older chunked transfer
  (fine for small/single-chunk; can stall for large multi-chunk files) — migrating them to the
  same HTTP path as video is the next media task.
- **Remote video** needs reasonable bandwidth; on a slow remote Tailscale link it buffers. Same
  Wi-Fi (LAN path) is dramatically faster.
- MCP **per-server** detail (which one failed) isn't surfaced structurally — grok only reports an
  aggregate connected count; `/mcps` shows per-server detail on demand.

### Notes for the next release

- Convert audio/files/full-image to the HTTP media path; consider per-file Range caching.
- Swap the iOS signing `DEVELOPMENT_TEAM` to the org once the paid account clears; switch
  distribution to TestFlight via `scripts/build-ios-release.sh`.
