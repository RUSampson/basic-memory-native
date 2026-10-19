// FOOTPRINT fix (16.10): the CoreML EmbeddingGemma engine lives in a CHILD
// process, not in the daemon.
//
// Why: after the very first prediction CoreML dirties the process-wide
// malloc heap by ~150-200 MB (weight/ANE-plan loading); releasing the MLModel
// frees those pages, but they are interleaved with live daemon objects, the
// allocator cannot return them to the OS (79% fragmentation per vmmap), and
// phys_footprint after idle-unload stayed at 387 MB vs 164 MB of the Qwen base
// — the only failed gate of the EMB-REDONE acceptance. There is no public API
// to reset the prediction cache in the macOS 27 SDK (MLModel has no
// reset(withContentsOf:)). In a child process all that dirt leaves with the
// process: idle-unload = terminate, the daemon footprint stays at baseline.
//
// Protocol (binary, no JSON — JSONSerialization boxing a 768 NSNumber reply
// per response fragmented the DAEMON heap by another ~150 MB on a stand with
// a full warm reindex (~1.8k embeds)):
//   request: [u8 kind: 'd'|'q'|'r'][u32 LE text length][UTF-8 text]
//   reply:   [u16 magic 0xB5E4][u16 seq][u32 LE count][count x f32 LE]
//            count == 0xFFFFFFF0 -> error: [u16 LE length][UTF-8 message]
// v2 (watchdog desync fix): magic+seq in the reply header. Night transient
// (Code=8 -> Code=9 «bad count 3168106786»): after the child died mid-reply
// the connection was reused desynchronized — float-vector remnants slid into
// the length header of the next roundtrip. magic/seq catch the desync in place
// as ProtocolError (Code=10) instead of «bad count» one frame later.
// seq is the reply counter on this connection, starts at 0 on each accept.
// The socket is created AFTER the model loads — connect-ready = model in memory
// (the «model loaded in X s» line is printed by the child to inherited stderr,
// the harness stand regexes still see it as before).
//
// Child insurance: SIGTERM = instant exit; parent died (getppid==1) = exit;
// idling longer than BMEM_MODEL_IDLE_TIMEOUT*2 = exit.
import Foundation
import BMemAPI
#if canImport(Darwin)
import Darwin
#endif

private func childPhysFootprintMB(pid: pid_t) -> Double {
    // phys_footprint of another process without a task port: proc_pid_rusage(RUSAGE_INFO_V4).
    var info = rusage_info_v4()
    let kr: Int32 = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
            proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
        }
    }
    guard kr == 0 else { return 0 }
    return Double(info.ri_phys_footprint) / (1024 * 1024)
}

// MARK: - Shared decisions (both sides)

public enum EmbedWorkerLink {
    /// Watchdog desync fix: reply header magic (protocol v2). Needed so a byte-stream
    /// desync (foreign vector remnants in the length header) is caught in place
    /// as ProtocolError instead of growing into «bad count» one frame later.
    public static let frameMagic: UInt16 = 0xB5E4

    /// Mode flag. Default: on for Gemma (it has CoreML fragmentation),
    /// off for Qwen (the CoreAIKit path is battle-tested, must not be touched
    /// without need). BMEM_EMBED_SUBPROCESS=0|1 overrides.
    public static func enabled() -> Bool {
        if let v = ProcessInfo.processInfo.environment["BMEM_EMBED_SUBPROCESS"] {
            return v != "0"
        }
        return Embedder.prefersGemma()
    }

