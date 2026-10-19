// UI-1: control API for the facade app. Same transport and port as the
// openai endpoint (http://127.0.0.1:8123, localhost) — routes are delegated
// by handleEmbedRequest (EmbedServer.swift), the transport is shared.
//
// Endpoints:
//   GET  /v1/status           showcase: version, index (chunks/projects/freshness),
//                             engine, daemon memory, model loaded, autostart;
//   GET  /v1/config           stored settings + read-only «never touch» list;
//   PUT  /v1/config           partial update (JSON with changed keys only),
//                             persist to ~/.bmem/config.json;
//   GET  /v1/search           engine search + trust filter + strictness;
//   GET  /v1/benchmark        latest benchmark numbers from evals/ as {total, hit}
//                             + custom section (custom benchmarks from evals/custom.json);
//   POST /v1/benchmark/custom {question, expected_file} — add a custom benchmark,
//                             check it right away, persist to evals/custom.json;
//   POST /v1/benchmark/custom/recheck — re-check all custom benchmarks;
//   GET  /v1/rollback/points  rollback points = commits of the git backup ~/.bmem/backup;
//   GET  /v1/rollback/diff    changes over a window (?days=7): files +/−;
//   POST /v1/rollback         rollback to a point {point} with a pre-rollback commit;
//   POST /v1/forget           {project}: index to zero, files to ~/.bmem/forgotten;
//   POST /v1/shutdown         daemon lifecycle fix: graceful shutdown on request of the
//                             owning app (response, grace, drain, exit 0).
//
// The API key lives in Keychain (UI-5) — only the lan_access flag is here; localhost needs no key.
import Foundation
import BMemCore
import BMemAPI

// MARK: - Daemon lifecycle fix: in-flight counter + graceful shutdown
//
// The owning app must be able to take the daemon down without losing work:
// POST /v1/shutdown (or SIGTERM) stops accepting new requests at the client
// level (the connection closes after the response), gives in-flight requests
// a short drain and exits. Both transports update the counter:
// the unix socket (handler in main.swift) and HTTP (handleEmbedRequest).

