# Grokestrator

A high-fidelity native desktop application for comfortably orchestrating multiple Grok Build instances from one place.

## What is Grokestrator?

If you regularly work with multiple Grok Build sessions (different configurations, different projects, local vs research instances, etc.), you know the pain:

- Constant context switching between terminals
- Losing history and context when moving between instances
- Difficulty keeping track of which instance has which capabilities (MCPs, skills, slash commands, etc.)

**Grokestrator** aims to solve this by giving you one comfortable, powerful interface that lets you manage and fluidly work across many Grok Build instances — while preserving the rich, dense experience you already like from the console.

## Current Status (Early Development)

- **Platform**: macOS + iOS, built as **native Swift + SwiftUI**.
- **Mac app**: Hybrid — runs both the client UI *and* the server. The stationary dev Mac owns `grok` instance lifecycle (launch/monitor/auto-restart), conversation history, and persistence.
- **iOS app**: Client-only — drives the Mac server (including voice/hands-free) over Tailscale.
- **Shared core**: `GrokestratorCore` (a Swift package) is the single source of truth for models, the control-plane protocol, and persistence.
- **Status**: Core foundation and the Grok Build integration layer (the "black box") are implemented. Active work is the client control-plane protocol so iOS/Mac clients can drive remote Grok Build instances.

See [`PROJECT_STATE.md`](PROJECT_STATE.md) for the live, authoritative snapshot.

> **Note on history**: An earlier iteration explored a Tauri/Rust/Svelte stack. After evaluating real iOS-client, voice, and hybrid-Mac-server requirements, the project moved to pure native Swift + SwiftUI.

## Goals

- Deliver a tool that power users of Grok Build actually want to use daily
- Maintain high visual and behavioral fidelity to the existing Grok console experience
- Minimize cognitive load when working with many instances
- Move fast with a strong design foundation

## Design Documents

All major design decisions are documented in the `design/` folder:

- [Vision & North Star](design/00-vision-and-north-star.md)
- [Architecture & Components](design/01-architecture-and-components.md) *(historical)*
- [UI Navigation & Interaction Model](design/02-ui-navigation-and-interaction.md)
- [Technology & Build Strategy](design/03-technology-and-build-strategy.md) *(historical)*
- [Conversation Model](design/04-conversation-model.md)
- [Data & Persistence Model](design/05-data-persistence-model.md)
- [Project Structure](design/06-project-structure.md)
- [Client Control Plane Protocol](design/07-client-control-plane-protocol.md)
- [Multimodal (Non-Text) Content](design/08-multimodal-content.md)

## Tech Stack (Current)

- **Apps**: Swift + SwiftUI (native macOS hybrid client+server, native iOS client)
- **Shared core**: `GrokestratorCore` Swift package (models, control-plane protocol, persistence)
- **Instance integration**: Agent Client Protocol (ACP) over stdio to each Grok Build instance
- **Remote transport**: Tailscale between iOS/Mac clients and the Mac server

## Getting Involved

This project is in very early stages. More details (including how to build and run) will be added as implementation progresses.

## License

TBD

---

*Note: This is currently a private repository during initial development.*
