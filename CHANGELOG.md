# Changelog — bmem

Format follows Keep a Changelog; versions are semantic.

## 1.1.2-beta3 — 2026-10-18

Fix release carrying the daemon-ownership and signal-handling fixes. The
`BMem-1.1.2-beta2.dmg` artifact (built 2026-10-18 13:22) predated the fix and
shipped a pre-fix binary under the beta2 version name; it has been withdrawn
and deleted, beta2 is not published and the name is not reused — this fix
content ships only under beta3.

### Fixed

- **SIGTERM/SIGINT crashed the daemon with SIGTRAP instead of draining
  gracefully** (a regression from the daemon-ownership change): the signal
  handlers were top-level closures in `main.swift`, and top-level code is
  isolated to `MainActor` (SE-0438) — GCD invoked them on a utility queue and
  the isolation assert killed the daemon before the first drain line
  (`kill -TERM` → rc=133; the test teardown kept producing crash reports).
  The handlers moved into a dedicated `SignalShutdownMonitor` (nonisolated,
  the same pattern as the memory-pressure monitor fix); an integration test
  now sends SIGTERM to a live daemon with an in-flight cold search. The drain
  budget was raised from 15 s to 90 s so an in-flight cold request survives a
  model reload and receives its answer.
- **The app now becomes the owner of the daemon**: if a daemon of a different
  version holds the port (classic case: the dmg was updated but an old
  `~/.local/bin/bmem` still serves `:8123`), the app shuts it down cleanly
  (`POST /v1/shutdown` → SIGTERM by pid → SIGKILL as a last resort) and
  starts its own bundled binary. Invariant: after the app launches,
  `/v1/status.version` equals the app version. The daemon learned graceful
  shutdown: `POST /v1/shutdown` and SIGTERM/SIGINT briefly drain in-flight
  requests and `exit(0)`; `/v1/status` now also reports `pid` and
  `model_idle_timeout_s`.
- **Idle-unload threshold line without a hardcoded literal**:
  `sys.model.unloaded` is parameterized by the actual threshold from
  `/v1/status` (single constant `BMemTuning.modelIdleTimeoutSeconds` = 335);
  the UI no longer promises "unload in 90 s" while the live threshold is 335.

## 1.1.2-beta2 — 2026-10-18

Stability release candidate after beta1: the embedding engine moved into a
child process, stream desync in the unload/reload window fixed, honest index
counters, drop-in languages. The `:8123` contract and the CLI did not change.

### Added

- **Embedding engine in a child process**: EmbeddingGemma now runs in a
  separate embed-worker; the daemon's idle footprint is ~90 MB (vs ~164 MB
  on the Qwen base); the worker unloads after idle and is transparently
  respawned on the next request.
- **Drop-in languages**: UI languages are JSON files in the `l10n/` folder
  of the resource bundle; a new language is a dropped-in file, no code
  changes (RU/EN bundled).
- **Honest index counters**: `/v1/status` reports `index.indexed /
  index.open / index.failed` separately (also per project); `dirty` is true
  only for a real reason (failed > 0 or an open file older than 24 h).

### Fixed

- **Embed-worker stream desync in the idle-unload/reload window**: a request
  arriving in the terminate/reload window is queued until the worker is
  ready (up to 3 rebuild attempts) instead of returning HTTP 500; the
  response protocol is v2 with magic+seq, so a desync is caught in place as
  a protocol error, and Code=7/8/9/10 logs the worker pid and header bytes
  to `daemon.log`. The idle-unload threshold is a fixed 335 s.
- **Concurrent embed requests interleaved on the worker socket**:
  round-trips are serialized on the worker socket, the daemon ignores
  SIGPIPE; with a long `BMEM_SOCKET` the socket leaf name is shortened to
  fit `sun_path` 104.
- **The indexer descended into dot-directories and excluded folders**:
  `scanMarkdown` prunes them without descending — cache and service folders
  no longer pollute the index or inflate the open/failed counters.

## 1.1.1-beta1 — 2026-10-15

First beta of the native **BMem.app**. The embedding engine, CLI and the
`:8123` contract are unchanged from 1.1.1; everything new is the control
layer and UI on top of the same daemon.

### Added

