// TextEmbedder wrapper: the actor serializes graph.run calls so parallel
// MCP requests do not run the model willy-nilly (CoreAIKit is marked
// @unchecked Sendable, but the graph internal thread safety is not guaranteed).
import Foundation
import CoreAIKitEmbeddings
import MachO

/// process footprint in MB (phys_footprint — the same number Activity Monitor
/// shows). Needed for the unload log: «model unloaded after Ns idle, footprint XMB».
public func processFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ti in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), ti, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return -1 }
    return Double(info.phys_footprint) / (1024 * 1024)
}

/// process RSS in MB via task_info(TASK_BASIC_INFO) — raw material for the mem
/// log lines (FIX-5). Differs from phys_footprint: RSS includes compressible
/// pages, footprint is the acceptance number (same as Activity Monitor).
public func processRSSMB() -> Double {
    var info = task_basic_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ti in
            task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), ti, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return -1 }
    return Double(info.resident_size) / (1024 * 1024)
}

/// Share of used swap in percent (sysctl vm.swapusage), -1 if unavailable.
public func swapUsedPct() -> Double {
    var mib = [CTL_VM, VM_SWAPUSAGE]
    var usage = xsw_usage()
    var len = MemoryLayout<xsw_usage>.size
    let r = mib.withUnsafeMutableBufferPointer { m in
        sysctl(m.baseAddress!, 2, &usage, &len, nil, 0)
    }
    guard r == 0, usage.xsu_total > 0 else { return -1 }
    return Double(usage.xsu_used) * 100.0 / Double(usage.xsu_total)
}

