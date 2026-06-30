# CLAUDE.md

Project agent guidance lives in **[AGENTS.md](AGENTS.md)** — read it first. It is the
orient-on-read entry point and defines two standing duties: **orient on the design
corpus** (repo `design/*.md` + the Obsidian `4-Concepts/` notes) before substantial
work, and **aggressively maintain the strategic record in Obsidian** (strategic
goals / oracles / reasoning — not operational decisions).

# Tool usage

- **Use the Edit tool for file edits.** Do not delegate edits to Codex agents, write
  Python/sed scripts to modify files, or use any other indirect mechanism. The Edit
  tool exists for this purpose — use it directly.
- Reserve the Task tool for research, exploration, and planning — not for making
  code changes that you can make yourself.

# Delivery (mandatory)

See **AGENTS.md §4**. Every completed slice → **open a PR** → list fixed issues →
**give the PR link** → **await merge** → do not start the next slice until merged.
When merge is reported → **comment on each fixed issue** (which PR, link) and **close**
if still open. Warn the human if they ask for more work while a PR is still open.