- **Native BMem.app**: a SwiftUI window with a dark theme and a six-section
  sidebar; built by `scripts/build-app.sh` (dev bundle) and
  `scripts/build-dmg.sh` (release dmg).
- **Control API on `:8123`**: `GET/PUT /v1/config`, `GET /v1/status`,
  `GET /v1/search`, `GET /v1/benchmark`, `POST /v1/benchmark/custom[/recheck]`
  — the same transport as `/v1/embeddings`; the `/embed` contract for external
  consumers did not change. Specification: `Sources/bmem/ControlAPI.swift`.
- **App screens**: onboarding (what gets indexed, Full Disk Access block,
  folder picker), "What I read", "Permissions", "Search" (strictness slider),
  "Advanced" (LAN key), "System" (autostart, telemetry).
- **Memory & rollbacks**: git backup of md notes in `~/.bmem/backup` (a commit
  once a day + before reindexing + at enablement), rollback points, a diff for
  a time window, rollback under the "adds files, never erases" rule, and
  "forget project" with a reversible archive in `~/.bmem/forgotten`.
- **Global hotkey panel**: a Spotlight-like panel on ⌥Space (configurable via
  `config.hotkey`, applied without a restart), 200 ms debounce, green scoring,
  "session/note · author · date" subtitles, Enter/⌘↵ opens the note.
- **Dual-language interface (RU/EN)**: every screen, the onboarding, the
  hotkey panel and dialogs are localized via a String Catalog; the language
  follows the system and can be overridden in the app instantly, without a
  restart.
- **Daemon autostart from the app**: if nothing answers on `:8123`, the app
  launches the daemon from the bundle (`Contents/MacOS/bmem`) once per run; a
  live daemon (CLI path, launchd, Login Item) is simply found. Instances with
  `--daemon-url`/`BMEM_DAEMON_URL` don't get autostart (the harness keeps
  owning the daemon; the explicit switch is `BMEM_APP_SPAWN=1`).

### Fixed

- **PUT /v1/config didn't reach the engine until a daemon restart** (found by
  this release's smoke run): onboarding added a folder, `/v1/config` showed
  it, but search answered `unknown project` until the daemon restarted. The
  engine got `updateConfig`; PUT/forget apply config on a live daemon;
  regression test `test04PutConfigReachesEngineWithoutRestart`.

### Beta caveats

- Builds are signed ad-hoc: Gatekeeper will require right-click → Open on the
  first launch; there is no auto-update or notarization.
- Telemetry is a no-op: the switch and the screen exist, sending is not
  implemented.
- Installing into `~/.local/bin` and `/Applications` is an owner's deliberate
  step; the release dmg does not do it.

Tests: `swift test`
all green.

## 1.1.1 — 2026-10-14

Engine switch: the default embedding backend is now **EmbeddingGemma-2**
(CoreML, ANE). Adopted after an A/B acceptance run on a frozen benchmark of
70 RU/EN reference questions (methodology and results: `evals/BENCHMARKS.md`):

| Metric | Qwen3 (production) | EmbeddingGemma-2 |
| --- | --- | --- |
| top-1 | 50/70 (71.4 %) | **58/70 (82.9 %)** |
| top-3 | 62/70 | **65/70** |
| search p90 | 2 232 ms | 2 438 ms (1.09×, within the 2× limit) |
| full corpus reindex | 590 s | **272 s (×2.2)** |
| idle footprint | 152 MB (live 177–315) | 193 MB (within the live range) |

Rollback without reinstalling: `BMEM_EMBED_BACKEND=qwen` in the daemon
environment (the Qwen bundle stays on disk in `~/.bmem/models`).

> **Note: the first launch after the update automatically performs a full
> database reindex.** Gemma vectors are a different 768-dimensional space
> (Qwen used 1024); rows are separated by a model tag in `embed_cache`, old
> vectors are neither overwritten nor in the way. Time estimate: ~5 minutes
> for ~9k chunks with a warm ANE cache (272 s on the test rig); on a clean
> machine add 1.5–2 minutes for a one-time ANE compilation of the `embed_*`
> functions (cached next to the model). Search keeps working during the
> reindex (FTS + already-reindexed chunks). External `:8123` consumers must
> rebuild their own indexes too — old qwen vectors are incompatible with the
> new ones.