actor Embedder {
    private var inner: TextEmbedder?
    /// Embedding integration: CoreML backend EmbeddingGemma-2 (lives instead of inner when selected).
    private var gemma: GemmaCoreMLModel?
    /// FOOTPRINT fix: in subprocess mode the model lives in the child process
    /// (see EmbedWorker.swift), here there is only the client. internal: accessed
    /// from the extension in EmbedWorker.swift.
    var worker: EmbedWorkerClient?
    /// «spawn already in progress» flag (see spawnWorker).
    var spawnInProgress = false
    /// FOOTPRINT-FIX2 (REVIEW-1 FAIL-1): SERIAL queue of roundtrips to the
    /// embed-worker. One fd is shared by all daemon embed calls (MCP and HTTP
    /// are served in parallel), and blocking sendAll/recvAll of two threads mix
    /// bytes on one socket -> frame desync and a silently cached foreign vector
    /// in embed_cache. The queue guarantees that a request-reply on the
    /// worker socket is an atomic sequence.
    let workerIO = DispatchQueue(label: "bmem.embed-worker.io")
    private var loadStart: Date?
    /// Internal «model was touched» counter (idle watchdog). internal — updated
    /// by the worker client from the extension.
    var lastUse = Date()
    /// Watchdog desync fix: worker rebuild counter (killWorker increments it). The reap
    /// task needs it to avoid unlinking an already-new child socket file.
    var generation = 0
    /// Watchdog desync fix: the current client is MIRRORED on the workerIO queue. All fd
    /// operations (round-trip, close, spawn socket/connect) live on workerIO —
    /// read/written only there. nonisolated(unsafe) — the «workerIO only» contract.
    nonisolated(unsafe) var ioClient: EmbedWorkerClient?
    /// Test hook (watchdog desync fix): replace child spawning — returns a ready client
    /// (fake server) so kill/reload stands do not run a live model.
    /// nil = real Process spawn.
    var spawnOverrideForTests: ((String) throws -> EmbedWorkerClient)?

    /// Backend choice. Since 1.1.1 the default is EmbeddingGemma-2 CoreML
    /// (A/B evaluation: top-1 58/70 vs 50/70, reindex 2.2x faster); explicit
    /// BMEM_EMBED_BACKEND=qwen rolls back to Qwen3-CoreAI (the bundle stays in
    /// ~/.bmem/models). The value "gemma" is accepted for compatibility with
    /// the embedding A/B stands.
    nonisolated static func prefersGemma() -> Bool {
        (ProcessInfo.processInfo.environment["BMEM_EMBED_BACKEND"] ?? "").lowercased() != "qwen"
    }

    /// Seconds since the last model access (for the watchdog in daemon mode).
    public func idleSeconds() -> TimeInterval {
        Date().timeIntervalSince(lastUse)
    }

    /// Is the model in memory right now?
    public var isLoaded: Bool { inner != nil || gemma != nil || worker != nil }

    /// Release TextEmbedder: the last strong ref to GraphModel goes — fp16
    /// weights and activation buffers return to the OS. The next ensureLoaded
    /// loads again (warm page cache — seconds).
    /// The «idled >= timeout» check and the inner reset are atomic inside the
    /// actor: a fresh embed must not squeeze in between the outer check and unload.
    public func unloadIfIdle(timeout: TimeInterval) {
        guard inner != nil || gemma != nil || worker != nil else { return }
        let idle = Date().timeIntervalSince(lastUse)
        guard idle >= timeout else { return }
        unloadNow(reason: String(format: "after %.0fs idle", idle))
    }

    /// Forced unload (tests/manual reset) without the idle check.
    public func forceUnload() {
        unloadNow(reason: "forced")
    }

    /// FIX-4: unload on the OS memory-pressure signal — immediately, even if the
    /// idle timer has not expired. reason goes into the log («on memory pressure warning»).
    public func forceUnload(reason: String) {
        unloadNow(reason: reason)
    }

    private func unloadNow(reason: String) {
        guard inner != nil || gemma != nil || worker != nil else { return }
        // FOOTPRINT fix: in subprocess mode unload = kill the child; all CoreML
        // dirt leaves with the process, the daemon footprint does not grow.
        killWorker()
        // Remember the URL BEFORE the reset: after gemma = nil there is no place to get modelURL.
        let coreMLURL = gemma?.modelURL
        inner = nil
        gemma = nil
        loadStart = nil
        // CoreML in this SDK does not hand weights out (no reset(withContentsOf:)),
        // so what remains is releasing the instances + returning the heap below.
        // If footprint is still above the Qwen base after this — something else
        // holds it, see BMEM_UNLOAD_DEBUG below (step-by-step probes).
        if let url = coreMLURL, ProcessInfo.processInfo.environment["BMEM_UNLOAD_DEBUG"] != nil {
            FileHandle.standardError.write(Data(
                String(format: "bmem: unload dbg: released, footprint %.0fMB (url %@)\n",
                       processFootprintMB(), url.lastPathComponent).utf8))
        }
        // The allocator does not return the freed heap (BPE tokenizer dictionaries
        // ~tens of MB) to the OS by itself — madvise(MADV_FREE) over free pages by hand.
        malloc_zone_pressure_relief(nil, 0)
        FileHandle.standardError.write(Data(
            String(format: "bmem: model unloaded %@, footprint %.0fMB\n",
                   reason, processFootprintMB()).utf8))
    }

    nonisolated static func resolveModelDir() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["BMEM_MODEL_DIR"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        let execDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        candidates.append(execDir.appendingPathComponent("models", isDirectory: true))
        candidates.append(execDir.deletingLastPathComponent().appendingPathComponent("models", isDirectory: true))
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("models", isDirectory: true))
        candidates.append(fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/AI-projects/bm-native/models", isDirectory: true))
        candidates.append(fm.homeDirectoryForCurrentUser.appendingPathComponent(".bmem/models", isDirectory: true))
        for c in candidates where fm.fileExists(atPath: c.appendingPathComponent("tokenizer").path) {
            return c
        }
        return nil
    }

    /// EmbeddingGemma-2 CoreML directory: BMEM_GEMMA_MODEL_DIR, otherwise
    /// ~/.bmem/models/embeddinggemma-2-coreml (home honoring HOME from the
    /// environment — stands run with a substituted HOME, as in Config),
    /// otherwise models/ next to the binary. A valid directory = tokenizer.json + embeddings.bf16 +
    /// (EmbeddingGemma2Text.mlmodelc | .mlpackage).
    nonisolated static func resolveGemmaDir() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["BMEM_GEMMA_MODEL_DIR"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        let home = URL(fileURLWithPath: Config.homeDir(), isDirectory: true)
        candidates.append(home.appendingPathComponent(".bmem/models/embeddinggemma-2-coreml", isDirectory: true))
        let execDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for base in [execDir, execDir.deletingLastPathComponent()] {
            candidates.append(base.appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent("embeddinggemma-2-coreml", isDirectory: true))
        }
        // Canonical development location (same trick as resolveModelDir uses for Qwen).
        candidates.append(fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/AI-projects/bm-native/models", isDirectory: true)
            .appendingPathComponent("embeddinggemma-2-coreml", isDirectory: true))
        for c in candidates {
            let hasTokenizer = fm.fileExists(atPath: c.appendingPathComponent("tokenizer.json").path)
            let hasTable = fm.fileExists(atPath: c.appendingPathComponent("embeddings.bf16").path)
            let hasModel = fm.fileExists(atPath: c.appendingPathComponent("EmbeddingGemma2Text.mlmodelc").path)
                || fm.fileExists(atPath: c.appendingPathComponent("EmbeddingGemma2Text.mlpackage").path)
            if hasTokenizer && hasTable && hasModel { return c }
        }
        return nil
    }

    /// model tag of the embed_cache key for the selected backend. The spaces are
    /// DIFFERENT (Gemma 768-dim, Qwen 1024-dim) — the tag separates them into
    /// cache rows (FIX-3); switching backends = full reindex under a new tag,
    /// old rows stay untouched (rollback is cheap).
    nonisolated static func activeModelTag() -> String {
        prefersGemma()
            ? (resolveGemmaDir()?.lastPathComponent ?? "unknown")
            : (resolveModelDir()?.lastPathComponent ?? "unknown")
    }

    func ensureLoaded() async throws {
        if EmbedWorkerLink.enabled() {
            if worker != nil { lastUse = Date(); return }
            try await spawnWorker()
            lastUse = Date()
            return
        }
        if Self.prefersGemma() {
            if gemma != nil { lastUse = Date(); return }
            guard let dir = Self.resolveGemmaDir() else {
                throw NSError(domain: "bmem", code: 1,
                              userInfo: [NSLocalizedDescriptionKey:
                                "EmbeddingGemma-2 bundle not found (set BMEM_GEMMA_MODEL_DIR)"])
            }
            loadStart = Date()
            // ANE: all 3862/3862 ops of the embed_* functions on the Neural Engine
            // (model card); .all also allows GPU copies, CoreML places the graph on ANE.
            let g = try await GemmaCoreMLModel.load(from: dir, computeUnits: .all)
            gemma = g
            lastUse = Date()
            FileHandle.standardError.write(Data("bmem: gemma model loaded in \(String(format: "%.1f", Date().timeIntervalSince(loadStart!)))s, footprint \(String(format: "%.0f", processFootprintMB()))MB\n".utf8))
            return
        }
        guard inner == nil else { return }
        guard let dir = Self.resolveModelDir() else {
            throw NSError(domain: "bmem", code: 1, userInfo: [NSLocalizedDescriptionKey: "model bundle not found (set BMEM_MODEL_DIR)"])
        }
        loadStart = Date()
        let e = try await TextEmbedder(bundleAt: dir, computeUnits: .gpu, prompts: .qwen3Embedding)
        inner = e
        lastUse = Date()
        FileHandle.standardError.write(Data("bmem: model loaded in \(String(format: "%.1f", Date().timeIntervalSince(loadStart!)))s\n".utf8))
    }

    /// The inner TextEmbedder is captured RIGHT AFTER ensureLoaded (before the
    /// await): an actor can reenter during await, and a watchdog unload must not
    /// catch inner == nil mid unfinished embed.
    func embedRaw(_ text: String) async throws -> [Float] {
        if EmbedWorkerLink.enabled() { return try await workerCall(kind: "r", text: text) }
        if let g = try await loadedGemma() { return try await g.embed(text: text, prefix: "") }
        let e = try await loadedEmbedder()
        return try await e.embed(text: text)
    }

    func embedDocument(_ text: String) async throws -> [Float] {
        if EmbedWorkerLink.enabled() { return try await workerCall(kind: "d", text: text) }
        if let g = try await loadedGemma() { return try await g.embed(text: text, prefix: GemmaPrompt.document) }
        let e = try await loadedEmbedder()
        return try await e.embed(document: text)
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        if EmbedWorkerLink.enabled() { return try await workerCall(kind: "q", text: text) }
        if let g = try await loadedGemma() { return try await g.embed(text: text, prefix: GemmaPrompt.searchQuery) }
        let e = try await loadedEmbedder()
        return try await e.embed(query: text)
    }

    /// nil when the backend is Qwen; with gemma — guarantees the model is loaded
    /// and refreshes lastUse (the strong reference returns before the caller awaits).
    private func loadedGemma() async throws -> GemmaCoreMLModel? {
        guard Self.prefersGemma() else { return nil }
        if gemma == nil { try await ensureLoaded() }
        lastUse = Date()
        return gemma!
    }

    private func loadedEmbedder() async throws -> TextEmbedder {
        if inner == nil { try await ensureLoaded() }
        lastUse = Date()
        return inner!
    }
}