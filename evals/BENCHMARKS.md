# Benchmarks — methodology and results

Everything we publish about search quality lives here. The question set and
the harness are in this folder; the raw internal run logs stay private until
we decide otherwise.

## Method

- **Suite:** 70 frozen reference questions (44 RU / 26 EN), each with a gold
  file — the note that must appear in the results. Questions were written
  from real recall needs and the gold mapping was content-verified before the
  first run. Paths are NFC-normalized before comparison (APFS returns NFD).
- **Corpus:** a live personal-notes registry indexed by BMem itself —
  11,147 chunks across ~1.8k Markdown notes (project names in the published
  query set are anonymized 1:1 placeholders; the internal originals differ
  only in names).
- **Harness:** `embeddinggemma2-vs-qwen.py`. Both engines run the *same*
  BMem 1.1.2-beta3 binary against isolated copies of the index (separate
  `HOME`, socket, DB), selected only via `BMEM_EMBED_BACKEND`. Search goes
  through the daemon's unix socket exactly like an MCP client's; the model is
  warm during the timed batch.
- **Metrics:** top-1 / top-3 accuracy against the gold file, search latency
  median/p90, idle footprint after model unload, first-query latency after
  unload.

## Results — BMem 1.1.2-beta3, run 2026-10-19

| Metric | Qwen3-Embedding-0.6B | EmbeddingGemma-2 (default) |
| --- | --- | --- |
| top-1 | 46/70 (65.7 %) | **56/70 (80.0 %)** |
| top-3 | 62/70 (88.6 %) | **64/70 (91.4 %)** |
| top-1, Russian half | 30/44 | **37/44** |
| top-1, English half | 16/26 | **19/26** |
| search latency median | 348 ms | **270 ms** |
| search latency p90 | 559 ms | **324 ms** |
| idle footprint after unload | 182 MB | **89 MB** |
| first search after unload | 0.9 s | 6.2 s |

EmbeddingGemma-2 wins quality on both language halves with a smaller idle
footprint; Qwen returns from idle faster (its model is smaller). The
release gate for switching the default engine required: new top-1 ≥ old,
new top-1 ≥ 80 %, p90 ≤ 2× old, idle footprint not higher, identical
chunker signature — all five green on this run.

## Live-daemon memory profile (2026-10-19)

Steady idle on the live daemon (11,257 chunks): **~30 MB RSS / 77 MB
footprint**. Model weights unload after 335 s idle (fixed product threshold);
the child embed-worker exits after 2×335 s idle. A cold query after unload
costs ~6 s (worker respawn + model load); the first load after an OS update
can cost ~60 s while the ANE shader cache rebuilds.

## Earlier runs (same frozen suite)

| Date | Setup | Gemma top-1 / top-3 | Qwen top-1 / top-3 | p90 (Gemma) |
| --- | --- | --- | --- | --- |
| 2026-10-14 | A/B stand (copies of the live DB), 9.2k chunks, pre-1.1.1 binaries | 58 / 65 | 50 / 62 | 2.44 s |
| 2026-10-17 | A/B stand, 9.4k chunks, pre-beta3 binaries | 56 / 64 | 47 / 61 | 3.92 s |
| 2026-10-19 | A/B stand, 11.1k chunks, **1.1.2-beta3** | **56 / 64** | 46 / 62 | **0.32 s** |

Row sources, in the internal run logs: 10-14 — `run-2026-10-14-metrics.json`
and the embedding A/B gate report; 10-17 — the re-acceptance harness logs on the
embed-worker prototype binary; 10-19 — `ab-summary-2026-10-19.json`.

The latency drop between 10-17 and 10-19 is real on this machine but we
publish it with a caveat: the 10-17 run paid a cold ANE shader-cache /
embed-worker path on a pre-beta3 binary. Treat the 10-19 numbers as the
beta3 contract and expect first-run-after-update slowness.

## Honest caveats

- This is **our own frozen question set on our own corpus** — a direction
  check, not an industry benchmark. Do not quote it as "80 % accuracy" in
  benchmarks-arena style comparisons.
- One machine (single Apple Silicon Mac), one corpus, one annotator.
- Accuracy is measured against *file-level* gold, not answer quality.
