// FOOTPRINT-FIX2 (REVIEW-1 FAIL-1): a race of concurrent embeds on one
// worker socket. Before, workerCall threw roundtrips into a global concurrent
// queue: two parallel calls on ONE fd mixed sendAll/recvAll bytes, the server
// read desynchronized frames, and a silently-consumed foreign vector settled
// into embed_cache (persistent index pollution).
// The fix is the serial Embedder.workerIO queue. Test: N parallel embedRaw
// with DIFFERENT texts -> each must get the vector derived from ITS OWN text.
// Without serialization it fails almost reliably (server delay widens the race
// window). No live model needed — the fake server speaks the binary protocol
// from the header of EmbedWorker.swift.
import XCTest
@testable import BMemCore
#if canImport(Darwin)
import Darwin
#endif

private extension Embedder {
    /// Test hook: inject a ready client so workerCall does not spawn the real
    /// model. Watchdog desync fix: the client must land on workerIO (ioClient) too —
    /// roundtrips read it there.
    func setWorkerForTests(_ client: EmbedWorkerClient?) {
        worker = client
        workerIO.async { self.ioClient = client }
    }
    /// Test hook: replace child spawning (watchdog desync fix).
    func setSpawnOverrideForTests(_ f: ((String) throws -> EmbedWorkerClient)?) { spawnOverrideForTests = f }
}

/// Deterministic «embedding function» of the fake server: 3 numbers from the text.
private func fakeVector(_ text: String) -> [Float] {
    let b = Array(text.utf8)
    return [Float(b.count), Float(b.first ?? 0), Float(b.last ?? 0)]
}

private func readExact(_ fd: Int32, _ count: Int) -> [UInt8]? {
    var buf = [UInt8](repeating: 0, count: count)
    var got = 0
    while got < count {
        let r = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress!.advanced(by: got), count - got, 0) }
        if r <= 0 { return nil }
        got += r
    }
    return buf
}

/// Thread-safe box for the watchdog desync stand: a queue of dummy processes
/// (the fake server handler takes its process in accept order)
/// and a list of fds for cleanup.
private final class KillWindowBox: @unchecked Sendable {
    let lock = NSLock()
    private var pending: [Process] = []
    private var all: [Process] = []
    var fds: [Int32] = []
    func pushDummy(_ p: Process) { lock.lock(); pending.append(p); all.append(p); lock.unlock() }
    func popDummyWaited() -> Process? {
        for _ in 0..<500 {
            lock.lock(); let d = pending.isEmpty ? nil : pending.removeFirst(); lock.unlock()
            if d != nil { return d }
            usleep(10_000)
        }
        return nil
    }
    var allDummies: [Process] { lock.lock(); defer { lock.unlock() }; return all }
    func pushFd(_ f: Int32) { lock.lock(); fds.append(f); lock.unlock() }
    var allFds: [Int32] { lock.lock(); defer { lock.unlock() }; return fds }
}

private func listenFakeUnix(_ path: String, file: StaticString = #filePath, line: UInt = #line) -> Int32 {
    let lfd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        _ = path.withCString { src in
            memcpy(buf.baseAddress!, src, min(strlen(src), buf.count - 1))
        }
    }
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    XCTAssertEqual(rc, 0, "bind \(path): \(String(cString: strerror(errno)))", file: file, line: line)
    XCTAssertEqual(listen(lfd, 4), 0, file: file, line: line)
    return lfd
}

private func connectFakeUnix(_ path: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        _ = path.withCString { src in
            memcpy(buf.baseAddress!, src, min(strlen(src), buf.count - 1))
        }
    }
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if rc != 0 { close(fd); return -1 }
    return fd
}

private struct TestFailure: Error { let msg: String }

private func makeSleepDummy() throws -> Process {
    let d = Process()
    d.executableURL = URL(fileURLWithPath: "/bin/sleep")
    d.arguments = ["600"]
    try d.run()
    return d
}

final class EmbedWorkerRaceTests: XCTestCase {

