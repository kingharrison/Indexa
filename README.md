# Indexa

> Your documents, your AI, your machine. No cloud required.

Indexa is a **local-first macOS app** for building private, AI-powered knowledge bases using Retrieval-Augmented Generation (RAG). Index your documents, ask natural language questions against them, and share encrypted knowledge bundles — all running locally with no data leaving your machine.

![Platform](https://img.shields.io/badge/platform-macOS-blue?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)
![Swift](https://img.shields.io/badge/swift-6.0-orange?style=flat-square)
![Status](https://img.shields.io/badge/status-v1.0-teal?style=flat-square)

---

## Download

**[⬇ Download Indexa.dmg](https://indexa-kb.ai/Indexa.dmg)** · [indexa-kb.ai](https://indexa-kb.ai)

Requires [Ollama](https://ollama.com) · Apple Silicon or Intel

---

## What is Indexa?

Indexa sits as a **middleware layer** between your documents and AI. You feed it files and websites, it chunks and embeds them into a local vector database, and then you — or other apps — can query that knowledge base via natural language or HTTP API.

The killer feature: **export any collection as an encrypted `.indexa` bundle**. Hand it to someone and they can query your knowledge base with full AI-powered answers — but they never see the underlying source documents. You control whether they see citations. You control whether they can modify anything.

---

## Features

### Document Ingestion
- Drag and drop **PDF, TXT, Markdown, RTF, DOCX, and HTML** files
- **Web scraping** — paste a URL to index a single page
- **Site crawling** — crawl entire websites with configurable depth and page limits
- AI-generated **document summaries** at ingest time
- Per-document **enable/disable** toggle for selective RAG queries

### AI-Powered Queries
- Natural language questions with answers grounded in your documents
- **Source citations** with relevance scores for every answer
- **Custom system prompts** per collection to control AI behavior
- Switch between any locally available **chat model** on the fly

### AI Distillation
- AI rewrites documents optimized for better retrieval accuracy
- Per-document toggle between original and distilled versions
- Batch distillation for entire site crawls

### Collections
- Organize documents into named collections — like folders, but smarter
- Each collection has its own system prompt, query context, and refresh settings
- **Duplicate** collections with all documents and embeddings intact
- **Rename** collections inline

### Export & Import (.indexa Bundles)
- Export collections as a portable **`.indexa` bundle** — fully self-contained
- **AES-256-GCM encryption** with PBKDF2 key derivation (100k iterations)
- Import bundles to restore or share knowledge bases across machines
- Double-click a `.indexa` file to open it directly in Indexa

### Collection Protection
Collections can be password-protected at two levels:

| Mode | What the recipient can do |
|---|---|
| **Sources Masked** | Query and get answers — cannot see documents or citations |
| **Read Only** | View documents and query with citations — cannot modify |

Passwords use PBKDF2 with per-collection random salt. Session-based unlock resets on app restart.

### HTTP REST API
- Built-in HTTP server exposes RAG to other applications
- Endpoints: `GET /v1/health` · `GET /v1/collections` · `POST /v1/query`
- API key authentication (Bearer token or `X-API-Key` header)
- Protection-aware: masked collections strip sources from API responses
- CORS restricted to localhost · Rate limiting on password attempts (10 tries, 5-min lockout)
- Auto-start on app launch

### Auto-Refresh
- Web sources re-index automatically on a schedule: Hourly, Daily, or Weekly
- Manual refresh available anytime

### Multi-Provider Support
- Default: **Ollama** (free, runs locally)
- Also supports any **OpenAI-compatible server** (LM Studio, etc.)
- Configure multiple providers, switch models on the fly
- Per-provider embedding model configuration

---

## Requirements

| Requirement | Details |
|---|---|
| **macOS** | Apple Silicon or Intel |
| **Ollama** | [ollama.com](https://ollama.com) — free, open source |
| **Embedding model** | `ollama pull nomic-embed-text` |
| **Chat model** | `ollama pull llama3.2` (or any supported model) |

---

## Getting Started

```bash
# 1. Install Ollama
brew install ollama

# 2. Pull required models
ollama pull nomic-embed-text
ollama pull llama3.2

# 3. Download and open Indexa
# https://indexa-kb.ai/Indexa.dmg
```

Then:
1. **Open Indexa** — it auto-connects to Ollama
2. **Create a collection** — give it a name
3. **Add documents** — drag files, paste URLs, or crawl a site
4. **Ask questions** — get AI answers with source citations
5. **Export** — bundle collections into encrypted `.indexa` files
6. **Integrate** — query Indexa from other apps via the HTTP API

---

## Architecture

| Component | Technology |
|---|---|
| Platform | macOS · Native SwiftUI · Swift 6 |
| UI Pattern | SwiftUI `@Observable` |
| Database | SQLite3 (raw C API, no dependencies) |
| Vector Search | Cosine similarity, computed in-memory |
| Embeddings | nomic-embed-text via Ollama (768-dim) |
| Encryption | AES-256-GCM (CryptoKit) + PBKDF2 (CommonCrypto) |
| Compression | LZFSE (Apple built-in) |
| HTTP Server | Apple Network framework (NWListener) |
| Sandbox | App Sandbox · network client + server entitlements |

---

## What Indexa is NOT

- **Not a cloud service** — everything runs locally
- **Not an AI model** — it uses Ollama (or compatible) as the AI backend
- **Not a chat app** — it's a knowledge base layer that chat apps connect to via API
- **Not phone-home** — no internet required after initial Ollama model download
- **Not tracking you** — zero telemetry or analytics

---

## Enterprise

Indexa is free for individuals. If your organization needs **server-managed access control** — provision users, revoke bundle access instantly, audit who queried what — that's on the roadmap.

Reach out if that's you: [info@indexa-kb.ai](mailto:info@indexa-kb.ai)

---

## Contributing

Issues, PRs, and feedback are welcome. This started as a personal tool — if it's useful to you, let's make it better together.

---

## License

MIT · Built by [@kingharrison](https://github.com/kingharrison)
