# Grokestrator — Data and Persistence Model

## Overview

This document defines what Grokestrator needs to persist, how it should be stored, and the trade-offs between different approaches — with a strong emphasis on **speed of delivery** for the initial Mac version.

The persistence layer must support:
- Restarting the app and returning the user to where they left off (open connections + conversations)
- The hybrid history model (Grokestrator owns conversation history while allowing clean handoff to the underlying instance)
- Future evolution (multi-instance conversations, remote support, etc.) without major rewrites

## What Needs to Be Persisted

### Core Entities

| Entity              | What to Store                                      | Frequency of Change | Notes |
|---------------------|----------------------------------------------------|---------------------|-------|
| **Connections**     | ID, user-assigned name, type (local/remote), last known details, connection metadata | Low | Stable over time |
| **Conversations**   | ID, title, associated connection ID, created/updated timestamps, message history | High | Primary unit of user work |
| **Messages**        | Content (text, tool calls, thoughts, etc.), timestamps, role | Very High | Bulk of the data |
| **Application State** | Last active connection + conversation, open panels, UI preferences | Medium | Per-user |
| **Instance Metadata** | Cached capabilities (slash commands, MCPs, skills) per connection | Medium | Can be refreshed on demand |

### What We Do **Not** Need to Persist (at least initially)

- Full raw ACP protocol state
- Large binary artifacts from tools (we can store references/paths instead)
- Transient tool execution state

## Persistence Approaches

### Option A: Simpler File-Based Storage

**Approach**: Directory-based structure with JSON files (e.g. `connections.json`, per-conversation folders with `messages.jsonl` or similar).

**Pros**:
- Very fast to implement
- Easy to debug and inspect by hand
- No database runtime or schema migration complexity
- Good enough for most local desktop apps
- Excellent restart behavior (just read files on startup)

**Cons**:
- No built-in full-text search across conversations
- More manual work for complex queries later
- Can become slower at very large scale (unlikely for early versions)

### Option B: SQLite

**Approach**: Embedded SQLite database (via `rusqlite` or similar in the Rust backend).

**Pros**:
- Strong querying and full-text search (FTS5) out of the box
- Better performance for large numbers of messages/conversations
- Easier to evolve schema over time
- Atomic transactions

**Cons**:
- Adds a small amount of complexity and dependencies
- Slightly more work to set up and migrate
- Overkill if we don't actually need search or complex queries in the early versions

### Option C: Hybrid

Use simple files for most things and SQLite only for search/indexing. This is usually the worst of both worlds for a small-to-medium desktop app.

## Recommendation

**Start with Option A (file-based storage)** for the initial implementation, unless we identify a concrete near-term need for full-text search across conversations.

### Rationale

- Speed to a usable Mac version is currently the highest priority.
- For a local desktop tool used by one person, file-based storage is usually more than sufficient.
- We can always migrate to SQLite later if real usage shows that search or complex querying becomes painful (this migration is very doable).
- The hybrid history requirement and "restart brings you back" goal are both easy to satisfy with files.

### When SQLite Would Make Sense

We should consider SQLite if any of the following become real requirements in the near term:
- Full-text search across all conversations and messages
- Complex filtering or analytics on conversation history
- Very large numbers of conversations/messages per user

**Current assessment**: None of these appear to be MVP or even early MVD requirements.

## Persistence and the Conversation Model

- Grokestrator owns the canonical conversation history.
- When handing off to a Grok Build instance, we can pass recent context/messages as needed.
- On restart, we reload connections and the last active conversation(s) from disk.
- Messages should be stored in an append-friendly format (e.g. JSONL) for easy incremental updates.

## Open Questions

1. **SQLite Decision** — Do we have any near-term use case that would benefit from full-text search or complex queries? (If not, we should default to file-based storage.)
2. Should we store raw tool outputs (screenshots, large diffs, etc.) directly, or just references?
3. How much conversation metadata do we need to support future multi-instance conversations?

## Relationship to Other Documents

- `00-vision-and-north-star.md`: Emphasizes conversation history as a first-class strength.
- `04-conversation-model.md`: Defines the hybrid ownership model that this persistence layer must support.
- `01-architecture-and-components.md`: The Rust backend will own the persistence implementation.
- `03-technology-and-build-strategy.md`: Tauri + Rust makes both file-based and SQLite approaches straightforward.

---

*Created: 2026-05-25*  
*Status: Lightweight — focused on enabling a fast path to a usable Mac version while leaving room to evolve.*