final class InflightCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func begin() { lock.lock(); n += 1; lock.unlock() }
    func end() { lock.lock(); n -= 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

let inflight = InflightCounter()

/// Drain (budget BMemTuning.shutdownDrainSeconds — shutdown drain fix: 90 s so an
/// in-flight cold request survives a model reload) and exit 0. Called from a
/// background queue — it blocks on purpose, the daemon main thread is in a
/// sleep loop anyway.
func gracefulExit(_ reason: String) {
    FileHandle.standardError.write(Data("bmem: daemon shutdown (\(reason)), draining \(inflight.count) in-flight\n".utf8))
    let deadline = Date().addingTimeInterval(Double(BMemTuning.shutdownDrainSeconds))
    while inflight.count > 0 && Date() < deadline { usleep(250_000) }
    if inflight.count > 0 {
        FileHandle.standardError.write(Data("bmem: drain timeout, \(inflight.count) requests still in flight, exiting anyway\n".utf8))
    }
    exit(0)
}

// The config lives in memory + on disk; PUT mutates both. NSLock, not an
// actor: the call comes from a blocking GCD thread (semaphore pattern of
// Socket.swift), driving an actor through a semaphore ad hoc is the same
// lock but with a priority trap.
final class ControlState: @unchecked Sendable {
    private let lock = NSLock()
    private var _config: Config
    /// Daemon lifecycle fix: the actual idle-unload threshold (seconds) — the same
    /// idleTimeout that drives the watchdog in main.swift. Served in /v1/status,
    /// the UI renders sys.model.unloaded from it; default — one shared constant.
    let modelIdleTimeout: Double
    init(config: Config, modelIdleTimeout: Double = Double(BMemTuning.modelIdleTimeoutSeconds)) {
        _config = config
        self.modelIdleTimeout = modelIdleTimeout
    }
    var config: Config {
        lock.lock(); defer { lock.unlock() }
        return _config
    }
    /// Mutate and persist; throws if config.json did not save (the in-memory
    /// value then stays new — the facade sees an honest 500).
    func update(_ mutate: (inout Config) -> Void) throws {
        lock.lock()
        mutate(&_config)
        let snapshot = _config
        lock.unlock()
        try snapshot.save()
    }
}

/// «What I never touch» (screen 2 of the design) — read-only showcase list.
/// Not stored in config.json: the user cannot extend it from the interface.
let neverTouchList = ["~/.ssh", "~/.gnupg", "~/secrets", "~/Library/Keychains",
                      "~/Library/Mail", "~/Library/Caches"]

struct ControlResponse {
    let status: Int
    let json: [String: Any]
}

private func ok(_ json: [String: Any]) -> ControlResponse { ControlResponse(status: 200, json: json) }
private func err(_ status: Int, _ message: String, _ detail: String? = nil) -> ControlResponse {
    var j: [String: Any] = ["error": message]
    if let detail { j["detail"] = detail }
    return ControlResponse(status: status, json: j)
}

// MARK: - Router

let controlRoutes: Set<String> = ["/v1/status", "/v1/config", "/v1/search",
                                  "/v1/benchmark", "/v1/benchmark/custom",
                                  "/v1/benchmark/custom/recheck",
                                  "/v1/rollback/points",
                                  "/v1/rollback/diff", "/v1/rollback", "/v1/forget",
                                  "/v1/shutdown"]

/// Query-string parsing of the request line: k=v&k2=v2, percent-decoding, '+' = space.
func parseQueryString(_ target: String) -> [String: String] {
    guard let q = target.split(separator: "?", maxSplits: 1).dropFirst().first else { return [:] }
    var out: [String: String] = [:]
    for pair in q.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard let key = String(kv[0]).removingPercentEncoding else { continue }
        let rawVal = kv.count > 1 ? String(kv[1]) : ""
        out[key] = (rawVal.removingPercentEncoding ?? rawVal).replacingOccurrences(of: "+", with: " ")
    }
    return out
}

func handleControlRequest(method: String, path: String, query: [String: String],
                          body: Data, engine: Engine, state: ControlState) async -> ControlResponse {
    switch (method, path) {
    case ("GET", "/v1/status"):          return await controlStatus(state: state, engine: engine)
    case ("GET", "/v1/config"):          return ok(configJSON(state.config))
    case ("PUT", "/v1/config"):          return await controlPutConfig(body: body, state: state, engine: engine)
    case ("GET", "/v1/search"):          return await controlSearch(query: query, engine: engine, state: state)
    case ("GET", "/v1/benchmark"):       return controlBenchmark()
    case ("POST", "/v1/benchmark/custom"):
        return await controlBenchmarkCustom(body: body, engine: engine, state: state)
    case ("POST", "/v1/benchmark/custom/recheck"):
        return await controlBenchmarkRecheck(engine: engine, state: state)
    case ("GET", "/v1/rollback/points"): return controlRollbackPoints(state: state)
    case ("GET", "/v1/rollback/diff"):   return controlRollbackDiff(query: query, state: state)
    case ("POST", "/v1/rollback"):       return controlRollback(body: body, state: state)
    case ("POST", "/v1/forget"):         return await controlForget(body: body, state: state, engine: engine)
    case ("POST", "/v1/shutdown"):       return controlShutdown()
    default:                             return err(404, "not found: \(method) \(path)")
    }
}

/// Daemon lifecycle fix: polite shutdown on request of the owning app.
/// The response goes out first, the exit follows a grace second later on a
/// background queue (in-flight drain inside gracefulExit).
private func controlShutdown() -> ControlResponse {
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
        gracefulExit("POST /v1/shutdown")
    }
    return ok(["ok": true, "exiting": true])
}

// MARK: - GET /v1/status

