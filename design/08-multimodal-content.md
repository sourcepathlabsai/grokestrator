# Grokestrator — Multimodal (Non-Text) Content

**Status:** Design v0.1 — for review.
**Date:** 2026-05-27

## Problem / Gap

The conversation pipeline currently assumes **text only**. Concretely:
- The ACP `ContentBlock` decodes just `{ type: "text" }`.
- `session/update` routing reads `content.text`; any non-text content block is **silently dropped**.
- `ConversationUpdate.message` / the transcript model carry a `String`.

So if Grok returns an image, song, video, generated file, etc., the user sees nothing. This document specifies how non-text content is modeled, transported, rendered, downloaded, persisted, and (later) delivered to the iOS client.

## Goals

- Render **images inline** in the transcript.
- Give **audio and video** an inline player (play/pause/scrub) plus **download**.
- Make **every non-text artifact downloadable** (and previewable where sensible).
- Degrade gracefully: anything we can't render richly becomes "name + size + download".
- Keep the model transport-agnostic so the same content works for the Mac (local) and, later, the iOS client over Tailscale.

## Content Taxonomy

| Type | In-stream behavior | Controls |
|---|---|---|
| **Text** | rendered (markdown later) | copy |
| **Image** (PNG/JPEG/GIF/WebP/SVG) | inline | download, enlarge (Quick Look) |
| **Audio / music** | inline player | play/pause/scrub, download |
| **Video** | inline player (poster + play) | play, download |
| **File / document** (PDF, CSV, zip, code, docx, …) | icon + name + size | preview (Quick Look), download |
| **Chart / diagram** | usually arrives *as* an image/SVG → inline | download |
| **Web link** (`resource_link` to a URL) | clickable card | open |
| **Code / diff** | (text, but) syntax-highlighted block | copy, later "apply diff" |
| **Table / structured data** | rendered table | copy / export CSV |
| **Unknown binary** (3D models, etc.) | icon + name | download only |

## Data Model

An assistant message becomes an **ordered list of content parts** rather than a `String`:

```swift
public enum ContentPart: Sendable {
    case text(String)
    case image(MediaSource, mimeType: String)
    case audio(MediaSource, mimeType: String)
    case video(MediaSource, mimeType: String)
    case file(MediaSource, mimeType: String, name: String, byteCount: Int?)
    case link(url: URL, title: String?)
}

/// Where a part's bytes actually live. The UI is agnostic to which case it is —
/// the transport layer resolves a source to displayable/downloadable bytes.
public enum MediaSource: Sendable {
    case inline(Data)        // base64 carried in the ACP stream (small assets)
    case localFile(URL)      // a path on the *server* machine (e.g. agent-written)
    case remote(URL)         // an http(s) URL
    case cached(URL)         // an app-cached copy on local disk
}
```

A streamed assistant turn is therefore a sequence of parts: text parts arrive incrementally (existing delta streaming), media parts arrive as **discrete whole blocks** appended to the message.

> **Inline vs by-reference is the key distinction.** Small images can be `inline(Data)` (base64 in the stream). Video and large audio **cannot** be base64'd into the stream — they arrive as a `resource_link` → `localFile` or `remote`. The model must support both from day one.

## ACP Mapping

Non-text arrives via ACP content blocks inside `session/update` (and tool output). Mapping:

| ACP block | → ContentPart |
|---|---|
| `{ type:"text", text }` | `.text` |
| `{ type:"image", data, mimeType }` | `.image(.inline(decode(data)), mime)` |
| `{ type:"audio", data, mimeType }` | `.audio(.inline(…), mime)` |
| `{ type:"resource", resource:{ uri?, mimeType, text? / blob? } }` | text → `.text`/`.file`; blob → media/file by mime |
| `{ type:"resource_link", uri, mimeType, name, size? }` | categorize by `mimeType`: image/audio/video → media `.localFile`/`.remote`; http + no media mime → `.link`; else `.file` |

Categorization is **mimeType-driven** with an "unknown → file/download" fallback.

> **Likely Grok behavior (to verify):** as a coding agent, Grok may deliver generated media by **writing a file and returning a `resource_link`** to it (a local path), rather than inlining base64. So `localFile` references are expected to be common — which is exactly what makes the iOS path (below) matter.

## UI / UX

- **Image** — inline `Image` (capped max width), click to enlarge (Quick Look), download button.
- **Audio** — compact `AVPlayer` transport (play/pause, scrubber, duration) + download.
- **Video** — `AVKit` player (poster + play) + download.
- **File** — icon + name + human size; Quick Look preview; download.
- **Link** — card (title/URL, favicon later); opens in browser.
- **Download** — Mac: `NSSavePanel` (default filename from `name`/mime). iOS: share sheet.
- Every non-text part shows a **download affordance**; players never block the transcript.

## Persistence

- Media bytes are **cached to disk** under `Application Support/Grokestrator/media/<sha>.<ext>`.
- History stores the `ContentPart` with a **`cached(URL)` reference**, not raw bytes inline in the conversation JSON (keeps history small and loadable).
- On history load, parts resolve to their cached files.

## iOS over Tailscale (the sharp edge)

`inline(Data)` and `remote(http URL)` work on iOS as-is. But a `localFile(URL)` is a path **on the Mac server** that the iOS client cannot open. To make media work cross-device:

- The **server** must serve/stream those bytes over the control plane — a new `GrokestratorProtocol` capability, e.g. `fetchResource(instanceID, ref) -> bytes` (with range support for large media), or a Tailscale-scoped HTTP byte endpoint.
- The client then treats the result as a `cached(URL)` after fetching.

**Phasing:** Mac-local first (sources resolve directly). The model is designed so swapping a `localFile` for a fetched/cached source is transparent to the UI, so the iOS streaming path slots in later without UI changes.

## Security & Limits

- Cap inline base64 size (e.g. skip/placeholder above ~10 MB) to protect the stream.
- Scope/sanitize local file access to what the agent references.
- Never log media bytes (the ACP debug logging was already removed).

## Relationship to the model duplication

`ConversationUpdate` / related types currently exist both Mac-locally and in `GrokestratorCore` (see the duplication note). `ContentPart` ideally lives in **Core** (shared by client + server). For the first slice it may land Mac-local alongside the existing types and be promoted to Core during the planned de-dup refactor.

## Phasing (implementation slices)

1. **Images (inline)** — `ContentPart`/`MediaSource` model, ACP decode of `image` blocks (inline + image `resource_link`), inline render + download (Mac). *(first slice)*
2. **Audio** player.
3. **Video** player.
4. **File / link cards** + Quick Look (the graceful fallback).
5. **Media persistence/caching** in history.
6. **iOS media transport** over the control plane (`fetchResource`).

## Open Questions

- Does `grok agent stdio` actually emit media today, and in what exact block shape (inline `image` vs `resource_link` to a written file vs a remote URL)? Verify against the binary when media output is available; until then, implement to the ACP standard with graceful unknown-handling.
- SVG: render as image or show source? (Lean: render.)
- Should tool *outputs* (e.g. a chart a tool produced) flow through the same `ContentPart` path? (Lean: yes.)
- Streaming partial media (progressive image/video) — defer; treat media blocks as whole for now.

---

*v0.1 — written 2026-05-27. First build slice (per decision): inline images on Mac.*
