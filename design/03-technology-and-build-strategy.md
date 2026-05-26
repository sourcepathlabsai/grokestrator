# Grokestrator — Technology and Build Strategy

> **⚠️ HISTORICAL / SUPERSEDED**
>
> This document contains the original technology evaluation that locked in **Tauri 2 + Rust backend + Svelte**.
>
> That direction was abandoned after:
> - Extended painful debugging (manifest-path fights, PATH pollution from ~/.grok/bin, missing Rust, tauri.conf.json schema battles, "just dev" watcher failures).
> - Honest assessment that a local stdio + Tauri model made the actual desired use case (iPhone client with voice while driving + powerful stationary dev Mac as the real server + seamless Tailscale experience across devices) impractical or impossible.
>
> **Current direction (locked after the pivot)**: Pure native Swift + SwiftUI.
> - Single Xcode workspace.
> - `GrokestratorCore` Swift Package (already implemented — see commit `cdb9a24` on `feat/initial-core-package-structure`).
> - `GrokestratorMac`: hybrid client + server app (direct `Process` management of `grok` instances, auto-restart, no tmux in v1).
> - `GrokestratoriOS`: client-only.
> - Tailscale for all client ↔ server connectivity.
>
> See `PROJECT_STATE.md` for the live snapshot and rationale.
>
> The evaluation table and "Recommended Direction" sections below are retained purely for archaeology.

---

## Overview

This document captures the technology and tooling strategy for Grokestrator. It reflects the current understanding of project goals, constraints, and priorities as of May 2026.

The choice of technology is not being made purely on technical merit, but on how well a given stack supports the actual objectives of the project.

---

## Project Goals and Priorities

The following goals are treated as equally important:

1. **Personal Utility**  
   Build a tool that the creator actually wants to use daily — comfortable, high-fidelity, and genuinely better than switching between multiple Grok Build console sessions.

2. **Visibility / Noticeability**  
   Ship something that has a reasonable chance of getting attention within the Grok/xAI community, ideally early in the lifecycle of Grok Build. This includes the possibility of attracting interest from xAI or Elon Musk.

3. **Demonstrate Effective Process**  
   Use a strong, upfront design phase followed by rapid, high-quality implementation. The way the project is built is intended to be part of the signal — showing a disciplined approach to AI-assisted software development.

Secondary considerations (not priorities for the initial version):
- Easy community contributions for other platforms
- Long-term maintainability by external contributors
- Broad cross-platform support from day one

---

## Key Constraints

- **Speed of Delivery is Critical**  
  When the decision is made to begin implementation, the goal is to produce a working, high-quality version in as few passes as possible.

- **Mac-First (at minimum)**  
  The initial version will target macOS. While eventual cross-platform support (Windows and Linux) is desired, it is not a requirement for the first public release.

- **High Fidelity Experience**  
   The application must preserve the rich, dense console-like experience (thinking traces, tool calls, scrollback style, etc.) while adding better multi-instance management and reduced cognitive load.

- **Low Chrome Philosophy**  
   The UI should minimize persistent interface elements. Information and controls should be available on demand rather than always visible.

---

## Technology Evaluation

### Primary Options Considered

| Option                        | Mac Delivery Speed | Native Feel (Mac) | Future Cross-Platform Effort | Architecture Clarity | Overall Fit |
|-------------------------------|--------------------|-------------------|------------------------------|----------------------|-------------|
| **Tauri 2 + Rust backend**    | Fast               | Very Good         | Relatively low               | Excellent            | Strong      |
| **Pure SwiftUI (macOS only)** | Fastest            | Best              | High (major rewrite likely)  | Good                 | Good        |
| **Electron + TypeScript**     | Very Fast          | Fair              | Low                          | Moderate             | Weak        |
| **Rust + egui / Iced**        | Medium             | Excellent         | Medium                       | Excellent            | Moderate    |

### Recommended Direction

**Tauri 2 with a Rust backend + Svelte** is the locked choice for the frontend.

#### Why Svelte

- Better aligns with the desire for a lighter, less "heavy" development experience compared to React.
- Excellent iteration speed and ergonomics, which supports the goal of rapid, high-quality delivery.
- Significantly smaller runtime and better performance characteristics out of the box.
- Works very well with Tauri.

While React has a much larger ecosystem, that advantage is secondary here given the project priorities (speed + quality of the resulting tool + demonstrating strong process). The user is comfortable reading generated code regardless of prior personal experience with the framework.

#### Rationale

- **Speed + Quality Balance**: Allows relatively fast delivery of a high-quality Mac application while maintaining a clean separation between the UI layer and the orchestration layer.
- **Rust Backend Value**: The Rust portion serves as a local, native orchestrator. It handles connection management to multiple Grok Build instances (local via process spawning or stdio, and later remote via Tailscale + `grok agent serve`). This architecture naturally supports future extension by the community or the original author without requiring a full rewrite.
- **Demonstrates Strong Architecture**: Using Rust for the core orchestration logic provides clear boundaries and demonstrates the value of thoughtful upfront design — aligning with one of the project’s explicit goals.
- **Future Optionality**: Even though cross-platform support is not a priority for the initial release, Tauri significantly lowers the cost of adding Windows and Linux later compared to a pure SwiftUI approach.
- **Frontend Velocity**: The web frontend allows rapid iteration on the user interface (sidebar, right panel, conversation rendering, etc.), which supports the goal of delivering a tool the creator actually wants to use.

### Why Not Pure SwiftUI?

While a pure SwiftUI implementation would likely produce the highest-fidelity Mac experience in the shortest amount of time, it creates a significant future cost if cross-platform support is ever desired. Given that the project is open to community contributions for other platforms later, this approach was deprioritized in favor of a stack that keeps future options open without major sacrifices to initial delivery speed.

---

## Scope and Phasing Implications

- **Phase 1 (Initial Release)**: Focus exclusively on delivering an excellent macOS experience. Do not invest time in Windows or Linux compatibility during the initial build unless it comes at near-zero cost.
- **Phase 2**: Windows and Linux support can be pursued later, potentially with community involvement. The architecture should not actively hinder this, even if it is not optimized for it upfront.
- **Linux**: Lowest priority. Can be addressed after Windows if demand exists.

---

## Open Questions

- Which frontend framework (Svelte vs React vs another) offers the best balance of velocity and long-term maintainability for this project?
- What level of abstraction should exist between the Rust orchestration layer and the UI?
- How should local conversation persistence and history be handled in the initial version?

---

## Relationship to Other Documents

- `00-vision-and-north-star.md`: Defines the overall vision and phased approach.
- `02-ui-navigation-and-interaction.md`: Details the desired user experience and interface patterns.
- This document (`03-technology-and-build-strategy.md`): Captures the tooling and architectural strategy chosen to support the above goals under the current constraints.

---

*Created: 2026-05-25*  
*Last Updated: 2026-05-25*