    // Watchdog desync repro: a CONCURRENT request in the
    // idle-unload/reload transition window. At night 02:03/04:03 the watchdog
    // killed the worker with an in-flight embed; the old code closed the fd from
    // the actor and killed "its" Process without checking the worker is still
    // ours: the second request arriving in the terminate/reload window either
    // read remnants of a desynchronized stream (Code=9 bad count) or knocked
    // down the already-fresh worker with its own killWorker — and the first
    // request died with 500. Requirement: a request in the transition window is queued until the worker is ready, not 500.
    func testConcurrentRequestDuringIdleKillSurvives() async throws {
        setenv("BMEM_EMBED_SUBPROCESS", "1", 1)
        // The fake servers send into a socket the client already closed (in
        // production the daemon starts with SIGPIPE=SIG_IGN — main.swift FIX2; the test does the same).
        signal(SIGPIPE, SIG_IGN)
        let uid = String(UUID().uuidString.prefix(8))
        let pathA = "/tmp/bmem-killA-\(uid).sock"   // the «dying» worker
        let pathB = "/tmp/bmem-killB-\(uid).sock"   // the «healthy» worker of the (re)spawn
        defer { unlink(pathA); unlink(pathB) }
        let lA = listenFakeUnix(pathA)
        let lB = listenFakeUnix(pathB)
        defer { close(lA); close(lB) }

        let gotRequest = DispatchSemaphore(value: 0)
        // S1: a slow child: read the request, after a second sent the
        // count=3 header and a TRUNCATED body (4 of 12 bytes), then closed —
        // death mid-reply (the «read failed» signature + garbage in the stream).
        let s1 = Thread {
            let sfd = accept(lA, nil, nil)
            guard sfd >= 0 else { return }
            defer { close(sfd) }
            guard let kind = readExact(sfd, 1)?.first, kind == UInt8(ascii: "r"),
                  let lenB = readExact(sfd, 4) else { return }
            let n = Int(UInt32(lenB[0]) | UInt32(lenB[1]) << 8
                | UInt32(lenB[2]) << 16 | UInt32(lenB[3]) << 24)
            guard readExact(sfd, n) != nil else { return }
            gotRequest.signal()
            usleep(1_000_000)  // the window the watchdog-unload arrives in
            var reply = Data()
            EmbedWorkerServer.appendReplyHeader(into: &reply, count: 3, seq: 0)
            reply.append(contentsOf: [0x00, 0x00, 0x80, 0x3F])  // float 1.0, body truncated
            _ = reply.withUnsafeBytes { send(sfd, $0.baseAddress, $0.count, 0) }
        }
        s1.start()

        // S2: a healthy worker; the connection lives while the client dummy process
        // lives (terminate in killWorker = child death = socket close).
        let box = KillWindowBox()
        let s2 = Thread {
            while true {
                let sfd = accept(lB, nil, nil)
                if sfd < 0 { break }
                let dummy = box.popDummyWaited()
                var alive = true
                var seq: UInt16 = 0
                while alive {
                    var pfd = pollfd(fd: sfd, events: Int16(POLLIN), revents: 0)
                    let r = poll(&pfd, 1, 100)
                    if r == 0 {
                        if let d = dummy, !d.isRunning { alive = false; break }
                        continue
                    }
                    guard let kind = readExact(sfd, 1)?.first, kind == UInt8(ascii: "r"),
                          let lenB = readExact(sfd, 4) else { break }
                    let n = Int(UInt32(lenB[0]) | UInt32(lenB[1]) << 8
                        | UInt32(lenB[2]) << 16 | UInt32(lenB[3]) << 24)
                    guard let textB = readExact(sfd, n) else { break }
                    // «computation» 150 ms checking whether the child died
                    var aborted = false
                    for _ in 0..<15 {
                        usleep(10_000)
                        if let d = dummy, !d.isRunning { aborted = true; break }
                    }
                    if aborted { break }  // death during computation — no reply
                    var vec = fakeVector(String(decoding: textB, as: UTF8.self))
                    var reply = Data()
                    EmbedWorkerServer.appendReplyHeader(into: &reply, count: UInt32(vec.count), seq: seq)
                    seq &+= 1
                    reply.append(Data(bytes: &vec, count: vec.count * MemoryLayout<Float>.size))
                    var sent = 0
                    let ok = reply.withUnsafeBytes { raw -> Bool in
                        while sent < raw.count {
                            let w = send(sfd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                            if w <= 0 { return false }
                            sent += w
                        }
                        return true
                    }
                    if !ok { break }
                }
                close(sfd)
            }
        }
        s2.start()

        let dummy1 = try makeSleepDummy()
        defer { if dummy1.isRunning { dummy1.terminate() } }
        let c1 = connectFakeUnix(pathA)
        XCTAssertGreaterThanOrEqual(c1, 0)

        let embedder = Embedder()
        await embedder.setWorkerForTests(EmbedWorkerClient(process: dummy1, path: pathA, fd: c1))
        await embedder.setSpawnOverrideForTests { path in
            let d = try makeSleepDummy()
            box.pushDummy(d)
            let fd = connectFakeUnix(pathB)
            guard fd >= 0 else {
                d.terminate()
                throw NSError(domain: "test", code: 99, userInfo: nil)
            }
            box.pushFd(fd)
            return EmbedWorkerClient(process: d, path: path, fd: fd)
        }

        // A — in-flight embed; B — a concurrent request exactly in the transition
        // window; then a watchdog-like idle-unload (night scenario 02:03).
        let a = Task<Result<[Float], TestFailure>, Never> {
            do { return .success(try await embedder.embedRaw("A-request")) }
            catch { return .failure(TestFailure(msg: String(describing: error))) }
        }
        XCTAssertEqual(gotRequest.wait(timeout: .now() + 10), .success, "S1 did not read request A")
        let b = Task<Result<[Float], TestFailure>, Never> {
            do { return .success(try await embedder.embedRaw("B-request")) }
            catch { return .failure(TestFailure(msg: String(describing: error))) }
        }
        try? await Task.sleep(for: .milliseconds(50))
        await embedder.forceUnload()  // idle-watchdog simulation inside the in-flight window

        let ra = await a.value
        let rb = await b.value
        XCTAssertNoThrow(try ra.get(), "a request in the kill/reload window must queue, not 500")
        XCTAssertNoThrow(try rb.get(), "the second transition-window request must await a fresh worker")
        if case .success(let va) = ra { XCTAssertEqual(va, fakeVector("A-request")) }
        if case .success(let vb) = rb { XCTAssertEqual(vb, fakeVector("B-request")) }

        await embedder.setSpawnOverrideForTests(nil)
        await embedder.setWorkerForTests(nil)
        close(c1)
        for fd in box.allFds { close(fd) }
        for d in box.allDummies where d.isRunning { d.terminate() }
        // S2 is an endless accept loop: it exits via closing the listen fd (defer).
    }

    // Watchdog desync fix spec items 3/4: a stream desync (foreign vector remnants in the
    // length header) is caught IN PLACE as ProtocolError Code=10 instead of
    // growing into «bad count» one frame later; diagnostics with the worker pid
    // and header bytes are printed to stderr (daemon.log).
    func testDesyncHeaderCaughtAsProtocolErrorWithDiagnostics() async throws {
        setenv("BMEM_EMBED_SUBPROCESS", "1", 1)
        signal(SIGPIPE, SIG_IGN)
        let uid = String(UUID().uuidString.prefix(8))
        let path = "/tmp/bmem-desync-\(uid).sock"
        defer { unlink(path) }
        let lfd = listenFakeUnix(path)
        defer { close(lfd) }

        // A malicious server: for every request it sends 8 bytes of garbage
        // (a float vector instead of the v2 header) and closes the connection.
        let s = Thread {
            while true {
                let sfd = accept(lfd, nil, nil)
                if sfd < 0 { break }
                if readExact(sfd, 1) != nil, let lenB = readExact(sfd, 4) {
                    let n = Int(UInt32(lenB[0]) | UInt32(lenB[1]) << 8
                        | UInt32(lenB[2]) << 16 | UInt32(lenB[3]) << 24)
                    _ = readExact(sfd, n)
                }
                let junk: [UInt8] = [0x77, 0xbe, 0x4e, 0x5e, 0x00, 0x00, 0x80, 0x3f]
                _ = junk.withUnsafeBytes { send(sfd, $0.baseAddress, $0.count, 0) }
                close(sfd)
            }
        }
        s.start()

        // Diagnostics go to stderr (daemon.log in the daemon) — capture them.
        let diagPath = "/tmp/bmem-desync-diag-\(uid).log"
        let dfd = open(diagPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        XCTAssertGreaterThanOrEqual(dfd, 0)
        let savedErr = dup(STDERR_FILENO)
        dup2(dfd, STDERR_FILENO)

        let box = KillWindowBox()
        let embedder = Embedder()
        await embedder.setSpawnOverrideForTests { p in
            let d = try makeSleepDummy()
            box.pushDummy(d)
            let fd = connectFakeUnix(path)
            guard fd >= 0 else {
                d.terminate()
                throw NSError(domain: "test", code: 99, userInfo: nil)
            }
            box.pushFd(fd)
            return EmbedWorkerClient(process: d, path: p, fd: fd)
        }
        var errDesc = ""
        do {
            _ = try await embedder.embedRaw("desync-probe")
        } catch {
            errDesc = String(describing: error)
        }
        await embedder.setSpawnOverrideForTests(nil)

        dup2(savedErr, STDERR_FILENO)
        close(savedErr)
        close(dfd)
        let diag = (try? Data(contentsOf: URL(fileURLWithPath: diagPath))).flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
        unlink(diagPath)
        for fd in box.allFds { close(fd) }
        for d in box.allDummies where d.isRunning { d.terminate() }

        XCTAssertTrue(errDesc.contains("Code=10") || errDesc.contains("protocol desync"),
                      "expected ProtocolError (Code=10), got: \(errDesc)")
        XCTAssertFalse(errDesc.contains("bad count"),
                       "desync must not grow into «bad count»: \(errDesc)")
        XCTAssertTrue(diag.contains("protocol desync"),
                      "daemon.log must print desync diagnostics, stderr was: \(diag)")
        XCTAssertTrue(diag.contains("pid="),
                      "diagnostics must contain the worker pid: \(diag)")
        XCTAssertTrue(diag.contains("77 be 4e 5e"),
                      "diagnostics must contain the header bytes: \(diag)")
    }

    func testConcurrentEmbedsGetOwnVectors() async throws {
        // Force the worker path regardless of the stands config/environment.
        setenv("BMEM_EMBED_SUBPROCESS", "1", 1)
        let sockPath = "/tmp/bmem-race-\(String(UUID().uuidString.prefix(8))).sock"
        defer { unlink(sockPath) }

        // --- fake embed-worker: one accept, sequential roundtrips.
        let lfd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(lfd, 0)
        defer { close(lfd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            _ = sockPath.withCString { src in
                memcpy(buf.baseAddress!, src, min(strlen(src), buf.count - 1))
            }
        }
        let bindRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bindRC, 0, "bind failed: \(String(cString: strerror(errno)))")
        XCTAssertEqual(listen(lfd, 4), 0)

        // --- client connection (one fd, as in the daemon).
        let cfd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(cfd, 0)
        let connectRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(cfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connectRC, 0)

        let serverDone = DispatchSemaphore(value: 0)
        let server = Thread {
            defer { serverDone.signal() }
            let sfd = accept(lfd, nil, nil)
            guard sfd >= 0 else { return }
            defer { close(sfd) }
            var seq: UInt16 = 0
            while true {
                guard let kind = readExact(sfd, 1)?.first, kind == UInt8(ascii: "r") else { break }
                guard let lenB = readExact(sfd, 4) else { break }
                let n = Int(UInt32(lenB[0]) | UInt32(lenB[1]) << 8
                    | UInt32(lenB[2]) << 16 | UInt32(lenB[3]) << 24)
                guard n >= 0, let textB = readExact(sfd, n) else { break }
                usleep(30_000)  // widen the race window for the non-serial variant
                var vec = fakeVector(String(decoding: textB, as: UTF8.self))
                var reply = Data()
                EmbedWorkerServer.appendReplyHeader(into: &reply, count: UInt32(vec.count), seq: seq)
                seq &+= 1
                reply.append(Data(bytes: &vec, count: vec.count * MemoryLayout<Float>.size))
                var sent = 0
                let ok = reply.withUnsafeBytes { raw -> Bool in
                    while sent < raw.count {
                        let w = send(sfd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                        if w <= 0 { return false }
                        sent += w
                    }
                    return true
                }
                if !ok { break }
            }
        }
        server.start()

        // A dead «stub process» instead of the real model (only needed for
        // terminate in killWorker).
        let dummy = Process()
        dummy.executableURL = URL(fileURLWithPath: "/bin/sleep")
        dummy.arguments = ["600"]
        try dummy.run()
        defer { if dummy.isRunning { dummy.terminate() } }

        let embedder = Embedder()
        await embedder.setWorkerForTests(EmbedWorkerClient(process: dummy, path: sockPath, fd: cfd))

        let texts = [
            "alpha one two three",
            "beta",
            "gamma long text with tail Z",
            "x",
            "delta-four-five-six-seven",
            "q",
            "epsilon text of a quite different length!!",
            "z",
        ]

        var results: [(String, [Float])] = []
        await withTaskGroup(of: (String, [Float]).self) { group in
            for t in texts {
                group.addTask {
                    do { return (t, try await embedder.embedRaw(t)) }
                    catch { return (t, []) }
                }
            }
            for await r in group { results.append(r) }
        }

        XCTAssertEqual(results.count, texts.count)
        for (text, vec) in results {
            XCTAssertEqual(vec, fakeVector(text),
                           "embed(\"\(text)\") returned a foreign/broken vector — race on the worker socket")
        }

        // The server finishes when the client closes the fd (wait outside the
        // async context: DispatchSemaphore.wait is unavailable in async).
        await embedder.setWorkerForTests(nil)
        close(cfd)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = serverDone.wait(timeout: .now() + 5)
                c.resume()
            }
        }
    }
}