    /// Socket-path base: next to the daemon socket (short on stands),
    /// otherwise ~/.bmem. The concrete path is suffixed with the pid — two
    /// processes sharing BMEM_SOCKET (daemon + CLI index) do not conflict.
    /// FOOTPRINT-FIX2: sun_path in sockaddr_un is 104 bytes. On stands with a
    /// long BMEM_SOCKET the path overflowed (the 17.10 stand hit 115>104): bind
    /// silently worked with a TRUNCATED name, unlink of the full path missed the
    /// file, and respawning the child after idle-unload died with EADDRINUSE
    /// (model lost for the rest of the daemon life). If the full path does not
    /// fit — the leaf is shortened, the directory is kept (per-directory stand isolation stays), the pid too.
    public static func socketPath() -> String {
        let base = ProcessInfo.processInfo.environment["BMEM_SOCKET"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? (Config.homeDir() as NSString).appendingPathComponent(".bmem/bmem.sock")
        let full = base + ".\(getpid()).embed.sock"
        // 103 = 104 minus the terminating NUL.
        if full.utf8.count <= 103 { return full }
        return (base as NSString).deletingLastPathComponent + "/bmem-e\(getpid()).sock"
    }
}

// MARK: - Server (child process: `bmem embed-worker <sock>`)

public enum EmbedWorkerServer {
    /// Blocking serve until SIGTERM/parent death. Never returns.
    public static func run(socketPath: String) -> Never {
        signal(SIGTERM) { _ in _exit(0) }
        // SIGPIPE ignore is not set here: it is set in main.swift BEFORE mode
        // dispatch and is inherited by this exec (FIX2; exactly one occurrence
        // of SIG_...IGN in Sources/ — an acceptance check).
        let embedder = Embedder()
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var loadError: String?
        Task {
            do { try await embedder.ensureLoaded() } catch { loadError = "\(error)" }
            sem.signal()
        }
        sem.wait()
        if let loadError {
            FileHandle.standardError.write(Data("bmem: embed-worker load failed: \(loadError)\n".utf8))
            _exit(2)
        }
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            _ = socketPath.withCString { src in
                memcpy(buf.baseAddress!, src, min(strlen(src), buf.count - 1))
            }
        }
        let bindAddr = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bindAddr == 0, listen(fd, 4) == 0 else {
            FileHandle.standardError.write(Data("bmem: embed-worker bind/listen failed for \(socketPath)\n".utf8))
            _exit(3)
        }
        // 0/negative timeout = «never unload» (daemon FIX-2 semantics) — the
        // child then never commits suicide on idling at all.
        let idleCfg = Double(ProcessInfo.processInfo.environment["BMEM_MODEL_IDLE_TIMEOUT"]
                             ?? String(BMemTuning.modelIdleTimeoutSeconds))
            ?? Double(BMemTuning.modelIdleTimeoutSeconds)
        let idleLimit = idleCfg > 0 ? idleCfg * 2 : Double.infinity
        var lastActivity = Date()
        while true {
            // poll with timeout: on an idle socket check whether the parent is alive.
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&pfd, 1, 10_000)
            if getppid() == 1 { _exit(0) }
            if Date().timeIntervalSince(lastActivity) > idleLimit { _exit(0) }
            guard r > 0 else { continue }
            let cfd = accept(fd, nil, nil)
            guard cfd >= 0 else { continue }
            defer { close(cfd) }
            var seq: UInt16 = 0  // reply counter on this connection (v2)
            while true {
                guard let kind = readExact(cfd, 1)?.first else { break }
                guard let lenBytes = readExact(cfd, 4) else { break }
                let textLen = Int(UInt32(lenBytes[0]) | UInt32(lenBytes[1]) << 8
                    | UInt32(lenBytes[2]) << 16 | UInt32(lenBytes[3]) << 24)
                guard textLen >= 0, textLen <= 8_388_608, let textBytes = readExact(cfd, textLen)
                else { break }
                lastActivity = Date()
                let text = String(decoding: textBytes, as: UTF8.self)
                nonisolated(unsafe) var reply = Data()
                let seqAtRequest = seq  // let snapshot: the Task (non-Sendable capture) must not touch the live counter
                let sem = DispatchSemaphore(value: 0)
                Task {
                    do {
                        let v: [Float]
                        switch kind {
                        case UInt8(ascii: "d"): v = try await embedder.embedDocument(text)
                        case UInt8(ascii: "q"): v = try await embedder.embedQuery(text)
                        default: v = try await embedder.embedRaw(text)
                        }
                        Self.appendReplyHeader(into: &reply, count: UInt32(v.count), seq: seqAtRequest)
                        v.withUnsafeBytes { reply.append(contentsOf: $0) }  // f32 LE (arm64 is natively LE)
                    } catch {
                        Self.appendReplyHeader(into: &reply, count: 0xFFFF_FFF0, seq: seqAtRequest)
                        let msg = Array("\(error)".utf8.prefix(2000))
                        var l = UInt16(msg.count).littleEndian
                        reply.append(Data(bytes: &l, count: 2))
                        reply.append(contentsOf: msg)
                    }
                    sem.signal()
                }
                sem.wait()
                seq &+= 1
                var sent = 0
                reply.withUnsafeBytes { raw in
                    while sent < reply.count {
                        let w = send(cfd, raw.baseAddress!.advanced(by: sent), reply.count - sent, 0)
                        if w <= 0 { return }
                        sent += w
                    }
                }
            }
        }
        _exit(0)
    }

    /// Reply header v2: [u16 magic][u16 seq][u32 LE count].
    static func appendReplyHeader(into reply: inout Data, count: UInt32, seq: UInt16) {
        var magic = EmbedWorkerLink.frameMagic.littleEndian
        var seqLE = seq.littleEndian
        var c = count.littleEndian
        reply.append(Data(bytes: &magic, count: 2))
        reply.append(Data(bytes: &seqLE, count: 2))
        reply.append(Data(bytes: &c, count: 4))
    }

    private static func readExact(_ fd: Int32, _ count: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let r = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress!.advanced(by: got), count - got, 0) }
            if r <= 0 { return nil }
            got += r
        }
        return buf
    }
}

