---
id: INV-no-destructive-shell
severity: critical
state: active
---
Shell commands must not irreversibly destroy data without human confirmation.

Irreversible, system-unrecoverable shell effects — recursive force-remove, filesystem format,
raw device writes, force-push, fork bomb. The rules below are high-recall (they over-fire by
design — the threat-DB pattern), so a match *flags for human/judge review*; it does not
silently block. They live inline so any runtime — not just Grokestrator — can enforce this
straight from the repo.

## Detect (any match → suspect)

- recursive force-remove: `\brm\s+(-[a-zA-Z]*\s+)*-?[a-zA-Z]*[rf][a-zA-Z]*`
- filesystem format: `\bmkfs(\.\w+)?\b`
- raw disk write: `\bdd\b.*\bof=/dev/`
- redirect over device: `>\s*/dev/(sd|disk|nvme)`
- git force-push: `\bgit\s+push\b.*(--force\b|-f\b)`
- fork bomb: `:\(\)\s*\{\s*:\|:`
- recursive chmod of root: `\bchmod\s+-R\s+.*\s+/\s*$`
