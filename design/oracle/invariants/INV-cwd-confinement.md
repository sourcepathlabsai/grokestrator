---
id: INV-cwd-confinement
severity: high
state: active
detector: DET-path-escape
---
File actions must stay within the node's working directory.

A node is sandboxed to its working directory; a path that resolves outside it is an
out-of-bounds reach. Checked precisely by resolving the action's path argument against the
cwd — a deterministic fact, so this detector *decides* (blocks) rather than suspects. The
precise check is a runtime hook (`DET-path-escape`) because it needs structured arguments,
not just a string match.