private func controlStatus(state: ControlState, engine: Engine) async -> ControlResponse {
    let cfg = state.config
    let s = await engine.daemonStatus()
    let iso = ISO8601DateFormatter()
    let projects: [[String: Any]] = s.projects.map { p in
        ["name": p.name, "notes": p.notes, "chunks": p.chunks,
         "open": p.open, "failed": p.failed,
         "indexed_at": p.indexedAt.map { iso.string(from: $0) } ?? NSNull()]
    }
    return ok([
        "version": "1.1.2-beta3",
        "engine": embedModelName,
        "engine_dim": embedModelDim,
        "model_loaded": s.modelLoaded,
        // Daemon lifecycle fix: pid — so the owning app can take the daemon down by
        // signal; model_idle_timeout_s — the actual watchdog threshold, the UI
        // renders sys.model.unloaded from it (no literal «90 s» anywhere).
        "pid": Int(getpid()),
        "model_idle_timeout_s": Int(state.modelIdleTimeout),
        "memory_mb": (s.footprintMB * 10).rounded() / 10,
        "memory_peak_mb": (s.peakMB * 10).rounded() / 10,
        "memory_limit_mb": cfg.memoryLimitMB,
        "autostart": cfg.launchAtLogin,
        "lan_access": cfg.lanAccess,
        "telemetry": cfg.telemetry,
        // Index reporting: three separate numbers instead of an eternally-dirty index.
        // indexed — notes in the DB; open — normally pending (session tails
        // >256 KB, fresh files after the last run); failed — genuinely unreadable.
        // dirty=yes only when failed>0 or an open file older than 24 h.
        "index": ["total_chunks": s.totalChunks,
                  "total_notes": s.projects.reduce(0) { $0 + $1.notes },
                  "indexed": s.projects.reduce(0) { $0 + $1.notes },
                  "open": s.openFiles,
                  "failed": s.failedFiles,
                  "dirty": s.dirty,
                  "projects": projects],
    ])
}

// MARK: - /v1/config

private func configJSON(_ cfg: Config) -> [String: Any] {
    ["projects": cfg.projects,
     "default_project": cfg.defaultProject,
     "min_similarity": cfg.minSimilarity,
     "exclude_dirs": cfg.excludeDirs,
     "engine": cfg.engine,
     "memory_limit_mb": cfg.memoryLimitMB,
     "lan_access": cfg.lanAccess,
     "telemetry": cfg.telemetry,
     "hotkey": cfg.hotkey,
     "launch_at_login": cfg.launchAtLogin,
     "auto_backup": cfg.autoBackup,
     "never_touch": neverTouchList]
}

