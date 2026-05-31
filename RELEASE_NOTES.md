# Grokestrator — Release Notes

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