### Changed

- **Default embedding backend is EmbeddingGemma-2**: a Gemma BPE tokenizer
  and a multifunction CoreML model `embed_32…embed_512` running on the Neural
  Engine; the inference port is based on FluidInference/FluidUse (Apache-2.0).
  It started as opt-in (`BMEM_EMBED_BACKEND=gemma`); since 1.1.1 it is the
  default, and an explicit `BMEM_EMBED_BACKEND=qwen` rolls back to
  Qwen3-CoreAI. CLI `bmem embed-probe` for numeric cross-checks.
- **:8123 honestly reports the active backend**: `/v1/models` returns
  `embeddinggemma-2` (dimension 768); on rollback — `qwen3-embedding-0.6b`
  (dimension 1024); the model name in a request is still accepted as anything
  and echoed back, so old client configs don't break.
- **dmg**: `BMem.app/Contents/models` carries a text bundle
  `embeddinggemma-2-coreml` (mlpackage + embeddings.bf16 + tokenizer +
  position embeddings, ~561 MB); the Qwen bundle was removed from the dmg,
  audio/vision graphs are not shipped — the image shrank from 896 MB to
  421 MB.

### Fixed

- **The first client crashed in embedded mode on a clean machine**:
  `spawnDaemon` waited for the daemon socket for 25 s, but the first launch
  includes ANE compilation of the `embed_*` functions (77–120 s, one-time).
  The wait was raised to 180 s with an early exit if the daemon process dies.
- **embed_cache overwrote the second model's vectors**: the primary key was
  only `content_hash`, and `INSERT OR REPLACE` with a new model tag
  overwrote the other model's vector (on the test rig the Qwen cache shrank
  10328 → 39 rows). The key is now composite `(content_hash, model,
  chunker)`; the migration runs once and stays compatible with the old binary
  (verified by a rollback test).