/// PUT — partial: only known keys are accepted, unknown ones -> 400 (the
/// facade must catch typos in names instead of silently losing edits).
private func controlPutConfig(body: Data, state: ControlState, engine: Engine) async -> ControlResponse {
    guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
        return err(400, "invalid json body")
    }
    let allowed: Set<String> = ["projects", "default_project", "min_similarity", "exclude_dirs",
                                "engine", "memory_limit_mb", "lan_access", "telemetry",
                                "hotkey", "launch_at_login", "auto_backup"]
    let unknown = Set(obj.keys).subtracting(allowed)
    if !unknown.isEmpty {
        return err(400, "unknown keys: \(unknown.sorted().joined(separator: ", "))")
    }
    var patch = state.config
    var errors: [String] = []
    func bad(_ key: String) { errors.append("bad value for \(key)") }

    if let v = obj["projects"] {
        if let p = v as? [String: String], p.values.allSatisfy({ $0.hasPrefix("/") }) { patch.projects = p } else { bad("projects") }
    }
    if let v = obj["default_project"] as? String, !v.isEmpty { patch.defaultProject = v }
    else if obj["default_project"] != nil { bad("default_project") }
    if let v = obj["min_similarity"] as? Double, (0...1).contains(v) { patch.minSimilarity = v }
    else if obj["min_similarity"] != nil { bad("min_similarity") }
    if let v = obj["exclude_dirs"] as? [String] { patch.excludeDirs = v }
    else if obj["exclude_dirs"] != nil { bad("exclude_dirs") }
    if let v = obj["engine"] as? String, ["gemma", "qwen"].contains(v) { patch.engine = v }
    else if obj["engine"] != nil { bad("engine (gemma|qwen)") }
    if let v = obj["memory_limit_mb"] as? Double, v >= 0 { patch.memoryLimitMB = v }
    else if obj["memory_limit_mb"] != nil { bad("memory_limit_mb") }
    if let v = obj["lan_access"] as? Bool { patch.lanAccess = v }
    else if obj["lan_access"] != nil { bad("lan_access") }
    if let v = obj["telemetry"] as? Bool { patch.telemetry = v }
    else if obj["telemetry"] != nil { bad("telemetry") }
    if let v = obj["hotkey"] as? String, v.count <= 64 { patch.hotkey = v }
    else if obj["hotkey"] != nil { bad("hotkey") }
    if let v = obj["launch_at_login"] as? Bool { patch.launchAtLogin = v }
    else if obj["launch_at_login"] != nil { bad("launch_at_login") }
    if let v = obj["auto_backup"] as? Bool {
        patch.autoBackup = v
        // First enable of the feature — initialize ~/.bmem/backup + the first
        // commit right here: after the toggle the screen must show a point.
        if v {
            let m = BackupManager(config: patch)
            do {
                try m.ensureRepo()
                _ = try m.sync(reason: "memory auto-backup enabled")
            } catch {
                return err(500, "backup init failed", String(describing: error))
            }
        }
    }
    else if obj["auto_backup"] != nil { bad("auto_backup") }

    if !errors.isEmpty { return err(400, "invalid config", errors.joined(separator: "; ")) }
    do {
        try state.update { $0 = patch }
    } catch {
        return err(500, "config save failed", String(describing: error))
    }
    // UI-7: the engine must see new folders immediately (onboarding without a
    // daemon restart), otherwise the first search answers «unknown project».
    await engine.updateConfig(state.config)
    return ok(configJSON(state.config))
}

// MARK: - GET /v1/search

/// trust: all | human | agent. A note counts as agent-authored when its
/// frontmatter says `source: agent` (Notes.swift); everything else is human.
/// strictness 0..1 — the score floor (default — the engine threshold).
private func controlSearch(query: [String: String], engine: Engine, state: ControlState) async -> ControlResponse {
    guard let q = query["q"], !q.isEmpty else { return err(400, "q required") }
    let trust = query["trust"] ?? "all"
    guard ["all", "human", "agent"].contains(trust) else { return err(400, "trust must be all|human|agent") }
    var strictness: Double?
    if let s = query["strictness"] {
        guard let d = Double(s), (0...1).contains(d) else { return err(400, "strictness must be 0..1") }
        strictness = d
    }
    let limit = min(max(Int(query["limit"] ?? "10") ?? 10, 1), 100)
    let cfg = state.config
    let project = query["project"] ?? cfg.defaultProject
    // fetch with headroom: trust/strictness trim the sample after the engine
    let hits: [NoteHit]
    do {
        hits = try await engine.search(project: project, query: q, limit: min(limit * 3, 100))
    } catch EngineError.unknownProject(let p) {
        return err(404, "unknown project: \(p)")
    } catch {
        return err(500, "search failed", String(describing: error))
    }
    var filtered = hits
    if trust == "agent" { filtered = filtered.filter { $0.source == "agent" } }
    if trust == "human" { filtered = filtered.filter { $0.source != "agent" } }
    if let s = strictness { filtered = filtered.filter { $0.score >= s } }
    filtered = Array(filtered.prefix(limit))
    // UI-6: the panel subtitle «session/note · author · date» — type from
    // frontmatter and file mtime. Only the file head is read (first 4 KB) —
    // hits <=30, microseconds next to embedding the query.
    let iso = ISO8601DateFormatter()
    let results: [[String: Any]] = filtered.map { hit in
        var row: [String: Any] = ["title": hit.title, "permalink": hit.permalink,
                                  "content": hit.content, "score": hit.score,
                                  "file_path": hit.filePath, "source": hit.source]
        row["kind"] = noteKind(ofFileAt: hit.filePath)
        if let m = (try? FileManager.default.attributesOfItem(atPath: hit.filePath))?[.modificationDate] as? Date {
            row["mtime"] = iso.string(from: m)
        } else {
            row["mtime"] = NSNull()
        }
        return row
    }
    return ok(["query": q, "project": project, "trust": trust, "results": results])
}

