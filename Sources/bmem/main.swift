// bmem — native memory server: MCP stdio + CLI + daemon.
//
// Modes:
//   bmem mcp                     — MCP stdio server. If a daemon is alive — thin proxy
//                                  (no model load per spawn); if not — it starts a
//                                  daemon itself and waits for the socket up to 180 s
//                                  (cold ANE start); otherwise embedded mode.
//                                  BMEM_NO_DAEMON=1 — force embedded.
//                                  BMEM_PROXY=1 — force daemon/proxy.
//   bmem daemon                  — resident server: model + index over a unix socket.
//   bmem index [--project P]     — rebuild the index
//   bmem search <query> [--project P] [--limit N]
//   bmem context <ident> [--project P]
//   bmem bench [--project P]     — discriminator: 10 Russian queries, expected top-1
import Foundation
import System
import Logging
import MCP
import BMemCore
import BMemAPI

// FOOTPRINT-FIX2 (REVIEW-1 FAIL-2): writing to a closed socket (a dead
// embed-worker; an MCP/HTTP client that dropped on timeout, as in production on
// 17.10 10:49:45) sends the process SIGPIPE, whose default action is death. The
// daemon must get EPIPE and go into its retry/respawn, not die silently. The
// ignore is inherited across exec, so ONE place here covers the child
// `bmem embed-worker` too (spawnWorker -> Process -> the same binary).
signal(SIGPIPE, SIG_IGN)

let argv = CommandLine.arguments
func flag(_ name: String, _ def: String = "") -> String {
    if let i = argv.firstIndex(of: name), i + 1 < argv.count { return argv[i + 1] }
    return def
}

let mode = argv.count > 1 ? argv[1] : "help"
let projectName = flag("--project", "hermes")

var config = Config.load()
if let p = ProcessInfo.processInfo.environment["BMEM_PROJECT_PATH"] {
    config.projects[projectName] = p
}
// UI-1: engine from config.json (env BMEM_EMBED_BACKEND takes precedence, it also
// overrides on stands). setenv before creating the Engine: embedModelTag
// reads env in init, and EmbedServer lazy globals — on first access;
// both happen after this line.
if ProcessInfo.processInfo.environment["BMEM_EMBED_BACKEND"] == nil, !config.engine.isEmpty {
    setenv("BMEM_EMBED_BACKEND", config.engine, 1)
}
// FOOTPRINT fix (see EmbedWorker.swift): the child embed-engine process —
// serves the embed socket and does not touch the DB. BMEM_EMBED_BACKEND is already
// inherited (or set above from config).
if mode == "embed-worker" {
    setenv("BMEM_EMBED_SUBPROCESS", "0", 1)
    EmbedWorkerServer.run(socketPath: argv.count > 2 ? argv[2] : EmbedWorkerLink.socketPath())
}
let dbPath = ProcessInfo.processInfo.environment["BMEM_DB"]
    ?? Config.homeDir() + "/.bmem/bmem.db"
try FileManager.default.createDirectory(atPath: Config.homeDir() + "/.bmem", withIntermediateDirectories: true)

let engine = try Engine(dbPath: dbPath, config: config)

func resolveProject(_ args: [String: Value]) -> String {
    args["project"]?.stringValue ?? projectName
}

func resolveLimit(_ args: [String: Value]) -> Int {
    args["page_size"]?.intValue ?? args["limit"]?.intValue ?? 10
}

// MARK: - JSON helpers

func jsonString(_ obj: Any) -> String {
    guard JSONSerialization.isValidJSONObject(obj),
          let data = try? JSONSerialization.data(withJSONObject: obj),
          let s = String(data: data, encoding: .utf8) else {
        return "{\"error\":\"json encode failed\"}"
    }
    return s
}

func argStr(_ args: [String: Value], _ keys: [String]) -> String? {
    for k in keys { if let s = args[k]?.stringValue, !s.isEmpty { return s } }
    return nil
}

func hitDict(_ h: NoteHit) -> [String: Any] {
    ["title": h.title, "permalink": h.permalink, "content": h.content,
     "score": h.score, "file_path": h.filePath]
}

// MARK: - Tool dispatch (shared by embedded, daemon and proxy receiver)

