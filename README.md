# Grokestrator

A high-fidelity native desktop application for comfortably orchestrating multiple Grok Build instances from one place.

## What is Grokestrator?

If you regularly work with multiple Grok Build sessions (different configurations, different projects, local vs research instances, etc.), you know the pain:

- Constant context switching between terminals
- Losing history and context when moving between instances
- Difficulty keeping track of which instance has which capabilities (MCPs, skills, slash commands, etc.)

**Grokestrator** aims to solve this by giving you one comfortable, powerful interface that lets you manage and fluidly work across many Grok Build instances — while preserving the rich, dense experience you already like from the console.

## Current Status (Early Development)

- **Platform**: macOS first (excellent native experience)
- **Focus**: Local instances (multiple Grok Build processes on the same machine)
- **Status**: Design phase complete. Implementation starting soon.

Remote support (via Tailscale + `grok agent serve`) and multi-machine orchestration are planned for later phases.

## Goals

- Deliver a tool that power users of Grok Build actually want to use daily
- Maintain high visual and behavioral fidelity to the existing Grok console experience
- Minimize cognitive load when working with many instances
- Move fast with a strong design foundation

## Design Documents

All major design decisions are documented in the `design/` folder:

- [Vision & North Star](design/00-vision-and-north-star.md)
- [UI Navigation & Interaction Model](design/02-ui-navigation-and-interaction.md)
- [Technology & Build Strategy](design/03-technology-and-build-strategy.md)
- [Conversation Model](design/04-conversation-model.md)
- [Architecture & Components](design/01-architecture-and-components.md)
- [Data & Persistence Model](design/05-data-persistence-model.md)

## Tech Stack (Current)

- **Frontend**: Svelte
- **Backend**: Rust (via Tauri)
- **Integration**: Agent Client Protocol (ACP) to communicate with Grok Build instances

## Getting Involved

This project is in very early stages. More details (including how to build and run) will be added as implementation progresses.

## License

TBD

---

*Note: This is currently a private repository during initial development.*