/// frontmatter `type:` of the note («session», «note», …); no file/field — "note".
private func noteKind(ofFileAt path: String) -> String {
    guard let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)),
          let head = try? h.read(upToCount: 4096),
          let text = String(data: head, encoding: .utf8) else { return "note" }
    let lines = text.components(separatedBy: "\n")
    guard lines.first == "---" else { return "note" }
    for line in lines.dropFirst() {
        if line == "---" { break }
        let kv = line.split(separator: ":", maxSplits: 1)
        if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces) == "type" {
            let v = kv[1].trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { return v }
        }
    }
    return "note"
}

// MARK: - GET /v1/benchmark (+ custom benchmarks, UI-5)

/// Benchmark directory: $BMEM_EVALS_DIR -> ~/.bmem/evals -> evals next to the
/// binary repository (dev build .build/<cfg>/bmem) -> ./evals.
private func evalsDir() -> String? {
    let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    let candidates = [ProcessInfo.processInfo.environment["BMEM_EVALS_DIR"] ?? "",
                      Config.homeDir() + "/.bmem/evals",
                      exeDir.appendingPathComponent("../../evals").path,
                      exeDir.appendingPathComponent("../../../evals").path,
                      "evals"]
    return candidates.first { FileManager.default.fileExists(atPath: $0) }
}

/// evals/custom.json: {"entries":[{id, question, expected_file, created_at,
/// last_check:{hit, top1, checked_at}}]}. The file is read/written whole —
/// records are few, no locking needed (one GCD thread per request, atomic write).
private func loadCustomEntries(dir: String) -> [[String: Any]] {
    guard let data = FileManager.default.contents(atPath: dir + "/custom.json"),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
    return obj["entries"] as? [[String: Any]] ?? []
}

private func saveCustomEntries(dir: String, _ entries: [[String: Any]]) throws {
    let data = try JSONSerialization.data(withJSONObject: ["entries": entries],
                                          options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: dir + "/custom.json"), options: .atomic)
}

private func customSummary(_ entries: [[String: Any]]) -> [String: Any] {
    ["total": entries.count,
     "hit": entries.filter { ($0["last_check"] as? [String: Any])?["hit"] as? Bool == true }.count,
     "entries": entries]
}

/// Checking one custom benchmark: search by the question, take top1, compare files.
/// A hit is an exact path, a suffix at a directory boundary or equal file names —
/// the user types what they see in Finder.
private func checkCustomEntry(question: String, expectedFile: String,
                              engine: Engine, state: ControlState) async -> [String: Any] {
    let iso = ISO8601DateFormatter()
    var check: [String: Any] = ["hit": false, "top1": NSNull(), "checked_at": iso.string(from: Date())]
    let project = state.config.defaultProject
    guard let hits = try? await engine.search(project: project, query: question, limit: 5),
          let top = hits.first else {
        return check
    }
    check["top1"] = top.filePath
    let expected = expectedFile.replacingOccurrences(of: "~", with: Config.homeDir())
    let got = top.filePath
    func samePath(_ a: String, _ b: String) -> Bool {
        if a.caseInsensitiveCompare(b) == .orderedSame { return true }
        if a.hasSuffix("/" + b) || b.hasSuffix("/" + a) { return true }
        return (a as NSString).lastPathComponent.caseInsensitiveCompare(
            (b as NSString).lastPathComponent) == .orderedSame
    }
    check["hit"] = samePath(got, expected)
    return check
}

