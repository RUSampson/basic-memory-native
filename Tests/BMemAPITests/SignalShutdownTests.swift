// SIGTERM to a live daemon with an in-flight
// request = graceful drain + exit 0, not SIGTRAP (earlier regression:
// a MainActor assert in the handler dropped the daemon before the first drain
// line, rc=133; with the 15-second in-flight budget a cold search got rc=52).
//
// Stand — a separate daemon instance on port 18124 (ControlAPITests live on
// 18123, the classes may run in parallel), temporary HOME, real model.
// Request coldness is made deterministic: BMEM_CONTROL_FIFO + "warning"
// (the FIX-4 acceptance path) unloads the model immediately, the next search
// kicks off a reload (60-90 s) — exactly the window SIGTERM lands in.
// The drain budget (BMemTuning.shutdownDrainSeconds = 90 s) must outlive the
// reload: the client gets its response, the daemon exits with 0.
import XCTest
import Darwin
import BMemAPI

private struct SigStandError: Error, CustomStringConvertible {
    let description: String
}

final class SignalShutdownTests: XCTestCase {

    private static let port: UInt16 = 18124

    func testSIGTERMDrainsInflightColdSearch() throws {
        let fm = FileManager.default
        let dir = "/tmp/bmem-sigterm-" + String(UUID().uuidString.prefix(8))
        let vault = dir + "/vault"
        try fm.createDirectory(atPath: vault + "/notes", withIntermediateDirectories: true)
        let evals = dir + "/evals"
        try fm.createDirectory(atPath: evals, withIntermediateDirectories: true)
        let note = "---\ntitle: Espresso machine E61\ntype: note\npermalink: hermes/notes/e61\n---\n"
            + "Espresso machine E61: 58 mm group, Rotex pump, gearbox repair.\n"
        try note.write(toFile: vault + "/notes/e61.md", atomically: true, encoding: .utf8)

        let fifo = dir + "/ctl.fifo"
        guard mkfifo(fifo, 0o600) == 0 else {
            throw SigStandError(description: "mkfifo failed: \(String(cString: strerror(errno)))")
        }

        let exe: String
        if let override = ProcessInfo.processInfo.environment["BMEM_TEST_BINARY"],
           fm.isExecutableFile(atPath: override) {
            exe = override
        } else {
            let repoRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard let found = [".build/debug/bmem", ".build/release/bmem"]
                    .map({ repoRoot.appendingPathComponent($0).path })
                    .first(where: { fm.isExecutableFile(atPath: $0) }) else {
                throw SigStandError(description: "bmem binary not found; run `swift build` first")
            }
            exe = found
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["daemon"]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = dir
        env["BMEM_DB"] = dir + "/bmem.db"
        env["BMEM_SOCKET"] = dir + "/bmem.sock"
        env["BMEM_EMBED_PORT"] = String(Self.port)
        env["BMEM_PROJECT_PATH"] = vault
        env["BMEM_MODEL_IDLE_TIMEOUT"] = "0"   // unload is done only by FIFO-warning
        env["BMEM_EVALS_DIR"] = evals
        env["BMEM_CONTROL_FIFO"] = fifo
        let realHome = env["HOME_REAL"] ?? NSHomeDirectory()
        env["BMEM_GEMMA_MODEL_DIR"] = realHome + "/.bmem/models/embeddinggemma-2-coreml"
        env["BMEM_MODEL_DIR"] = realHome + "/.bmem/models"
        p.environment = env
        FileManager.default.createFile(atPath: dir + "/daemon.log", contents: nil)
        let logFH = FileHandle(forWritingAtPath: dir + "/daemon.log")!
        p.standardOutput = logFH
        p.standardError = logFH
        try p.run()
        addTeardownBlock {
            // On a green run the daemon is already dead (SIGTERM in the test); if the
            // test failed earlier — kill hard so no orphan is left on 18124.
            if p.isRunning { kill(p.processIdentifier, SIGKILL); try? p.waitUntilExit() }
        }

        // 1. Readiness: endpoint alive and initial indexing produced chunks
        //    (model warmed — warm+reindex in the daemon are background tasks).
        let ready = Date().addingTimeInterval(180)
        var warm = false
        while Date() < ready {
            if let (status, json) = try? Self.http("GET", "/v1/status", timeout: 3),
               status == 200,
               let index = json["index"] as? [String: Any],
               let projects = index["projects"] as? [[String: Any]],
               projects.contains(where: { (($0["chunks"] as? Int) ?? 0) > 0 }) {
                warm = true; break
            }
            if !p.isRunning {
                throw SigStandError(description: "daemon exited early; see \(dir)/daemon.log")
            }
            usleep(1_000_000)
        }
        XCTAssertTrue(warm, "stand not warmed up within 180 s")

        // 2. Deterministic model unload: FIFO "warning" (the FIX-4 path).
        //    An O_NONBLOCK open catches "no reader" (ENXIO) if the daemon has not
        //    created the channel yet — no eternal block on write.
        let wfd = open(fifo, O_WRONLY | O_NONBLOCK)
        guard wfd >= 0 else {
            throw SigStandError(description: "fifo open failed: \(String(cString: strerror(errno)))")
        }
        // The daemon reader slices rawValue by bytes before trim — a trailing NUL
        // must not be written («unknown pressure 'warning\0'»).
        let payload = Data("warning\n".utf8)
        _ = payload.withUnsafeBytes { write(wfd, $0.baseAddress, $0.count) }
        close(wfd)
        let unloaded = Date().addingTimeInterval(30)
        var sawUnload = false
        while Date() < unloaded {
            if let (_, json) = try? Self.http("GET", "/v1/status", timeout: 3),
               json["model_loaded"] as? Bool == false {
                sawUnload = true; break
            }
            usleep(500_000)
        }
        XCTAssertTrue(sawUnload, "model did not unload via FIFO-warning within 30 s")

        // 3. The cold search goes to background (reload 60-90 s) and becomes the
        //    in-flight request SIGTERM is aimed at.
        nonisolated(unsafe) var searchResult: Int = -1
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            if let (code, json) = try? Self.http("GET",
                                                 "/v1/search?q=\(Self.urlEncode("espresso machine gearbox"))&limit=3",
                                                 timeout: 240),
               code == 200, (json["results"] as? [Any])?.isEmpty == false {
                searchResult = code
            } else {
                searchResult = -1
            }
            sem.signal()
        }
        usleep(2_000_000)  // request in flight (reload takes tens of seconds)

        // 4. SIGTERM to a live in-flight request.
        kill(p.processIdentifier, SIGTERM)

        // 5. The response must arrive (drain outlived the reload), daemon exits 0.
        XCTAssertEqual(sem.wait(timeout: .now() + 180), .success,
                       "the in-flight search got no response within 180 s (drain dropped it?)")
        XCTAssertEqual(searchResult, 200,
                       "the in-flight cold search did not reach 200 with results")
        let exited = Date().addingTimeInterval(60)
        while p.isRunning && Date() < exited { usleep(250_000) }
        XCTAssertFalse(p.isRunning, "daemon did not exit after drain")
        XCTAssertEqual(p.terminationStatus, 0,
                       "the daemon must exit 0 (the SIGTRAP regression gave rc=133)")

        // 6. Log: drain lines present, no drain timeout.
        let log = (try? String(contentsOfFile: dir + "/daemon.log", encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("daemon shutdown (SIGTERM)"),
                      "no graceful shutdown line in the log")
        XCTAssertTrue(log.contains("draining 1 in-flight"),
                      "drain had to wait for exactly 1 in-flight request")
        XCTAssertFalse(log.contains("drain timeout"),
                       "the drain budget did not outlive the cold reload")
    }

    // MARK: - HTTP helper (the same semaphore pattern as ControlAPITests)

    private static func http(_ method: String, _ path: String,
                             timeout: TimeInterval) throws -> (Int, [String: Any]) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw SigStandError(description: "bad url")
        }
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        nonisolated(unsafe) var out: (Int, [String: Any])?
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            var json: [String: Any] = [:]
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                json = obj
            }
            out = (code, json)
            sem.signal()
        }.resume()
        sem.wait()
        guard let out else { throw SigStandError(description: "no response from \(method) \(path)") }
        return out
    }

    private static func urlEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}
