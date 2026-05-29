# Grokestrator — Release Notes

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

- **Mac:** unsigned `.dmg` (`Grokestrator-0.1.0-unsigned.dmg`). First launch needs a one-time
  Gatekeeper override — see *"How to open Grokestrator.txt"* inside the DMG (System Settings →
  Privacy & Security → "Open Anyway", or `xattr -dr com.apple.quarantine /Applications/Grokestrator.app`).
- **iOS:** sideload from Xcode with a free Personal Team (7-day cert). TestFlight comes once the
  paid Apple Developer account clears.

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