/// GET: frozen benchmark numbers from evals/run-*.json + the custom section.
/// Neither run files nor custom — an honest 404; at least one present — we answer.
private func controlBenchmark() -> ControlResponse {
    let key = embedModelName == "embeddinggemma-2" ? "gemma" : "qwen"
    guard let dir = evalsDir() else {
        return err(404, "no benchmark data", "evals directory not found")
    }
    let custom = customSummary(loadCustomEntries(dir: dir))
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
        .filter { $0.hasPrefix("run-") && $0.hasSuffix(".json") }.sorted() ?? []
    let latest = files.last ?? ""
    if !latest.isEmpty,
       let data = FileManager.default.contents(atPath: dir + "/" + latest),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let bench = obj["bench"] as? [String: Any],
       let entry = bench[key] as? [String: Any],
       let total = entry["n"] as? Int, let hit = entry["top1"] as? Int {
        let runDate = (obj["meta"] as? [String: Any])?["run_date"] as? String ?? ""
        return ok(["engine": key, "total": total, "hit": hit,
                   "run_date": runDate, "source": latest, "custom": custom])
    }
    // The frozen benchmark was not run, but custom entries exist — answer with
    // zeros in the main part, the screen tells total=0 apart and shows custom only.
    if (custom["total"] as? Int ?? 0) > 0 {
        return ok(["engine": key, "total": 0, "hit": 0,
                   "run_date": "", "source": NSNull(), "custom": custom])
    }
    return err(404, "no benchmark data", "no parsable run-*.json in \(dir)")
}

/// POST {question, expected_file}: add a custom benchmark, check it right away.
private func controlBenchmarkCustom(body: Data, engine: Engine, state: ControlState) async -> ControlResponse {
    guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let question = obj["question"] as? String, !question.trimmingCharacters(in: .whitespaces).isEmpty,
          let expected = obj["expected_file"] as? String, !expected.trimmingCharacters(in: .whitespaces).isEmpty
    else { return err(400, "question and expected_file required") }
    guard let dir = evalsDir() else {
        return err(503, "evals directory not found")
    }
    var entry: [String: Any] = ["id": UUID().uuidString.lowercased(),
                                "question": question, "expected_file": expected,
                                "created_at": ISO8601DateFormatter().string(from: Date())]
    entry["last_check"] = await checkCustomEntry(question: question, expectedFile: expected,
                                                 engine: engine, state: state)
    var entries = loadCustomEntries(dir: dir)
    entries.append(entry)
    do { try saveCustomEntries(dir: dir, entries) }
    catch { return err(500, "custom.json save failed", String(describing: error)) }
    return ok(["ok": true, "entry": entry, "custom": customSummary(entries)])
}

/// POST: re-check all custom benchmarks with the current engine (screen button).
private func controlBenchmarkRecheck(engine: Engine, state: ControlState) async -> ControlResponse {
    guard let dir = evalsDir() else { return err(503, "evals directory not found") }
    var entries = loadCustomEntries(dir: dir)
    guard !entries.isEmpty else {
        return ok(["ok": true, "custom": customSummary(entries)])
    }
    for i in entries.indices {
        guard let q = entries[i]["question"] as? String,
              let f = entries[i]["expected_file"] as? String else { continue }
        entries[i]["last_check"] = await checkCustomEntry(question: q, expectedFile: f,
                                                          engine: engine, state: state)
    }
    do { try saveCustomEntries(dir: dir, entries) }
    catch { return err(500, "custom.json save failed", String(describing: error)) }
    return ok(["ok": true, "custom": customSummary(entries)])
}