// MARK: - Client (daemon side)

/// One live child: process + socket connection. I/O is blocking, but always
/// from background GCD threads (the actor is never blocked). All fields are
/// immutable — @unchecked Sendable because of Process (formally non-Sendable,
/// used only for terminate/waitUntilExit).
final class EmbedWorkerClient: @unchecked Sendable {
    let process: Process
    let path: String
    let fd: Int32
    /// Watchdog desync fix: marked killed (killWorker). Set synchronously in the actor,
    /// read on workerIO before a roundtrip: a dead fd is not touched at all —
    /// its number may already have been reused by socket() of a new spawn.
    nonisolated(unsafe) var dead = false
    /// Expected seq of the next reply on this connection (protocol v2).
    /// Touched only from workerIO (serial) — no race.
    nonisolated(unsafe) var nextSeq: UInt16 = 0
    init(process: Process, path: String, fd: Int32) {
        self.process = process
        self.path = path
        self.fd = fd
    }
}

extension Embedder {
    /// Spawn `bmem embed-worker`: the child loads the model BEFORE bind/listen,
    /// so a successful connect == «model ready». Wait up to 240 s (first ANE
    /// compilation on a fresh machine takes minutes).
    func spawnWorker() async throws {
        // A race of two loaders (warm + first embed) would otherwise start two
        // children and unlink would steal the first socket: the second spawn waits.
        while spawnInProgress { try await Task.sleep(for: .milliseconds(200)) }
        if worker != nil { return }
        spawnInProgress = true
        defer { spawnInProgress = false }
        let path = EmbedWorkerLink.socketPath()
        if let override = spawnOverrideForTests {
            // Test hook (watchdog desync fix): a live client from a fake server.
            let c = try override(path)
            workerIO.async { self.ioClient = c }
            worker = c
            return
        }
        unlink(path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        p.arguments = ["embed-worker", path]
        var env = ProcessInfo.processInfo.environment
        env["BMEM_EMBED_SUBPROCESS"] = "0"  // the child loads the model in itself
        p.environment = env
        p.standardOutput = FileHandle.standardOutput
        p.standardError = FileHandle.standardError
        try p.run()
        // Watchdog desync fix: socket()/connect() run on the workerIO queue. The fd number
        // socket() returns must not be «ambushed» by a deferred close() of a
        // killed worker (otherwise close catches up with an already-fresh socket).
        // The loop blocks the queue for the child readiness time — parallel
        // roundtrips have nowhere to go before ioClient appears anyway.
        let client: EmbedWorkerClient = try await withCheckedThrowingContinuation { cont in
            workerIO.async {
                let deadline = Date().addingTimeInterval(240)
                var fd: Int32 = -1
                while Date() < deadline {
                    if !p.isRunning {
                        cont.resume(throwing: NSError(domain: "bmem", code: 4, userInfo: [NSLocalizedDescriptionKey:
                            "embed-worker exited (status \(p.terminationStatus)) before ready"]))
                        return
                    }
                    fd = socket(AF_UNIX, SOCK_STREAM, 0)
                    var addr = sockaddr_un()
                    addr.sun_family = sa_family_t(AF_UNIX)
                    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                        _ = path.withCString { src in
                            memcpy(buf.baseAddress!, src, min(strlen(src), buf.count - 1))
                        }
                    }
                    let ok = withUnsafePointer(to: &addr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                    }
                    if ok == 0 { break }
                    close(fd)
                    fd = -1
                    usleep(300_000)
                }
                guard fd >= 0 else {
                    p.terminate()
                    cont.resume(throwing: NSError(domain: "bmem", code: 5, userInfo: [NSLocalizedDescriptionKey:
                        "embed-worker did not become ready in 240s"]))
                    return
                }
                let c = EmbedWorkerClient(process: p, path: path, fd: fd)
                self.ioClient = c
                cont.resume(returning: c)
            }
        }
        worker = client
    }

