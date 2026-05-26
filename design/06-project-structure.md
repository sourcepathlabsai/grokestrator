# Grokestrator — Project Structure and Module Responsibilities

**Status:** First Pass  
**Date:** May 2026

## Overview

This document defines the high-level project structure and the responsibilities of each major module. The goal is to keep the architecture clean, understandable, and suitable for AI-driven development while supporting the current direction (native Mac + iOS, hybrid Mac app, multi-server support).

We are deliberately keeping the structure simple and "normal".

## High-Level Structure

```
Grokestrator/
├── Grokestrator.xcworkspace
├── Packages/
│   └── GrokestratorCore/               ← Shared logic (Swift Package)
├── GrokestratorMac/                    ← macOS app (Client + Server)
├── GrokestratoriOS/                    ← iOS app (Client only)
└── Design/                             ← Living design documentation
```

## Module Responsibilities

### GrokestratorCore (Swift Package)
- Contains all shared, platform-independent logic.
- Acts as the single source of truth for models, networking protocols, and core abstractions.
- Should remain as free of UI and platform-specific code as possible.

Current sub-modules (implemented in the Core foundation):
- **Models**: ServerAddress (with Tailscale + port), Conversation, Message, Agent, ConnectionState, ServerInfo, ManagedInstance, ServerConfiguration, ClientConfiguration.
- **Networking**: GrokestratorTransport protocol, Connection, GrokestratorProtocol (full request/response/event control plane for client ↔ server).
- **Server**: ServerState, ServerConfiguration (data model for instance lifecycle, auto-restart, etc.).
- **Client**: MultiServerSession (multi-tab/server), ClientConfiguration.
- **Persistence**: PersistenceProtocol + FilePersistence (actor-based JSON implementation).
- **Common**: GrokestratorError.

The Core is the primary place new shared code lands. It is deliberately free of UI and heavy platform specifics so it can be used by both the Mac hybrid app and the iOS client.

### GrokestratorMac
- The only target that can run in Server Mode.
- Contains all macOS-specific UI and server management features.
- Depends on GrokestratorCore.

### GrokestratoriOS
- Client-only application.
- Depends on GrokestratorCore.

### Design/
- Living documentation. Updated as architectural decisions are made during implementation.

---

This structure follows current standard practices for Swift/SwiftUI projects that need shared code across platforms while allowing the Mac app to have richer server capabilities.

The Core package will be the primary place where most new shared code is written.
