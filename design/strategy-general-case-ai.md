# Strategy — General-Case AI ("agentic AI for the rest of us")

> **This is a SEPARATE bet from Grokestrator-the-product.** It is a *monetization
> strategy* for a transferable concept — the **supervision/approval control plane** —
> as a general-case AI tool for non-technical operators. It is **not** Grokestrator's
> roadmap. Grokestrator stays a free, focused, personal/solo-dev tool (see
> `00-vision-and-north-star.md`); this document is where the commercial thesis lives,
> linked but kept apart so it can't quietly redefine the free tool.
>
> Status: **strategy exploration — gated, not committed.** Nothing here is built or
> promised. The next action is a cheap validation test (below), not a platform.

## One-line thesis

A GUI where a **non-technical operator** can run an AI agent against their real
business systems, **watch it work, and approve sensitive actions** — the agent acts
task-by-task under a business workflow; nothing irreversible (an email, an invoice, a
payment) happens without a human OK.

## What's transferable from Grokestrator (and what isn't)

The asset is **not** Grokestrator-the-app, grok, or the local-Mac-server deployment.
It is the **supervision/approval control plane** Grokestrator proves out:

- **Reuse (~80%):** the ACP-style control plane — stream an agent's reasoning, render
  its `tool_call`s, surface out-of-thread permission/question overlays, "always-allow"
  memoization, and the multi-device broadcast. This is the differentiated, demoable
  surface. Keep **ACP as the generic wire protocol** (it isn't grok-specific).
- **Do NOT carry over:**
  - **grok as the brain.** grok is a *coding* agent (file-edit/bash). Business action
    (CRM, QuickBooks, email) needs a business tool-calling LLM + planner. Swap the brain;
    keep the wire protocol and the supervision UX.
  - **The local-Mac-server / customer-hardware deployment** (see "Hard truths").
  - **General-purpose scope.** "Anything for anyone" is a focus trap (see "Wedge").

## Hard truths (from the strategy panel, 2026-06-01)

These are the panel's conclusions; recorded so we don't relitigate or repeat the
mistakes:

1. **"Local on the business's own hardware" is a liability, not the edge.** For a
   no-IT SMB, an on-prem box makes *us* the unpaid MSP (patches, dead SSDs, an update
   that bricks the agent, "your agent on our hardware emailed the wrong client"). It's
   the Mac-as-server problem reborn at sites with no IT; caps at ~5 accounts; no clean
   liability story. Local execution is also **table stakes** (Claude Code, Codex CLI,
   Manus "My Computer", n8n self-hosted all run local). **Host it per-tenant ourselves;
   reserve "local" only where a specific integration or compliance/air-gap rule demands
   it.**
2. **Approval-gating is table stakes, not a moat.** A UI pattern + state machine any
   competitor ships in a sprint; incumbents already have permission prompts, and
   human-in-the-loop is being commoditized and even regulation-driven (EU AI Act Art. 14,
   CA SB-833). *Necessary ≠ defensible.*
3. **The real moat candidates** (in order): (a) becoming the **workflow
   system-of-record in one vertical** — data gravity from task state, approvals,
   outcomes, and per-customer tuned rules = the switching cost; (b) **vertical
   integration depth + a trust/liability story** (know exactly how one trade's
   quote→schedule→invoice connects; stand behind ~99% reliability; tamper-evident audit
   trail). The **supervision GUI is the wedge** (what demos and closes), not the moat.
4. **The killer risk is the trust cliff**, not the engineering. The whole bet rests on
   a non-technical owner catching a subtly-wrong invoice in an approval modal — and that
   owner is, by definition, the *least* equipped to. If supervision doesn't measurably
   raise the trust ceiling, we've built a slow assistant, not autonomy.

## The sharpest narrow version (the wedge)

Resist "CRM" and "general-purpose." Win one seam first.

- **Vertical:** one trade-service niche (e.g. HVAC / plumbing / electrical), sold to the
  owner-operator.
- **Jobs (≤3, <5 action types):** (1) draft a **quote** from a job photo / voicemail /
  email; (2) owner **approves and sends** it in the GUI; (3) **follow-up + convert to
  invoice** (QuickBooks). Nothing leaves without an OK.
- **Explicitly out of scope:** generic "CRM" (that's Salesforce/HubSpot/Monday's teeth),
  multi-vertical, customer-owned hardware, full autonomy, a Windows/Linux local agent,
  and the grok brain.

## Business model / GTM

- **Consulting-led that productizes.** Founder is solo + part-time: install and *manage*
  it as a service (cloud per-tenant, **not** their box). ~**$1–3k setup + $300–1k/mo**
  per shop. This funds the work and forces real integration learning; productize the
  repeated parts.
- **Sell the outcome, not the architecture.** "Quotes out same day, nothing sent without
  your OK" — never "local AI agents." Non-technical buyers buy results + liability
  transfer.
- **Motion:** founder-led, one vertical, referral-driven within that trade community; the
  supervision GUI is the demo that closes. (GoHighLevel proves the agency/reseller motion
  monetizes the "AI for small business" space — but it leans toward *removing* the human,
  which makes our **approval bet a genuine differentiator** for liability-sensitive owners.)
- **Honest framing for a part-time solo founder:** services-led-that-productizes is the
  *right* model, not a downgrade — it self-funds, builds the integration moat, and has a
  real paying customer from day one.

## Competitive landscape (web-grounded, 2026-06-01)

| Player | What it is | How it differs from this thesis |
|---|---|---|
| **n8n (self-hosted)** | OSS workflow + AI-agent node on your own box, 400+ integrations | Builder for technical tinkerers; no CRM, no non-technical supervision UX |
| **Lindy / Relevance AI / Gumloop / Cognosys** | Hosted "AI employee" builders ($50–250+/mo) | Exactly the cloud-sandbox model; act via integrations, not local |
| **GoHighLevel / HubSpot** | CRM-at-the-center + SMB AI workflow; GHL white-label/agency-resold ($97/mo) | Own the CRM ground; lean toward *removing* the human (opposite of our approval bet) |
| **UiPath / Kognitos** | RPA→agentic, on-prem + governance | Enterprise-priced; 30–50%/yr maintenance treadmill; not SMB-operable |
| **Manus "My Computer" / Claude Code / Codex** | Local agent, deep FS/terminal, step approval | The real supervision-UX lookalikes; but terminal-flavored, dev-centric, not workflow/CRM-governed |

**White space:** the *intersection* — a non-technical operator's GUI where a business
workflow decides which actions are auto vs. gated, the operator watches the agent reason
and answers it, and actions run against the business's systems. **No one occupies that
exact seam — but each edge is contested and the seam is thin and shrinking.** Attractive
as a **consultant-delivered managed service for a solo founder**, not as a defensible
standalone venture (at least not yet).

## Validate before building (the only near-term action)

Retire the trust cliff first, with **zero platform**:

1. Find **one real trade shop** (owner-operator, quote→invoice pain).
2. **Wizard-of-Oz it ~2 weeks:** run grok/Claude + QuickBooks/Gmail tools *by hand* on
   real jobs; present drafts to the owner in a barebones approval screen.
3. **Measure:** does review take **<10 s**, does the owner **catch errors we deliberately
   seed**, and **will they pay**?
4. **Gate:** a signed, paying design-partner **before** a line of platform is written.

### Kill criteria (≈90 days)

If we can't get a paying design-partner **and** <10 s review **and** ~99% reliability on a
tiny (<5 action-type) set → **stop, and fall back to shipping the focused free dev tool.**
A lovable, finished Grokestrator beats an unshippable everything-platform.

## Relationship to Grokestrator

- **Grokestrator** (`00-vision-and-north-star.md`) stays a **free, focused, personal /
  solo-dev tool** — "use it if you want." Its supervision slice (the rung-0 attention cue
  + a minimal rung-3 observable, answerable child, see `10-agent-orchestration.md`) is
  useful to that audience *on its own merits* — **and** it is the live prototype of this
  strategy's interaction model, de-risked on the founder's own work.
- **This document** is the **separate commercial bet**. It reuses the *concept* (the
  supervision/approval control plane), not the app, the brain, or the deployment. It is
  earned only by passing the validation test above.

---

*Created 2026-06-01. Separate from Grokestrator's product design; linked via
`00-vision-and-north-star.md` and `10-agent-orchestration.md`. Grounded in a multi-lens
strategy analysis (market/technical/moat/bear + synthesis). Strategy exploration — gated,
not committed.*