func dispatchTool(engine: Engine, config: Config, name: String, args: [String: Value],
                  project: String, limit: Int) async -> (String, Bool) {
    func call<T>(_ body: () async throws -> T, _ ok: (T) -> [String: Any]) async -> (String, Bool) {
        do { return (jsonString(try await ok(body())), false) }
        catch EngineError.notFound(let m) { return (jsonString(["error": "NOT_FOUND", "detail": m]), true) }
        catch EngineError.alreadyExists(let p) { return (jsonString(["error": "NOTE_ALREADY_EXISTS", "title": p, "permalink": p]), false) }
        catch EngineError.unknownProject(let p) { return (jsonString(["error": "UNKNOWN_PROJECT", "detail": p]), true) }
        catch EngineError.notSupported(let m) { return (jsonString(["error": "NOT_SUPPORTED", "detail": m]), true) }
        catch { return (jsonString(["error": "ENGINE", "detail": String(describing: error)]), true) }
    }

    switch name {
    case "search_notes":
        guard let q = args["query"]?.stringValue, !q.isEmpty else {
            return (jsonString(["error": "BAD_ARGS", "detail": "query required"]), true)
        }
        return await call({ try await engine.search(project: project, query: q, limit: limit) }) { hits in
            ["results": hits.map(hitDict)]
        }

    case "read_note":
        guard let ident = argStr(args, ["identifier", "permalink", "path"]) else {
            return (jsonString(["error": "BAD_ARGS", "detail": "identifier required"]), true)
        }
        return await call({ try await engine.read(project: project, identifier: ident) }) { r in
            ["title": r.title, "permalink": r.permalink, "content": r.content,
             "file_path": r.filePath, "frontmatter": NSNull(), "checksum": r.checksum]
        }

    case "write_note":
        guard let title = args["title"]?.stringValue, let content = args["content"]?.stringValue else {
            return (jsonString(["error": "BAD_ARGS", "detail": "title/content required"]), true)
        }
        let dir = args["directory"]?.stringValue ?? args["folder"]?.stringValue ?? "notes"
        let tags = args["tags"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        let overwrite = args["overwrite"]?.boolValue ?? false
        return await call({ try await engine.write(project: project, title: title, content: content, directory: dir, tags: tags, overwrite: overwrite) }) { r in
            ["title": r.title, "permalink": r.permalink, "file_path": r.filePath, "action": "created"]
        }

    case "edit_note":
        guard let ident = args["identifier"]?.stringValue,
              let op = args["operation"]?.stringValue,
              let content = argStr(args, ["content", "new_content", "replacement", "replace_with"]) else {
            return (jsonString(["error": "BAD_ARGS", "detail": "identifier/operation/content required"]), true)
        }
        let findText = argStr(args, ["find_text", "find", "old_text", "old_content", "search"])
        let section = argStr(args, ["section", "section_heading", "heading"])
        return await call({ try await engine.edit(project: project, identifier: ident, operation: op, content: content, findText: findText, section: section) }) { r in
            ["title": r.title, "permalink": r.permalink, "file_path": r.filePath, "operation": op, "checksum": r.checksum]
        }

    case "build_context":
        guard let url = args["url"]?.stringValue else {
            return (jsonString(["error": "BAD_ARGS", "detail": "url required"]), true)
        }
        do {
            let r = try await engine.buildContext(project: project, identifier: url, limit: limit)
            func hitKind(_ h: NoteHit, _ kind: String) -> [String: Any] {
                hitDict(h).merging(["kind": kind]) { $1 }
            }
            let targetDict: [String: Any] = ["title": r.target.title, "permalink": r.target.permalink,
                                             "content": String(r.target.content.prefix(600)),
                                             "score": 1.0, "file_path": r.target.filePath, "kind": "target"]
            let related = r.graph.map { hitKind($0.0, $0.1) } + r.vector.map { hitKind($0, "vector") }
            return (jsonString(["target": targetDict, "related": related]), false)
        } catch {
            return (jsonString(["error": "ENGINE", "detail": String(describing: error)]), true)
        }

    case "recent_activity":
        return await call({ await engine.recent(project: project, limit: limit) }) { hits in
            ["items": hits.map(hitDict), "results": hits.map(hitDict)]
        }

    case "list_memory_projects":
        let list: [[String: Any]] = config.projects.sorted { $0.key < $1.key }.map {
            ["name": $0.key, "external_id": $0.key, "path": $0.value, "mode": "local", "is_default": $0.key == config.defaultProject]
        }
        return (jsonString(["projects": list, "default": config.defaultProject]), false)

    case "list_workspaces":
        return (jsonString(["workspaces": [["name": "personal", "type": "personal", "role": "owner", "is_default": true]]]), false)

    case "create_memory_project":
        guard let pname = args["project_name"]?.stringValue ?? args["name"]?.stringValue,
              let ppath = args["project_path"]?.stringValue ?? args["path"]?.stringValue else {
            return (jsonString(["error": "BAD_ARGS", "detail": "project_name/project_path required"]), true)
        }
        try? await engine.reindex(project: pname)
        return (jsonString(["name": pname, "path": ppath, "ok": true]), false)

    case "delete_note":
        guard let ident = args["identifier"]?.stringValue else {
            return (jsonString(["error": "BAD_ARGS", "detail": "identifier required"]), true)
        }
        return await call({ try await engine.deleteNote(project: project, identifier: ident) }) { ok in
            ["ok": ok, "identifier": ident]
        }

    case "move_note":
        guard let ident = args["identifier"]?.stringValue,
              let folder = args["new_folder"]?.stringValue else {
            return (jsonString(["error": "BAD_ARGS", "detail": "identifier/new_folder required"]), true)
        }
        return await call({ try await engine.moveNote(project: project, identifier: ident, newFolder: folder) }) { ok in
            ["ok": ok, "identifier": ident, "new_folder": folder]
        }

    case "schema_validate", "schema_infer", "schema_diff":
        return (jsonString(["error": "NOT_SUPPORTED", "detail": "schema tools are not implemented in bmem v1"]), true)

    default:
        return (jsonString(["error": "UNKNOWN_TOOL", "detail": name]), true)
    }
}

// MARK: - Tool definitions

func strProp(_ desc: String) -> Value { .object(["type": .string("string"), "description": .string(desc)]) }

func schema(_ props: [String: Value], _ required: [String] = []) -> Value {
    var obj: [String: Value] = ["type": .string("object"), "properties": .object(props)]
    if !required.isEmpty { obj["required"] = .array(required.map(Value.string)) }
    return .object(obj)
}

let toolDefs: [Tool] = [
    Tool(name: "search_notes",
         description: "Search notes in the markdown knowledge base (vector + full-text hybrid).",
         inputSchema: schema(["query": strProp("Search terms"), "page": .object(["type": .string("integer")]),
                              "page_size": .object(["type": .string("integer")]), "output_format": strProp("json or text"),
                              "project": strProp("Project name"), "project_id": strProp("Project id"),
                              "tags": .object(["type": .string("array")]), "status": strProp("status filter"),
                              "note_types": .object(["type": .string("array")]), "entity_types": .object(["type": .string("array")])])),
    Tool(name: "read_note",
         description: "Read a note by title, permalink, or memory:// URL.",
         inputSchema: schema(["identifier": strProp("Note title, permalink, or memory:// URL"),
                              "include_frontmatter": .object(["type": .string("boolean")]),
                              "output_format": strProp("json or text"),
                              "project": strProp("Project name"), "project_id": strProp("Project id")], ["identifier"])),
    Tool(name: "write_note",
         description: "Create a markdown note in the knowledge base.",
         inputSchema: schema(["title": strProp("Note title"), "content": strProp("Markdown body"),
                              "directory": strProp("Folder path within the project"),
                              "overwrite": .object(["type": .string("boolean")]),
                              "tags": .object(["type": .string("array")]),
                              "project": strProp("Project name"), "project_id": strProp("Project id")],
                             ["title", "content", "directory"])),
    Tool(name: "edit_note",
         description: "Edit an existing note: append, prepend, find_replace, replace_section.",
         inputSchema: schema(["identifier": strProp("Note title or permalink"),
                              "operation": .object(["type": .string("string"), "enum": .array([.string("append"), .string("prepend"), .string("find_replace"), .string("replace_section")])]),
                              "content": strProp("Replacement/addition content"),
                              "find_text": strProp("Text to replace (find_replace)"),
                              "section": strProp("Section heading (replace_section)"),
                              "expected_replacements": .object(["type": .string("integer")]),
                              "output_format": strProp("json or text"),
                              "project": strProp("Project name"), "project_id": strProp("Project id")],
                             ["identifier", "operation", "content"])),
    Tool(name: "build_context",
         description: "Navigate from a note to related notes (wikilink graph 1-hop + vector similarity).",
         inputSchema: schema(["url": strProp("memory:// URL or note identifier"),
                              "depth": .object(["type": .string("integer")]),
                              "project": strProp("Project name")], ["url"])),
    Tool(name: "recent_activity",
         description: "List recently updated notes.",
         inputSchema: schema(["timeframe": strProp("Lookback window, e.g. 7d"),
                              "limit": .object(["type": .string("integer")]),
                              "project": strProp("Project name")])),
    Tool(name: "list_memory_projects", description: "List configured memory projects (workspaces).",
         inputSchema: schema([:])),
    Tool(name: "list_workspaces", description: "List workspaces (local mode: personal only).",
         inputSchema: schema([:])),
    Tool(name: "create_memory_project", description: "Register a new project directory.",
         inputSchema: schema(["project_name": strProp("Project name"), "project_path": strProp("Absolute path"),
                              "name": strProp("Project name"), "path": strProp("Absolute path"),
                              "set_default": .object(["type": .string("boolean")])], ["project_name", "project_path"])),
    Tool(name: "delete_note", description: "Delete a note file and its index rows.",
         inputSchema: schema(["identifier": strProp("Note title or permalink"),
                              "project": strProp("Project name")], ["identifier"])),
    Tool(name: "move_note", description: "Move a note to another folder.",
         inputSchema: schema(["identifier": strProp("Note title or permalink"),
                              "new_folder": strProp("Target folder"),
                              "project": strProp("Project name")], ["identifier", "new_folder"])),
    Tool(name: "schema_validate", description: "Not implemented in bmem v1.", inputSchema: schema([:])),
    Tool(name: "schema_infer", description: "Not implemented in bmem v1.", inputSchema: schema([:])),
    Tool(name: "schema_diff", description: "Not implemented in bmem v1.", inputSchema: schema([:])),
]

// MARK: - Daemon transport helpers

let socketPath = ProcessInfo.processInfo.environment["BMEM_SOCKET"]
    ?? Config.homeDir() + "/.bmem/bmem.sock"

func proxyToolCall(path: String, tool: String, args: [String: Value],
                   project: String, limit: Int) async -> (String, Bool) {
    return await withCheckedContinuation { (cont: CheckedContinuation<(String, Bool), Never>) in
        DispatchQueue.global(qos: .userInitiated).async {
            // the payload is built INSIDE the closure: a @Sendable closure does not
            // capture non-Sendable [String: Any] from outside (warning 272:47).
            // args is [String: Value], Value: Sendable, so capturing args is legal.
            let payload: [String: Any] = ["tool": tool, "args": args.mapValues(fromValue),
                                          "project": project, "limit": limit]
            let r = daemonCall(path, payload: payload)
            cont.resume(returning: r ?? (jsonString(["error": "DAEMON_DOWN", "detail": path]), true))
        }
    }
}

func spawnDaemon(probePath: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: argv[0]).resolvingSymlinksInPath()
    p.arguments = ["daemon"]
    var env = ProcessInfo.processInfo.environment
    env["BMEM_SOCKET"] = probePath
    p.environment = env
    let logPath = Config.homeDir() + "/.bmem/daemon.log"
    FileManager.default.createFile(atPath: logPath, contents: nil)
    if let fh = FileHandle(forWritingAtPath: logPath) {
        p.standardError = fh
        p.standardOutput = fh
    } else {
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
    }
    do { try p.run() } catch { return false }
    // 1.1.1 (EMB-3): the first launch on a clean machine includes ANE compilation
    // of embed_* functions (77-120 s, once, cached in the mlmodelc next to the
    // model) — within the old 25 s the daemon could not bring the socket up, and the
    // first client fell back to embedded mode. Wait up to 180 s; exit early if the
    // daemon process died (a broken install must not hang the client).
    for _ in 0..<900 {
        usleep(200_000)
        if socketAlive(probePath) { return true }
        if !p.isRunning { return socketAlive(probePath) }
    }
    return socketAlive(probePath)
}