- **The daemon died under real OS memory pressure (the bug lived since
  1.1.0)**: the `DispatchSource.makeMemoryPressureSource` handler in
  main.swift read `pressureSource.mask` — a top-level variable, and top-level
  code is isolated to the MainActor (SE-0424/0438); GCD invoked the handler
  on a utility queue, the running isolation check hit
  `dispatch_assert_queue` → SIGTRAP, and the daemon died entirely exactly
  when it was needed most (6 crash reports on 13–14.10; FIFO-injection
  acceptance runs didn't catch this path). The source moved into
  `BMemCore.MemoryPressureMonitor`, the handler is honestly nonisolated
  (confirmed in SIL) and survives live warning/critical events. The 1.1.1
  image was rebuilt with the fix (same version).
- **The idle-watchdog didn't unload the gemma engine**: `unloadIfIdle`
  watched `inner != nil` (the Qwen slot) and never fired for the second
  backend.

## 1.1.0 — 2026-10-13

Memory and CPU stability: five architectural fixes, each verified on a test
rig and in live production.

### Fixed

- **Chunker infinite loop**: splitting long paragraphs was O(n²) and hung on
  live transcripts — the daemon burned 100% CPU for days. Now a single
  character pass (O(n)); chunk boundaries match the old ones bit-for-bit
  (cross-checked on 1677 files).
- **Model residency**: embedder weights (1.1 GB) lived in memory forever.
  Now they unload after 90 s idle (`BMEM_MODEL_IDLE_TIMEOUT`), reloading in
  ~0.8 s on the first request. Idle footprint: 6–11 GB → 110–230 MB.
- **Reindex on file append**: embeddings are content-addressed
  (`embed_cache`, md5 of the chunk + model/chunker tags); appending to a live
  transcript re-embeds only the tail, not the whole file. Before: a full
  re-embed on every agent-session append.
- **OS memory pressure**: `DispatchSource.memoryPressure` — on `.warning`
  the model unloads immediately, on `.critical` also `PRAGMA shrink_memory`.
- **Double indexing**: subfolders that are the root of another project are no
  longer indexed twice — production reindex 1694 → 1239 notes.

### Added

- `mem: rss/footprint/swap` metrics into the daemon log every 60 s and
  self-exit when the footprint exceeds `BMEM_MEM_LIMIT_MB` (default 8192)
  for 5 consecutive samples; model residency returns via client auto-spawn.
- `bmem version` (also `--version`/`-v`).

## 1.0.0 — 2026-09-28

First release: a native Swift replacement for the Python Basic Memory stack
(BM server + separate embedder server) in a single `bmem` binary.

### Added

- **Binary modes**: `mcp` (stdio MCP server, 14 tools — the surface is
  compatible with the Hermes basic-memory plugin and the OpenClaw
  openclaw-basic-memory plugin), `daemon` (resident backend), `index`,
  `search`, `context`, `bench`.
- **Storage**: a single SQLite WAL database (`~/.bmem/bmem.db`) — notes +
  chunks + FTS5 + fp32 vectors + edges. md files remain the source of truth;
  the database is derived.
- **Embedding**: Qwen3-Embedding-0.6B-CoreAI (float16, s512) via CoreAIKit,
  GPU inference. The model bundle is looked up next to the binary
  (`models/` beside the exec dir, `Contents/models` in the .app,
  `~/.bmem/models`), overridable with `BMEM_MODEL_DIR`.
- **Daemon loop**: a unix socket `~/.bmem/bmem.sock` with a flock lock;
  `bmem mcp` is a thin proxy to the daemon; with a dead socket it
  auto-spawns the daemon (waiting for the socket up to 25 s), and on failure
  falls back to an all-in-one embedded mode. `BMEM_NO_DAEMON=1` forces
  embedded, `BMEM_PROXY=1` forces proxy.
- **OpenAI-compatible endpoint** `/v1/embeddings` + `/v1/models` on
  127.0.0.1:8123 inside the daemon (`BMEM_EMBED_PORT`, "0"/"off" disables it)
  — for OpenClaw memory.search.
- **Graph**: wikilinks `[[Target]]`, `[[Target|alias]]`, anchors and `.md`
  suffixes → an edges table; `context` = a 1-hop walk over edges (out +
  backlinks) + vector highlighting. Parity with the Obsidian graph was
  verified on a live corpus (181 wikilink occurrences, 0 resolvable links
  lost).
- **Workspace registry**: `~/.bmem/config.json` (seeded from
  `~/.basic-memory/config.json`); `BMEM_PROJECT_PATH` / `--project P`
  override.
- **structuredContent** in MCP CallTool results alongside text (without it
  the OpenClaw plugin couldn't talk to BM).
- **1.0.0 packaging**: `BMem.app` (the launcher starts the daemon +
  notification) and `BMem-1.0.0.dmg` (drag-to-Applications) with the model
  bundle inside; ad-hoc signature over all Mach-O.

### Fixed

- **stdin watchdog (critical)**: the old SIGIO/O_ASYNC was also delivered on
  data arrival — a live client was killed 5 s after the handshake. Replaced
  with a poll-watchdog (a separate detached thread, 1 s poll): EOF =
  POLLHUP/POLLNVAL or a regular file with FIONREAD==0; a 5 s grace for
  in-flight work.
- The `dispatchMain()` pattern that starved the MCP server's cooperative
  pool (replaced with an eternal `await Task.sleep`).
- `CallTool.Result`: `.text(text:annotations:_meta:)` instead of the
  deprecated factory.
- CLI errors in search/context/bench no longer trap with fatal error — they
  print `error: ...`.

### Performance (measured live, 26–27.09)

- Warm search through the proxy: 0.21–0.43 s (vs ~13 s embedded cold).
- Full index of a 974-note / 5960-chunk corpus: ~4 s.
- Discriminator on 10 RU queries: 10/10 top-1; the min_similarity threshold
  of 0.30 was calibrated on the live corpus.

### Known limitations of 1.0.0

- Daemon residency = auto-spawn from the first client. launchd residency
  without Full Disk Access hangs on TCC (getxattr) — no plist is shipped.
- Ad-hoc signature: on another machine the dmg hits Gateway quarantine
  (right-click → Open, or `xattr -dr com.apple.quarantine`).
- MCP transport is stdio only; no streamable-HTTP for the Obsidian plugin.
- Files >256 KB, node_modules/venv/build/hidden dirs are out of the index.
