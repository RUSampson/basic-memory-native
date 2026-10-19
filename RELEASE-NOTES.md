# Release Notes — BMem 1.1.2-beta3 (2026-10-18)

**BMem** — a native memory backend for AI agents on macOS/Apple Silicon: one
Swift binary instead of the Basic Memory + embedding-server Python stack. It
keeps knowledge in a single SQLite database (FTS5 + vectors + wikilinks
graph); the source of truth stays plain Markdown files.

## What's new in 1.1.2-beta3

Fix build on top of beta2 (the `:8123` contract and the CLI are unchanged):

- the app is now the owner of the daemon: when a different-version daemon
  holds the port it shuts it down cleanly (`POST /v1/shutdown` → SIGTERM by
  pid → SIGKILL as a last resort) and starts its own from the bundle;
  `/v1/status` now reports `pid` and `model_idle_timeout_s`;
- SIGTERM/SIGINT no longer crash the daemon with SIGTRAP — in-flight
  requests are drained gracefully and the daemon exits 0; the drain budget
  is raised to 90 s, so a cold request arriving during a model reload waits
  and gets its answer;
- the idle-unload threshold line in the UI is parameterized by the actual
  threshold from `/v1/status` (335 s) instead of a hardcoded "90 s";
- the `BMem-1.1.2-beta2.dmg` artifact (a pre-fix binary shipped under the
  beta2 name) is withdrawn and deleted; beta2 is not published.

## What's new in 1.1.2-beta2

Stability and footprint fixes after beta1; the `:8123` contract and the CLI
are unchanged:

- the embedding engine now runs in a separate embed-worker process: the
  daemon's idle footprint is ~90 MB; the worker unloads after 335 s of idle
  (fixed threshold) and is transparently respawned on the next request;
- a request arriving during the worker unload/reload window is queued until
  the worker is ready instead of getting an HTTP 500; the response protocol
  is v2 with magic+seq — stream desync is caught in place and diagnosed in
  `daemon.log`;
- embed round-trips are serialized on the worker socket (concurrent requests
  no longer interleave); the daemon no longer dies on SIGPIPE;
- `/v1/status` reports `index.indexed / index.open / index.failed`
  separately (also per project); `dirty` is set only for a real reason;
- UI languages are drop-in JSON files in the `l10n/` folder of the bundle:
  a new language needs no code changes;
- the indexer no longer descends into dot-directories and excluded folders
  (`skipDirs`).

## What's new in 1.1.1-beta1

First beta of the **native BMem.app** on top of the existing daemon (the
EmbeddingGemma-2 engine, the CLI and the `:8123` contract are the same as in
1.1.1):

- dark-themed app with six sections: onboarding, "What I read",
  "Permissions", "Search", "Advanced", "System";
- global hotkey search panel on ⌥Space (Spotlight-style, configurable);
- "Memory & rollbacks": git backup of notes, rollback points, diff, "forget
  project";
- control API on `:8123` (`/v1/status`, `/v1/config`, `/v1/search`,
  `/v1/benchmark`) — the `/embed` contract for external consumers is
  unchanged;
- on first launch the app starts or finds the daemon itself (bundled
  `Contents/MacOS/bmem`; a daemon already running from CLI/launchd is simply
  discovered).

Beta caveats: builds are ad-hoc signed (first launch — right-click → Open),
telemetry is a no-op, there is no auto-update. Full summary: `CHANGELOG.md`.

## What's new in 1.1.1

Embedding engine switch: **EmbeddingGemma-2 (CoreML, Neural Engine)** instead
of Qwen3-Embedding-0.6B. On the frozen benchmark of 70 RU/EN reference
queries: top-1 58/70 (82.9 %) vs 50/70 (71.4 %), a full reindex is 2.2×
faster, search latency is equal. Details: `CHANGELOG.md`.

> **The first launch after an update automatically runs a full database
> reindex** (~5 minutes for ~9k chunks; on a clean machine add 1.5–2 minutes
> for the one-off ANE model compilation). Search keeps working during the
> reindex. External `:8123` consumers: vectors are now 768-dimensional (was
> 1024) — rebuild your own index.

Rollback to the old engine without reinstalling: set `BMEM_EMBED_BACKEND=qwen`
in the daemon environment (the Qwen bundle stays in `~/.bmem/models`).

## What's inside

| Component | What it does |
| --- | --- |
| `bmem mcp` | MCP server (stdio), 14 tools: search/read/context/write/edit/delete… |
| `bmem daemon` | Resident backend: model + SQLite behind a unix socket |
| `BMem.app` | Native app: management screens, hotkey panel, daemon autostart |
| `bmem index/search/context/bench` | CLI for manual work and calibration |
| `:8123/v1/embeddings` | OpenAI-compatible embeddings (EmbeddingGemma-2 CoreML, ANE, 768-dim) |
| Auto-spawn | The first client starts the daemon itself; first wait up to 180 s (cold ANE start) |

## Installation (dmg)

1. Open `BMem-1.1.2-beta3.dmg`, drag `BMem.app` into `Applications`
   (replaces the old version).
2. First launch: right-click the icon → Open (ad-hoc signature, Gatekeeper
   will warn). Or clear the quarantine attribute:
   `xattr -dr com.apple.quarantine /Applications/BMem.app`.
3. Agents need the binary on PATH:
   `mkdir -p ~/.local/bin && cp /Applications/BMem.app/Contents/MacOS/bmem ~/.local/bin/bmem && codesign --force -s - ~/.local/bin/bmem`
4. The model lives inside the bundle
   (`BMem.app/Contents/models/embeddinggemma-2-coreml`, text graph ~561 MB)
   and is picked up automatically; fallback paths are
   `~/.bmem/models/embeddinggemma-2-coreml` or `BMEM_GEMMA_MODEL_DIR`.

## Verification

```bash
~/.local/bin/bmem version                                 # bmem 1.1.2-beta3
~/.local/bin/bmem search "test query" --project ai-projects   # hits with score
curl -s http://127.0.0.1:8123/v1/models                   # embeddinggemma-2, dimension 768
```

Reference engine benchmark (70 queries, A/B, 2026-10): EmbeddingGemma-2
58/70 vs Qwen 50/70 (internal corpus; harness and protocol are in the project
history).

## Requirements

- macOS 27+, Apple Silicon (the binary is built for deployment target 27;
  the CoreML model itself requires macOS 15+). The Neural Engine (ANE) is
  the intended engine, but the graph also runs on GPU/CPU.
- Disk: ~600 MB for the model inside the dmg bundle.
- RAM: the embed-worker unloads after 335 s of idle (fixed threshold);
  at rest the daemon uses ~90 MB, under load up to ~320 MB (footprint).
  During a full reindex, virtual residency with mmap can reach ~11 GB —
  that is page cache; physical usage stays in the hundreds of MB.

## How to connect Hermes / OpenClaw / Obsidian

See `README.md` (MCP config snippets for each client).