// MARK: - rollback / forget (UI-4)

/// The backup manager is built on the live config per call: PUT /v1/config
/// can change projects between requests, caching it is not allowed.
private func backupManager(state: ControlState) -> BackupManager {
    BackupManager(config: state.config)
}

/// Rollback points = commits of ~/.bmem/backup. Without backup enabled — an
/// honest empty list with git_backup=false (the screen shows the toggle, not a list).
private func controlRollbackPoints(state: ControlState) -> ControlResponse {
    let m = backupManager(state: state)
    var json: [String: Any] = [
        "git_backup": m.repoExists,
        "auto_backup": state.config.autoBackup,
        "schedule": "every day at 03:00",
        "backup_dir": m.backupDir,
    ]
    guard m.repoExists else {
        json["points"] = []
        return ok(json)
    }
    do {
        json["points"] = try m.points().map { p in
            ["commit": p.commit, "date": p.date, "author": p.author,
             "message": p.message, "changes": p.changes]
        }
    } catch {
        return err(500, "git log failed", String(describing: error))
    }
    return ok(json)
}

/// Changes over a window (for the «Diff for a week» view): from the state
/// before the window first commit to HEAD. An empty window — an empty answer, not an error.
private func controlRollbackDiff(query: [String: String], state: ControlState) -> ControlResponse {
    let days = min(max(Int(query["days"] ?? "7") ?? 7, 1), 90)
    do {
        let d = try backupManager(state: state).diff(days: days)
        return ok(["days": days, "commits": d.commits,
                   "files": d.files.map { ["path": $0.path, "added": $0.added, "deleted": $0.deleted] }])
    } catch {
        return err(500, "diff failed", String(describing: error))
    }
}

/// Rollback to a point. 409 — backup not enabled (nothing to roll back), 404 — no such point.
/// The merge rule is in the header of Backup.swift; notes written after the
/// point are not lost: the rollback adds files and leaves uncommitted edits alone.
private func controlRollback(body: Data, state: ControlState) -> ControlResponse {
    guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let point = obj["point"] as? String, !point.isEmpty else {
        return err(400, "point required")
    }
    let m = backupManager(state: state)
    guard m.repoExists else {
        return err(409, "backup not enabled",
                   "no git backup — enable auto_backup (PUT /v1/config)")
    }
    do {
        let r = try m.rollback(to: point)
        return ok(["ok": true, "pre_rollback_commit": r.preCommit,
                   "restored": r.restored, "reverted": r.reverted, "kept_newer": r.keptNewer])
    } catch BackupError.unknownPoint(let p) {
        return err(404, "unknown point: \(p)")
    } catch {
        return err(500, "rollback failed", String(describing: error))
    }
}

/// «Forget project»: backup commit (if the repository exists) -> files to
/// ~/.bmem/forgotten -> index to zero -> project out of config. Files are not
/// deleted but archived — the action is reversible without git.
private func controlForget(body: Data, state: ControlState, engine: Engine) async -> ControlResponse {
    guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let project = obj["project"] as? String, !project.isEmpty else {
        return err(400, "project required")
    }
    guard state.config.projects[project] != nil else {
        return err(404, "unknown project: \(project)")
    }
    let m = backupManager(state: state)
    if m.repoExists { _ = try? m.sync(reason: "before forget project \(project)") }
    let archived: (archivedTo: String, files: Int)
    do {
        archived = try m.archiveProject(project)
    } catch {
        return err(500, "archive failed", String(describing: error))
    }
    let dropped = await engine.dropProject(project)
    do {
        try state.update { $0.projects[project] = nil }
    } catch {
        return err(500, "config save failed", String(describing: error))
    }
    await engine.updateConfig(state.config)  // UI-7: the engine forgets the path too
    return ok(["ok": true, "archived_to": archived.archivedTo,
               "files_archived": archived.files,
               "notes_removed": dropped.notes, "chunks_removed": dropped.chunks])
}
