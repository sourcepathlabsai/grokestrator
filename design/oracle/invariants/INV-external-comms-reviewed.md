---
id: INV-external-comms-reviewed
severity: high
state: active
---
Actions that communicate externally (email, posting, messaging) must be human-reviewed before
they send.

External communication is irreversible and speaks for the user — the canonical "generate it,
then put it in front of a human before sending" case. Classification also escalates any action
whose side-effect is `communicate` and crosses the system boundary; the rules below are
high-recall payload checks that catch outbound comms even when classification is unknown.

## Detect (any match → suspect)

- send email: `(?i)\bsend\s+email\b`
- smtp: `(?i)\bsmtp\b`
- sendmail: `(?i)\b(sendmail|mail\s+-s)\b`
- mailto: `(?i)mailto:`
- slack webhook: `(?i)hooks\.slack\.com`
- slack message: `(?i)\bslack\b.*\b(post|send|message)\b`
- discord webhook: `(?i)discord\.com/api/webhooks`
- curl POST: `(?i)\bcurl\b[^\n]*(-X\s+POST|--request\s+POST)\b`
- tweet: `(?i)\b(tweet|twurl)\b`
- gh comment: `(?i)\bgh\s+(issue|pr)\s+comment\b`
- post to channel: `(?i)\bpost\s+(to|message)\b`
- webhook: `(?i)\bwebhook\b`
- notify user: `(?i)\bnotify\s+user\b`