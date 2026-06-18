---
id: INV-external-comms-reviewed
severity: high
state: active
---
Actions that communicate externally (email, posting, messaging) must be human-reviewed before
they send.

External communication is irreversible and speaks for the user — the canonical "generate it,
then put it in front of a human before sending" case. There's no precise detector yet: this
invariant is enforced by *classification* (any action whose side-effect is `communicate` and
crosses the system boundary escalates) and stands as grounding context a judge reads when an
external-comms action is in question.