    /// One embed through the child. A request arriving in the terminate/reload
    /// transition window (watchdog desync fix) is queued: up to 3 attempts with worker
    /// rebuilds between them, instead of returning 500 after the first read error.
    func workerCall(kind: String, text: String) async throws -> [Float] {
        var lastError: Error = NSError(domain: "bmem", code: 6,
                                       userInfo: [NSLocalizedDescriptionKey: "embed worker: no attempt"])
        // Watchdog desync fix: an incoming request takes the worker off the idle watchdog
        // cross IMMEDIATELY. Before, lastUse was refreshed only after success, and
        // the watchdog (10 s tick) managed to kill the child mid-first-embed after
        // a long idle — the night signature 02:03/04:03.
        lastUse = Date()
        for attempt in 0..<3 {
            if worker == nil { try await spawnWorker() }
            guard let client = worker else { continue }
            do {
                let v: [Float] = try await withCheckedThrowingContinuation { cont in
                    // SERIAL workerIO (FIX2): roundtrips on one fd must not mix
                    // bytes — on a global concurrent queue two parallel embeds
                    // would read each other replies.
                    workerIO.async {
                        // Watchdog desync fix: a client marked dead is not touched — its fd
                        // may already be closed (number reused). The request is
                        // queued for a fresh worker (Code=12).
                        if client.dead {
                            cont.resume(throwing: NSError(domain: "bmem", code: 12,
                                userInfo: [NSLocalizedDescriptionKey: "embed worker recycled, request requeued"]))
                            return
                        }
                        do { cont.resume(returning: try Self.workerRoundTrip(client, kind: kind, text: text)) }
                        catch { cont.resume(throwing: error) }
                    }
                }
                lastUse = Date()
                return v
            } catch let error as NSError where error.domain == "bmem" && error.code == 11 {
                throw error  // the model answered with an error — connection is clean, no rebuild needed
            } catch {
                lastError = error
                if attempt == 2 { break }
                killWorker(expected: client)  // force-drop the connection and reconnect
            }
        }
        throw lastError
    }