// MARK: - Modes

let configSnapshot = config  // Sendable snapshot for the daemon @Sendable callbacks
// UI-1: live config for the control API (PUT /v1/config mutates it and writes to disk).
// Daemon lifecycle fix: the idle-unload threshold is computed here once — the same value drives
// the watchdog in daemon mode, goes into /v1/status (model_idle_timeout_s)
// and into the sys.model.unloaded string. Default — BMemTuning (335, watchdog desync fix).
let modelIdleTimeout = Double(ProcessInfo.processInfo.environment["BMEM_MODEL_IDLE_TIMEOUT"]
                              ?? String(BMemTuning.modelIdleTimeoutSeconds))
    ?? Double(BMemTuning.modelIdleTimeoutSeconds)
let controlState = ControlState(config: config, modelIdleTimeout: modelIdleTimeout)

switch mode {
case "version", "--version", "-v":
    print("bmem 1.1.2-beta3")
case "mcp":
    var proxy = false
    let env = ProcessInfo.processInfo.environment
    let forceNo = env["BMEM_NO_DAEMON"] != nil
    let forceProxy = env["BMEM_PROXY"] != nil
    // BMEM_PROJECT_PATH — test project override: with it, proxying to the shared
    // daemon is disallowed by default (the daemon may have started with another config/DB).
    let testOverride = env["BMEM_PROJECT_PATH"] != nil
    if !forceNo, forceProxy || !testOverride {
        if socketAlive(socketPath) {
            proxy = true
            FileHandle.standardError.write(Data("bmem: proxy → daemon \(socketPath)\n".utf8))
        } else if spawnDaemon(probePath: socketPath) {
            proxy = true
            FileHandle.standardError.write(Data("bmem: daemon spawned, proxy mode\n".utf8))
        } else {
            FileHandle.standardError.write(Data("bmem: daemon unavailable, embedded mode\n".utf8))
        }
    }
    if !proxy {
        FileHandle.standardError.write(Data("bmem: embedded mode\n".utf8))
        let warmProjects = config.projects.keys.map { $0 }
        Task.detached {
            try? await engine.warm()
            for p in warmProjects { try? await engine.reindex(project: p) }
        }
    }
    let proxyMode = proxy  // immutable snapshot: the @Sendable callback must not catch a mutable var
    let server = Server(name: "bmem", version: "1.1.2-beta3", capabilities: .init(tools: .init()))
    await server.withMethodHandler(ListTools.self) { _ in .init(tools: toolDefs) }
    await server.withMethodHandler(CallTool.self) { params in
        let args = params.arguments ?? [:]
        let project = resolveProject(args)
        let limit = resolveLimit(args)
        let result: (String, Bool)
        if proxyMode {
            result = await proxyToolCall(path: socketPath, tool: params.name, args: args,
                                         project: project, limit: limit)
        } else {
            result = await dispatchTool(engine: engine, config: configSnapshot, name: params.name,
                                        args: args, project: project, limit: limit)
        }
        // structuredContent = machine-readable payload next to the text (MCP spec).
        // The OpenClaw plugin (openclaw-basic-memory) requires it; Hermes
        // dedups text==structured, the Obsidian transport is untouched.
        var structured: Value?
        if let data = result.0.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            structured = toValue(obj)
        }
        return CallTool.Result(content: [.text(text: result.0, annotations: nil, _meta: nil)],
                               structuredContent: structured,
                               isError: result.1)
    }
    let transport: StdioTransport
    if env["BMEM_DEBUG"] != nil {
        var l = Logger(label: "bmem.mcp", factory: { label in StreamLogHandler.standardError(label: label) })
        l.logLevel = .debug
        transport = StdioTransport(logger: l)
    } else {
        transport = StdioTransport()
    }
    try await server.start(transport: transport)
    // Watchdog stdin-EOF: the client closed stdin (died without kill) — give 5 s to
    // finish in-flight work and exit so dead proxies do not pile up.
    // NOT SIGIO/O_ASYNC: macOS delivers SIGIO on data arrival too, not only on
    // EOF — a live client would kill its proxy 5 s after the first message
    // (verified live 26.09: death 5.1 s after notifications).
    // So a separate thread: poll(1 s); «readable + 0 bytes in buffer» = EOF/HUP.
    Thread.detachNewThread {
        let stdinFd: Int32 = 0
        var st = stat()
        let isFile = fstat(stdinFd, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
        var nBytes: Int32 = 0
        let fionread: UInt = 0x4004_667F  // sys/filio.h _IOR('f',127,int); the macro is not visible to Swift
        while true {
            var fds = pollfd(fd: stdinFd, events: Int16(POLLIN), revents: 0)
            let r = poll(&fds, 1, 1000)
            let ev = Int32(fds.revents)
            var eof = false
            if r > 0 {
                if (ev & (POLLHUP | POLLNVAL)) != 0 {
                    eof = true  // pipe: writer end closed (client died)
                } else if isFile, (ev & POLLIN) != 0,
                          ioctl(stdinFd, fionread, &nBytes) == 0, nBytes == 0 {
                    eof = true  // regular file: reached the end (tests via < file)
                }
            }
            if eof {
                usleep(5_000_000)
                _exit(0)
            }
        }
    }
    // IMPORTANT (verified 2026-09-26): start() does NOT block on reading — it runs the
    // message-loop in a separate Task and returns immediately. Without an eternal hold
    // of the main task the process exits before the first message is handled (verified live).
    while true { try? await Task.sleep(for: .seconds(3600)) }

case "daemon":
    let ok = startSocketServer(path: socketPath) { req in
        // Daemon lifecycle fix: the unix transport also joins the drain during graceful
        // shutdown (POST /v1/shutdown / SIGTERM wait for in-flight to finish).
        inflight.begin()
        defer { inflight.end() }
        let t0 = Date()
        let (text, isError) = await dispatchTool(engine: engine, config: configSnapshot, name: req.tool,
                                                 args: req.args, project: req.project, limit: req.limit)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        FileHandle.standardError.write(Data("bmem: daemon \(req.tool) [\(req.project)] \(ms)ms err=\(isError)\n".utf8))
        return jsonString(["text": text, "isError": isError])
    }
    if !ok {
        FileHandle.standardError.write(Data("bmem: daemon not started (already running or bind failed)\n".utf8))
        exit(0)
    }
    FileHandle.standardError.write(Data("bmem: daemon socket up at \(socketPath)\n".utf8))
    // openai-compatible endpoint for external clients (OpenClaw memory.search etc.):
    // BMEM_EMBED_PORT sets the port, "0"/"off" disables it; default 8123.
    let embedPortEnv = ProcessInfo.processInfo.environment["BMEM_EMBED_PORT"] ?? "8123"
    if let embedPort = UInt16(embedPortEnv), embedPort > 0 {
        if startEmbedServer(port: embedPort, engine: engine, state: controlState) {
            FileHandle.standardError.write(Data("bmem: embed endpoint on http://127.0.0.1:\(embedPort)/v1 (\(embedModelName))\n".utf8))
        } else {
            FileHandle.standardError.write(Data("bmem: embed endpoint bind failed on :\(embedPort)\n".utf8))
        }
    }
    // Daemon lifecycle fix: SIGTERM/SIGINT — graceful (the same drain as POST
    // /v1/shutdown). The owning app sends SIGTERM to the old daemon;
    // the default behavior (instant death mid-reindex) is deliberately
    // changed to drain.
    // Shutdown drain fix: handlers moved into SignalShutdownMonitor — the same defect class
    // as FIX-6 (see MemoryPressureMonitor.swift): a closure from top-level is
    // inferred MainActor-isolated, GCD calls it on a utility queue, the isolation
    // assert dropped the daemon in SIGTRAP (rc=133) before the first drain line —
    // regression fixed in 1.1.2-beta2.
    // Keep the monitor in a top-level let: releasing it would cancel the sources.
    let signalMonitor = SignalShutdownMonitor()
    let warmProjects = config.projects.keys.map { $0 }
    Task.detached {
        // UI-4: a rollback point before reindexing (if the feature is on) —
        // a broken reindex must not be able to eat notes without a way
        // back.
        if controlState.config.autoBackup {
            _ = try? BackupManager(config: controlState.config).sync(reason: "before reindex")
        }
        try? await engine.warm()
        for p in warmProjects { try? await engine.reindex(project: p) }
        FileHandle.standardError.write(Data("bmem: daemon warm\n".utf8))
    }
    // UI-4: the «once a day at 03:00» scheduler. Tick every 10 minutes; if the daemon
    // was down at 03:00 the commit is caught up on the first tick after 03:00.
    // The flag is read live: the UI toggle works without a daemon restart.
    Task.detached {
        while true {
            try? await Task.sleep(for: .seconds(600))
            guard controlState.config.autoBackup else { continue }
            _ = try? BackupManager(config: controlState.config).dailyTick()
        }
    }
    // FIX-2 idle-watchdog: the model must not hang around for days. Poll every 10 s;
    // BMEM_MODEL_IDLE_TIMEOUT — idle seconds before unload (0 = never unload).
    // warm() above = lastUse now, so the first unload is possible no earlier than
    // the timeout after full warm-up.
    // Watchdog desync fix: default 335 s instead of 90. The 90 s
    // threshold did not survive nightly client polls (OpenClaw ~15 min, observer 2 h):
    // every poll hit the unload->cold-reload cycle (~67 s), and requests in the
    // transition window gave Code=8/9 (memory-watch-2026-10-17.md). 335 is a fixed
    // constant (BMemTuning); adaptive auto-tuning is deliberately not introduced.
    // The value is already computed on top-level — the same value is served in
    // /v1/status and renders the sys.model.unloaded string.
    let idleTimeout = modelIdleTimeout
    if idleTimeout > 0 {
        Task.detached {
            while true {
                try? await Task.sleep(for: .seconds(10))
                await engine.unloadModelIfIdle(timeout: idleTimeout)
            }
        }
    }
    // FIX-4: system memory pressure signal (macOS gives no per-process limits,
    // but gives DispatchSource). .warning — unload the model immediately without
    // waiting for the idle timer; .critical — plus PRAGMA shrink_memory;
    // .normal — nothing (the model reloads on demand, the FIX-2 path).
    // FIX-6: the source moved into MemoryPressureMonitor (BMemCore). The old handler
    // here read `pressureSource.mask` — a top-level let, and all top-level code is
    // isolated to MainActor (SE-0438); GCD called the handler on a utility queue,
    // the isolation assert dropped the daemon in SIGTRAP on real OS pressure
    // (6 reports on 13-14.10). Inside the Monitor the handler is nonisolated —
    // verified in SIL. Details: MemoryPressureMonitor.swift.
    let pressureMonitor = MemoryPressureMonitor(engine: engine)
    pressureMonitor.start()
    // FIX-5: observability of own memory + threshold fuse.
    // Every 60 s a detached task writes the mem line to the log
    // «mem: rss X MB footprint Y MB swap_used Z% (projects=N chunks=M)»;
    // BMEM_MEM_LIMIT_MB (default — config.memoryLimitMB, 8192 in the file) — footprint
    // above the threshold 5 samples in a row gives «mem: over limit, exiting» and exit(0):
    // residency is restored by the client auto-spawn (bmem mcp) or launchd.
    // 0 = threshold off (the log stays).
    let memLimitMB = Double(ProcessInfo.processInfo.environment["BMEM_MEM_LIMIT_MB"]
                            ?? String(controlState.config.memoryLimitMB)) ?? 8192
    // BMEM_MEM_INTERVAL_SEC — sample interval (default 60 s; the threshold-
    // experiment stands need a shorter one, otherwise 5 in a row is 5 minutes of waiting).
    let memInterval = Double(ProcessInfo.processInfo.environment["BMEM_MEM_INTERVAL_SEC"] ?? "60") ?? 60
    let memLogPath = ProcessInfo.processInfo.environment["BMEM_MEM_LOG"]
        ?? Config.homeDir() + "/.bmem/daemon.log"
    // Top-level runs on MainActor; @Sendable closure to call from a detached Task.
    let memLogLine: @Sendable (String) -> Void = { line in
        if let fh = FileHandle(forWritingAtPath: memLogPath) {
            try? fh.seekToEnd()
            try? fh.write(contentsOf: Data((line + "\n").utf8))
            try? fh.close()
        } else {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
    }
    Task.detached {
        while true {
            try? await Task.sleep(for: .seconds(memInterval))
            let s = await engine.memSample(limitMB: memLimitMB)
            memLogLine("bmem: " + s.line)
            if memLimitMB > 0 && s.overCount >= 5 {
                memLogLine("bmem: mem: over limit, exiting")
                exit(0)
            }
        }
    }
    // Test injection (FIX-4 acceptance): BMEM_CONTROL_FIFO — a named pipe the stand
    // writes "warning"/"critical"/"normal" to; blocking read in a separate thread,
    // the live DispatchSource is not faked meanwhile.
    if let fifoPath = ProcessInfo.processInfo.environment["BMEM_CONTROL_FIFO"] {
        Thread.detachNewThread {
            let fd = open(fifoPath, O_RDWR)  // O_RDWR: do not wait for a writer on open
            if fd < 0 {
                FileHandle.standardError.write(Data("bmem: control fifo open failed \(fifoPath)\n".utf8))
                return
            }
            var buf = [UInt8](repeating: 0, count: 64)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { usleep(200_000); continue }
                let word = String(bytes: buf[0..<n], encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // Semaphore pattern as in Socket.swift: the thread blocks because
                // detachNewThread does not accept an async closure.
                if let level = Engine.MemoryPressure(rawValue: word) {
                    let sem = DispatchSemaphore(value: 0)
                    Task { await engine.handleMemoryPressure(level); sem.signal() }
                    sem.wait()
                } else {
                    FileHandle.standardError.write(Data("bmem: unknown pressure '\(word)'\n".utf8))
                }
            }
        }
    }
    while true { try? await Task.sleep(for: .seconds(3600)) }

case "index":
    // UI-4: the same rollback point before reindexing as in the daemon.
    if config.autoBackup {
        _ = try? BackupManager(config: config).sync(reason: "before reindex")
    }
    let t0 = Date()
    let report = try await engine.reindex(project: projectName)
    // Index reporting: open — normally pending (session tails >256 KB and anything that
    // arrived during the run awaits); failed — genuinely unreadable.
    let openAfter = await engine.daemonStatus().projects
        .first(where: { $0.name == projectName })?.open ?? 0
    print("indexed \(projectName) in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
    print("added=\(report.added) updated=\(report.updated) unchanged=\(report.unchanged) "
          + "deleted=\(report.deleted) failed=\(report.failed) open=\(openAfter) "
          + "model_runs=\(report.modelRuns) chunks=\(report.chunksTotal)")

case "gc":
    let removed = await engine.gcEmbedCache()
    print("embed_cache gc: removed \(removed) orphaned vectors")

case "embed-probe":
    // Embedding cross-check (python reference): text vector by the active backend
    // (BMEM_EMBED_BACKEND). --kind query|document|raw, default raw.
    guard argv.count > 2 else { print("usage: bmem embed-probe <text> [--kind query|document|raw]"); exit(2) }
    let kind = flag("--kind", "raw")
    let vec = try await engine.embedProbe(argv[2], kind: kind)
    print(jsonString(["kind": kind, "dim": vec.count, "vec": vec]))

case "search":
    guard argv.count > 2 else { print("usage: bmem search <query>"); exit(2) }
    let q = argv[2]
    let limit = Int(flag("--limit", "5")) ?? 5
    do {
        let hits = try await engine.search(project: projectName, query: q, limit: limit)
        for h in hits { print(String(format: "%.3f", h.score), h.title, "|", String(h.content.prefix(80)).replacingOccurrences(of: "\n", with: " ")) }
        if hits.isEmpty { print("(no hits)") }
    } catch { print("error: \(error)") }

case "context":
    guard argv.count > 2 else { print("usage: bmem context <identifier>"); exit(2) }
    do {
        let r = try await engine.buildContext(project: projectName, identifier: argv[2], limit: 5)
        print("target: \(r.target.title)")
        for (h, k) in r.graph { print("  [\(k)]", h.title) }
        for h in r.vector { print("  [vec]", String(format: "%.3f", h.score), h.title) }
    } catch { print("error: \(error)") }

case "bench":
    let cases: [(String, String)] = [
        ("\u{0440}\u{0430}\u{0437}\u{043C}\u{0435}\u{0440} \u{043F}\u{043B}\u{0430}\u{0442}\u{044B} \u{041A}\u{043B}\u{0435}\u{0439}\u{043C}\u{043E}\u{0440}", "\u{041F}\u{043B}\u{0430}\u{0442}\u{044B}"), ("\u{0441}\u{0442}\u{043E}\u{0439}\u{043A}\u{0438} M3 \u{0432}\u{044B}\u{0441}\u{043E}\u{0442}\u{0430} \u{043C}\u{0438}\u{043B}\u{043B}\u{0438}\u{043C}\u{0435}\u{0442}\u{0440}\u{044B}", "\u{041F}\u{043B}\u{0430}\u{0442}\u{044B}"),
        ("\u{0447}\u{0435}\u{043C} \u{0437}\u{0430}\u{043A}\u{0440}\u{044B}\u{0442}\u{044C} \u{0434}\u{044B}\u{0440}\u{044B} JA3 JA4", "VPN"), ("\u{043C}\u{043E}\u{0434}\u{0435}\u{043B}\u{044C} \u{0434}\u{043B}\u{044F} \u{0432}\u{044B}\u{0440}\u{0435}\u{0437}\u{0430}\u{043D}\u{0438}\u{044F} \u{0444}\u{043E}\u{043D}\u{0430}", "\u{041C}\u{043E}\u{0434}\u{0435}\u{043B}\u{0438}"),
        ("\u{0441}\u{043A}\u{043E}\u{043B}\u{044C}\u{043A}\u{043E} VRAM \u{0443} TripoSG", "\u{041C}\u{043E}\u{0434}\u{0435}\u{043B}\u{0438}"), ("\u{043A}\u{0430}\u{043A}\u{043E}\u{0439} \u{043F}\u{043E}\u{0440}\u{0442} \u{0437}\u{0430}\u{043D}\u{0438}\u{043C}\u{0430}\u{0435}\u{0442} Kali MCP", "\u{041F}\u{043E}\u{0440}\u{0442}\u{044B}"),
        ("\u{0433}\u{0434}\u{0435} \u{0445}\u{0440}\u{0430}\u{043D}\u{0438}\u{0442}\u{044C} \u{0441}\u{0435}\u{043A}\u{0440}\u{0435}\u{0442}\u{044B} \u{043F}\u{0430}\u{0440}\u{043E}\u{043B}\u{0438}", "\u{0421}\u{0435}\u{043A}\u{0440}\u{0435}\u{0442}\u{044B}"), ("\u{043F}\u{043E}\u{0432}\u{0435}\u{0434}\u{0435}\u{043D}\u{0447}\u{0435}\u{0441}\u{043A}\u{0438}\u{0439} \u{0430}\u{043D}\u{0430}\u{043B}\u{0438}\u{0437} \u{0434}\u{0435}\u{0442}\u{0435}\u{043A}\u{0446}\u{0438}\u{0438} VPN", "VPN"),
        ("\u{0440}\u{0430}\u{0437}\u{043C}\u{0435}\u{0440}\u{044B} \u{043B}\u{043E}\u{0436}\u{0435}\u{043C}\u{0435}\u{043D}\u{0442}\u{0430} \u{043F}\u{043B}\u{0430}\u{0442}\u{044B} \u{043F}\u{043E}\u{043B}\u{043E}\u{0441}\u{0442}\u{044C}", "\u{041F}\u{043B}\u{0430}\u{0442}\u{044B}"), ("\u{043F}\u{0440}\u{043E}\u{0432}\u{0430}\u{0439}\u{0434}\u{0435}\u{0440}\u{044B} \u{043F}\u{0430}\u{043C}\u{044F}\u{0442}\u{0438} markdown \u{0434}\u{0435}\u{0440}\u{0435}\u{0432}\u{043E}", "\u{041F}\u{0430}\u{043C}\u{044F}\u{0442}\u{044C}"),
    ]
    var hits = 0
    for (q, exp) in cases {
        let r = try await engine.search(project: projectName, query: q, limit: 3)
        let top = r.first?.title ?? "-"
        let ok = top.contains(exp)
        hits += ok ? 1 : 0
        print((ok ? "OK  " : "MISS") + " \(q) -> \(top)")
    }
    print("top-1: \(hits)/\(cases.count)")

default:
    print("usage: bmem mcp | daemon | index | search <q> | context <ident> | bench  [--project P]")
}