# CLAUDE.md

Project agent guidance lives in **[AGENTS.md](AGENTS.md)** — read it first. It is the
orient-on-read entry point.

# Mode of operation (mandatory)

**You must work in the OODA helix** — Observe → **Orient** → Decide → Act. See
**AGENTS.md §0**. **Orient is load-bearing** (synthesis through doctrine and design
intent; derive the real mission). Skipping Orient = barreling; never Acting = timidity.
Helix, not flat loop: each Act feeds re-Orient; delegation spawns sub-helices.

**Why:** (1) order the backlog by best current judgment against goals/design/intent —
priority is **fluid** as you learn; (2) make the thought process **explicit** so any
LLM can pick up the work. Show Observe → Orient → Decide reasoning; say **why this slice
now**.

Standing duties (the Orient axis made operational):
- **Orient on the design corpus** (§1) before substantial work
- **Maintain the strategic record in Obsidian** (§2) — goals / oracles / reasoning, not
  operational trivia

# Tool usage

- **Use the Edit tool for file edits.** Do not delegate edits to Codex agents, write
  Python/sed scripts to modify files, or use any other indirect mechanism. The Edit
  tool exists for this purpose — use it directly.
- Reserve the Task tool for research, exploration, and planning — not for making
  code changes that you can make yourself.

# Delivery (mandatory)

See **AGENTS.md §4**. Every completed slice → **`scripts/certify-pr.sh`** → **open a PR**
→ list fixed issues → **give the PR link** → **await merge** → do not start the next
slice until merged.
When merge is reported → **comment on each fixed issue** (which PR, link) and **close**
if still open. Warn the human if they ask for more work while a PR is still open.