    /// Diagnostic line into daemon.log (daemon stderr). Watchdog desync fix: with
    /// Code=7/8/9/10 in production there was silence — now we always write the
    /// worker pid and the byte state of the header that reveals stream desync.
    private static func workerLog(_ msg: String, client: EmbedWorkerClient? = nil, header: [UInt8]? = nil) {
        var line = "bmem: embed worker " + msg
        if let client { line += " (pid=\(client.process.processIdentifier) fd=\(client.fd))" }
        if let header { line += " header=[" + header.map { String(format: "%02x", $0) }.joined(separator: " ") + "]" }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private static func workerRoundTrip(_ client: EmbedWorkerClient, kind: String, text: String) throws -> [Float] {
        // Binary frame v2 (see file header): [u8 kind][u32 LE len][text] ->
        // [u16 magic][u16 seq][u32 LE count][f32 x count]; not a single
        // JSON/NSNumber — the daemon heap does not fragment on every embed.
        var req = Data([UInt8(kind.utf8.first ?? UInt8(ascii: "r"))])
        var len = UInt32(text.utf8.count).littleEndian
        req.append(Data(bytes: &len, count: 4))
        req.append(contentsOf: text.utf8)
        if !sendAll(client.fd, req) {
            workerLog("write failed", client: client)
            throw NSError(domain: "bmem", code: 7, userInfo: [NSLocalizedDescriptionKey: "embed worker write failed"])
        }
        var header = [UInt8](repeating: 0, count: 8)
        let got = recvAll(client.fd, &header, 8)
        if got != 8 {
            workerLog("read failed: got \(got)/8 header bytes", client: client, header: Array(header.prefix(got)))
            throw NSError(domain: "bmem", code: 8, userInfo: [NSLocalizedDescriptionKey: "embed worker read failed"])
        }
        let magic = UInt16(header[0]) | UInt16(header[1]) << 8
        let seq = UInt16(header[2]) | UInt16(header[3]) << 8
        let count = UInt32(header[4]) | UInt32(header[5]) << 8 | UInt32(header[6]) << 16 | UInt32(header[7]) << 24
        guard magic == EmbedWorkerLink.frameMagic else {
            workerLog("protocol desync: bad magic \(String(format: "0x%04x", magic))", client: client, header: header)
            throw NSError(domain: "bmem", code: 10, userInfo: [NSLocalizedDescriptionKey:
                "embed worker protocol desync (magic \(String(format: "0x%04x", magic)))"])
        }
        guard seq == client.nextSeq else {
            workerLog("protocol desync: seq \(seq) != expected \(client.nextSeq)", client: client, header: header)
            throw NSError(domain: "bmem", code: 10, userInfo: [NSLocalizedDescriptionKey:
                "embed worker protocol desync (seq \(seq) != \(client.nextSeq))"])
        }
        client.nextSeq &+= 1
        if count == 0xFFFF_FFF0 {
            var lbuf = [UInt8](repeating: 0, count: 2)
            guard recvAll(client.fd, &lbuf, 2) == 2 else {
                workerLog("read failed on error-message length", client: client, header: header)
                throw NSError(domain: "bmem", code: 8, userInfo: [NSLocalizedDescriptionKey: "embed worker read failed"])
            }
            let l = Int(lbuf[0]) | Int(lbuf[1]) << 8
            var msg = [UInt8](repeating: 0, count: l)
            _ = recvAll(client.fd, &msg, l)
            throw NSError(domain: "bmem", code: 11, userInfo: [NSLocalizedDescriptionKey:
                "embed worker: \(String(decoding: msg, as: UTF8.self))"])
        }
        guard count <= 4096 else {
            workerLog("bad count \(count)", client: client, header: header)
            throw NSError(domain: "bmem", code: 9, userInfo: [NSLocalizedDescriptionKey: "embed worker bad count \(count)"])
        }
        var buf = [UInt8](repeating: 0, count: Int(count) * 4)
        guard recvAll(client.fd, &buf, buf.count) == buf.count else {
            workerLog("short read of vector body (count=\(count))", client: client, header: header)
            throw NSError(domain: "bmem", code: 8, userInfo: [NSLocalizedDescriptionKey: "embed worker short read"])
        }
        return buf.withUnsafeBytes { raw in
            Array(UnsafeBufferPointer(start: raw.bindMemory(to: Float.self).baseAddress!, count: Int(count)))
        }
    }

    private static func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        var ok = true
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < data.count {
                let w = send(fd, raw.baseAddress!.advanced(by: sent), data.count - sent, 0)
                if w <= 0 { ok = false; return }
                sent += w
            }
        }
        return ok
    }

    private static func recvAll(_ fd: Int32, _ buf: UnsafeMutablePointer<UInt8>, _ count: Int) -> Int {
        var got = 0
        while got < count {
            let r = recv(fd, buf.advanced(by: got), count - got, 0)
            if r <= 0 { return got }
            got += r
        }
        return got
    }

    /// Drop the worker. Watchdog desync fix:
    /// * `expected` — kill only if the current worker is still this client.
    ///   Without the check, a request that lost the race knocked down the
    ///   winner already-fresh worker with its own killWorker (Code=7/8 ping-pong from the night log).
    /// * close(fd) — strictly via workerIO: close() from an actor thread while
    ///   a blocking recvAll runs on the worker thread is UB (the fd number is
    ///   grabbed by socket() of a new spawn, the «dead» recv eats bytes of the
    ///   new socket -> night Code=9). terminate() already closes the socket on
    ///   the child side: the in-flight roundtrip gets EOF and finishes itself,
    ///   close catches up with it in the queue.
    /// * unlink of the path — only if no new child has taken it already
    ///   (generation unchanged), otherwise the fresh worker socket is eaten.
    func killWorker(expected: EmbedWorkerClient? = nil) {
        guard let w = worker else { return }
        if let expected, w !== expected { return }
        worker = nil
        generation &+= 1
        let gen = generation
        w.dead = true
        if w.process.isRunning { w.process.terminate() }
        workerIO.async {
            if self.ioClient === w { self.ioClient = nil }
            close(w.fd)
        }
        // reap without blocking the actor.
        DispatchQueue.global().async {
            w.process.waitUntilExit()
            Task { [weak self] in
                guard let self else { return }
                if await self.generation == gen { unlink(w.path) }
            }
        }
    }

    /// phys_footprint of the live child (MB), 0 if there is no child. Needed so
    /// FIX-5 (BMEM_MEM_LIMIT_MB threshold) and FIX-4 (shed) measure the PRODUCT
    /// MEMORY (daemon + engine), not just the daemon after the FOOTPRINT fix.
    func workerFootprintMB() -> Double {
        guard let w = worker, w.process.isRunning else { return 0 }
        return childPhysFootprintMB(pid: w.process.processIdentifier)
    }
}
