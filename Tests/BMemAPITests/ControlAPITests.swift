// UI-1: daemon control API tests (status/config/search/benchmark/rollback).
//
// Stand per the card rule: a SEPARATE daemon instance on port 18123 with a
// temporary HOME, temporary DB and temporary note vault — the production
// ~/.local/bin/bmem and the live daemon :8123 are not touched at all.
//
// The model is the real one (Gemma CoreML, dir from the real home via
// BMEM_GEMMA_MODEL_DIR): search does not exist without it, and stubbing it
// in an integration test means not testing search.
import XCTest
@testable import BMemCore
import BMemAPI

/// Stand setup failure message (XCTestError has no message-carrying codes).
private struct StandError: Error, CustomStringConvertible {
    let description: String
}

final class ControlAPITests: XCTestCase {

    // MARK: - Stand

    // nonisolated(unsafe): XCTestCase.setUp/tearDown run once and before the
    // tests; this class runs its tests sequentially — no race.
    nonisolated(unsafe) private static var stand: Stand?

    private struct Stand {
        var dir: String          // temporary HOME
        var vault: String        // temporary note vault
        var port: UInt16 = 18123
        var process: Process
    }

    override class func setUp() {
        super.setUp()
        if stand != nil { return }
        stand = try! launchStand()
    }

    override class func tearDown() {
        stand?.process.interrupt()
        stand = nil
        super.tearDown()
    }

    private static func launchStand() throws -> Stand {
        let fm = FileManager.default
        // Short path: sun_path in sockaddr_un is limited to 104 bytes,
        // NSTemporaryDirectory() (var/folders/...) overflows it.
        let dir = "/tmp/bmem-ui1-" + String(UUID().uuidString.prefix(8))
        let vault = dir + "/vault"
        try fm.createDirectory(atPath: vault + "/notes", withIntermediateDirectories: true)

        // UI-5: benchmark-dir isolation. Without the override the daemon would
        // write custom.json (custom benchmarks) into evals/ in the repo and litter the checkout.
        let evals = dir + "/evals"
        try fm.createDirectory(atPath: evals, withIntermediateDirectories: true)

        // Notes: two human (no source) and two agent (source: agent),
        // all about the same subject — the trust filter must separate exactly them.
        let notes: [(String, String, String)] = [
            ("human1", "human", "Coffee dispenser Gaggia: a real-life review of how I brew at home."),
            ("human2", "human", "Bought a coffee dispenser at the market, sharing a human impression."),
            ("agent1", "agent", "Coffee dispenser: an agent note, observation protocol."),
            ("agent2", "agent", "Coffee dispenser agent log: measured, recorded by an agent."),
        ]
        for (name, source, body) in notes {
            let text = "---\ntitle: Note \(name)\npermalink: hermes/notes/\(name)\ntype: note\n"
                + (source == "agent" ? "source: agent\n" : "")
                + "---\n\(body)\n"
            try text.write(toFile: vault + "/notes/\(name).md", atomically: true, encoding: .utf8)
        }

        // Binary: swift test builds the whole package, the debug artifact sits nearby.
        // BMEM_TEST_BINARY — explicit override for stands outside SPM.
        let exe: String
        if let override = ProcessInfo.processInfo.environment["BMEM_TEST_BINARY"], fm.isExecutableFile(atPath: override) {
            exe = override
        } else {
            let repoRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // BMemAPITests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // repo root
            let candidates = [".build/debug/bmem", ".build/release/bmem"]
                .map { repoRoot.appendingPathComponent($0).path }
            guard let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
                throw StandError(description: "bmem binary not found; run `swift build` first. Tried: \(candidates.joined(separator: ", "))")
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
        env["BMEM_EMBED_PORT"] = "18123"
        env["BMEM_PROJECT_PATH"] = vault
        env["BMEM_MODEL_IDLE_TIMEOUT"] = "0"      // do not unload the model mid-test
        env["BMEM_MEM_LOG"] = dir + "/daemon.log"
        env["BMEM_EVALS_DIR"] = evals
        // A copy of the frozen benchmark into the stand dir — testBenchmark
        // must see the same 58/70 as the production run.
        let repoRootForEvals = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let runFile = repoRootForEvals.appendingPathComponent("evals/run-2026-10-14-metrics.json").path
        if fm.fileExists(atPath: runFile) {
            try? fm.copyItem(atPath: runFile, toPath: evals + "/run-2026-10-14-metrics.json")
        }
        // The model is the real one, from the real home (the test HOME does not see it).
        let realHome = env["HOME_REAL"] ?? NSHomeDirectory()
        env["BMEM_GEMMA_MODEL_DIR"] = realHome + "/.bmem/models/embeddinggemma-2-coreml"
        env["BMEM_MODEL_DIR"] = realHome + "/.bmem/models"
        p.environment = env
        FileManager.default.createFile(atPath: dir + "/daemon.log", contents: nil)
        let logFH = FileHandle(forWritingAtPath: dir + "/daemon.log")!
        p.standardOutput = logFH
        p.standardError = logFH
        try p.run()

        let stand = Stand(dir: dir, vault: vault, process: p)

        // Wait for the HTTP endpoint and the initial indexing (warm+reindex in the
        // daemon are background; cold ANE compilation on a clean machine takes up to 180 s).
        // The loop is synchronous: http() itself blocks on a semaphore, no actors needed.
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if let (status, json) = try? http("GET", "/v1/status", port: 18123, timeout: 3),
               status == 200,
               let index = json["index"] as? [String: Any],
               let projects = index["projects"] as? [[String: Any]],
               projects.contains(where: { (($0["chunks"] as? Int) ?? 0) > 0 }) {
                return stand
            }
            if !p.isRunning {
                throw StandError(description: "daemon exited early; see \(dir)/daemon.log")
            }
            usleep(1_000_000)
        }
        throw StandError(description: "stand not ready in 180s; see \(dir)/daemon.log")
    }

    // MARK: - HTTP helper

    private func http(_ method: String, _ path: String, body: String? = nil,
                      timeout: TimeInterval = 240) throws -> (Int, [String: Any]) {
        try Self.http(method, path, body: body, timeout: timeout)
    }

    private static func http(_ method: String, _ path: String, body: String? = nil,
                             port: UInt16 = 18123, timeout: TimeInterval = 240) throws -> (Int, [String: Any]) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw StandError(description: "bad url")
        }
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        if let body { req.httpBody = Data(body.utf8) }
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
        guard let out else { throw StandError(description: "no response from \(method) \(path)") }
        return out
    }

    private var standDir: String { Self.stand!.dir }
    private var standVault: String { Self.stand!.vault }
    private var standProcessId: pid_t { pid_t(Self.stand!.process.processIdentifier) }

    // MARK: - Tests

    func testStatus() throws {
        let (code, json) = try http("GET", "/v1/status")
        XCTAssertEqual(code, 200)
        XCTAssertEqual(json["version"] as? String, "1.1.2-beta3")
        XCTAssertEqual(json["engine"] as? String, "embeddinggemma-2")
        XCTAssertEqual(json["engine_dim"] as? Int, 768)
        XCTAssertNotNil(json["model_loaded"])
        XCTAssertNotNil(json["memory_mb"])
        XCTAssertNotNil(json["memory_peak_mb"], "UI-5: footprint peak is required for the idle/peak line")
        XCTAssertNotNil(json["memory_limit_mb"])
        XCTAssertNotNil(json["autostart"])
        // Daemon lifecycle fix: daemon pid (the app signals the old one to quit) and the
        // actual idle-unload threshold. The stand runs with
        // BMEM_MODEL_IDLE_TIMEOUT=0 — /v1/status must report the ACTUAL threshold,
        // not the code constant; the constant is covered in LocalizationTests.
        XCTAssertEqual(json["pid"] as? Int, Int(standProcessId),
                       "pid in /v1/status == pid of the stand daemon")
        XCTAssertEqual(json["model_idle_timeout_s"] as? Int, 0,
                       "model_idle_timeout_s must reflect the stand BMEM_MODEL_IDLE_TIMEOUT")
        let index = json["index"] as? [String: Any]
        XCTAssertNotNil(index, "index section missing")
        let projects = index?["projects"] as? [[String: Any]]
        XCTAssertNotNil(projects)
        XCTAssertTrue(projects!.contains { ($0["name"] as? String) == "hermes" && (($0["chunks"] as? Int) ?? 0) > 0 },
                      "hermes project with chunks expected in \(projects ?? [])")
        let hermes = projects!.first { ($0["name"] as? String) == "hermes" }!
        XCTAssertGreaterThanOrEqual(hermes["notes"] as? Int ?? 0, 4)
        XCTAssertNotNil(hermes["indexed_at"], "freshness (indexed_at) must be set after warm reindex")
        // Index reporting: three separate numbers + honest dirty must be in the response;
        // a healthy stand — failed=0 and dirty=false (a live tail is not dirt).
        XCTAssertNotNil(index?["indexed"] as? Int, "index reporting: indexed counter")
        XCTAssertNotNil(index?["open"] as? Int, "index reporting: open counter")
        XCTAssertEqual(index?["failed"] as? Int, 0, "index reporting: clean stand must report failed=0")
        XCTAssertEqual(index?["dirty"] as? Bool, false, "index reporting: clean stand must report dirty=false")
        XCTAssertNotNil(hermes["open"], "index reporting: per-project open")
        XCTAssertNotNil(hermes["failed"], "index reporting: per-project failed")
    }

    func test01GetConfigDefaults() throws {
        let (code, json) = try http("GET", "/v1/config")
        XCTAssertEqual(code, 200)
        XCTAssertEqual(json["default_project"] as? String, "hermes")
        XCTAssertEqual(json["engine"] as? String, "gemma")
        XCTAssertEqual(json["telemetry"] as? Bool, false, "telemetry is off by default")
        XCTAssertEqual(json["lan_access"] as? Bool, false)
        XCTAssertEqual(json["launch_at_login"] as? Bool, false)
        let never = json["never_touch"] as? [String]
        XCTAssertNotNil(never)
        XCTAssertTrue(never!.contains("~/.ssh"), "the never-touch list must be non-empty")
        let projects = json["projects"] as? [String: String]
        XCTAssertEqual(projects?["hermes"], standDir + "/vault")
    }

    func test02PutConfigPersists() throws {
        let put = """
        {"hotkey":"^\\\\^B","telemetry":true,"lan_access":true,"memory_limit_mb":4096,"exclude_dirs":["build"]}
        """
        let (code, after) = try http("PUT", "/v1/config", body: put)
        XCTAssertEqual(code, 200)
        XCTAssertEqual(after["hotkey"] as? String, "^\\^B")
        XCTAssertEqual(after["telemetry"] as? Bool, true)
        XCTAssertEqual(after["lan_access"] as? Bool, true)
        XCTAssertEqual(after["memory_limit_mb"] as? Double, 4096)
        XCTAssertEqual(after["exclude_dirs"] as? [String], ["build"])

        // GET shows the same (in memory)
        let (code2, got) = try http("GET", "/v1/config")
        XCTAssertEqual(code2, 200)
        XCTAssertEqual(got["hotkey"] as? String, "^\\^B")
        XCTAssertEqual(got["telemetry"] as? Bool, true)

        // and on disk it is the same file the daemon reads at startup
        let disk = try String(contentsOfFile: standDir + "/.bmem/config.json", encoding: .utf8)
        XCTAssertTrue(disk.contains("\"telemetry\" : true"), "config.json on disk: \(disk)")
        XCTAssertTrue(disk.contains("\"memoryLimitMB\" : 4096"))
        XCTAssertTrue(disk.contains("\"hotkey\" : \"^\\\\^B\""))
    }

    func test03PutConfigValidation() throws {
        let (code1, _) = try http("PUT", "/v1/config", body: #"{"engine":"gpt9"}"#)
        XCTAssertEqual(code1, 400, "an unknown engine must be rejected")
        let (code2, json2) = try http("PUT", "/v1/config", body: #"{"opeshka":1}"#)
        XCTAssertEqual(code2, 400)
        XCTAssertTrue((json2["error"] as? String)?.contains("unknown keys") == true)
        let (code3, _) = try http("PUT", "/v1/config", body: #"{"min_similarity":5}"#)
        XCTAssertEqual(code3, 400)
        // after the rejections the value did not change
        let (_, cfg) = try http("GET", "/v1/config")
        XCTAssertEqual(cfg["engine"] as? String, "gemma")
    }

    /// UI-7 (smoke 1.1.1-beta1): PUT /v1/config must reach the Engine without a
    /// daemon restart — otherwise onboarding adds a folder while search keeps
    /// answering "unknown project" until the next daemon start.
    func test04PutConfigReachesEngineWithoutRestart() throws {
        let dir = standDir + "/ui7-vault"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "A note about the purple camel. One of a kind.\n".write(
            toFile: dir + "/verblyud.md", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let put = "{\"projects\":{\"hermes\":\"\(standVault)\",\"ui7\":\"\(dir)\"}}"
        let (code, _) = try http("PUT", "/v1/config", body: put)
        XCTAssertEqual(code, 200)
        defer { _ = try? http("PUT", "/v1/config", body: "{\"projects\":{\"hermes\":\"\(standVault)\"}}") }

        // Before the fix this was a 404 unknown project (the engine lived on the startup snapshot).
        let q = "q=purple%20camel"
        let (code2, json2) = try http("GET", "/v1/search?\(q)&project=ui7&limit=3")
        XCTAssertEqual(code2, 200, "a new project must be searchable without a restart: \(json2)")
        let hits = json2["results"] as? [Any] ?? []
        XCTAssertFalse(hits.isEmpty, "the first search indexed ui7 synchronously")
    }

    func testSearchTrustFilter() throws {
        let q = "coffee%20dispenser"
        let (code, all) = try http("GET", "/v1/search?q=\(q)&limit=10")
        XCTAssertEqual(code, 200)
        let results = all["results"] as? [[String: Any]] ?? []
        XCTAssertGreaterThanOrEqual(results.count, 2, "hybrid search must find both human and agent notes: \(all)")
        XCTAssertTrue(results.contains { ($0["source"] as? String) == "agent" })
        XCTAssertTrue(results.contains { ($0["source"] as? String) != "agent" })

        let (_, agentOnly) = try http("GET", "/v1/search?q=\(q)&trust=agent")
        let agentResults = agentOnly["results"] as? [[String: Any]] ?? []
        XCTAssertFalse(agentResults.isEmpty, "trust=agent must find something")
        XCTAssertTrue(agentResults.allSatisfy { ($0["source"] as? String) == "agent" },
                      "trust=agent returned a human note: \(agentResults)")

        let (_, humanOnly) = try http("GET", "/v1/search?q=\(q)&trust=human")
        let humanResults = humanOnly["results"] as? [[String: Any]] ?? []
        XCTAssertFalse(humanResults.isEmpty, "trust=human must find something")
        XCTAssertTrue(humanResults.allSatisfy { ($0["source"] as? String) != "agent" },
                      "trust=human returned an agent note: \(humanResults)")
    }

    func testSearchStrictnessAndArgs() throws {
        let q = "coffee%20dispenser"
        let (code, strict) = try http("GET", "/v1/search?q=\(q)&strictness=0.999")
        XCTAssertEqual(code, 200)
        let results = strict["results"] as? [[String: Any]] ?? []
        // almost nothing reaches 0.999 cosine; in any case no more than without a threshold
        XCTAssertTrue(results.allSatisfy { (($0["score"] as? Double) ?? 0) >= 0.999 })

        let (badQ, _) = try http("GET", "/v1/search")
        XCTAssertEqual(badQ, 400)
        let (badTrust, _) = try http("GET", "/v1/search?q=x&trust=bogus")
        XCTAssertEqual(badTrust, 400)
        let (badStrict, _) = try http("GET", "/v1/search?q=x&strictness=2")
        XCTAssertEqual(badStrict, 400)
        let (badProject, _) = try http("GET", "/v1/search?q=x&project=net-proekta")
        XCTAssertEqual(badProject, 404)
    }

    func testBenchmark() throws {
        // The frozen reference lives in evals/ — it may be absent from a public
        // snapshot; skip instead of failing in that case.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let runFile = repoRoot.appendingPathComponent("evals/run-2026-10-14-metrics.json").path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: runFile),
                          "the frozen evals/run-*.json reference is not part of this snapshot")
        let (code, json) = try http("GET", "/v1/benchmark")
        XCTAssertEqual(code, 200)
        XCTAssertEqual(json["engine"] as? String, "gemma")
        XCTAssertEqual(json["total"] as? Int, 70, "benchmark frozen: 70 questions")
        XCTAssertEqual(json["hit"] as? Int, 58, "last Gemma-2 run: top1=58")
        XCTAssertFalse((json["source"] as? String ?? "").isEmpty)
    }

    // MARK: - UI-5: custom benchmarks (POST /v1/benchmark/custom, recheck)

    /// Full cycle: add with a correct file (hit), add with an invented one
    /// (honest hit=false), GET returns the custom section, recheck re-verifies,
    /// custom.json lives in the stand BMEM_EVALS_DIR, not in the repository.
    func test20CustomBenchmarkAddCheckRecheck() throws {
        let (c1, r1) = try http("POST", "/v1/benchmark/custom",
                                body: #"{"question":"coffee dispenser Gaggia review from real life","expected_file":"human1.md"}"#)
        XCTAssertEqual(c1, 200, "custom add: \(r1)")
        let entry1 = try XCTUnwrap(r1["entry"] as? [String: Any])
        let check1 = try XCTUnwrap(entry1["last_check"] as? [String: Any])
        XCTAssertEqual(check1["hit"] as? Bool, true,
                       "top1 for the Gaggia question must be human1.md, got \(check1["top1"] ?? "nil")")

        let (c2, r2) = try http("POST", "/v1/benchmark/custom",
                                body: #"{"question":"coffee dispenser","expected_file":"tot-net-takogo-faila.md"}"#)
        XCTAssertEqual(c2, 200)
        let entry2 = try XCTUnwrap(r2["entry"] as? [String: Any])
        let check2 = try XCTUnwrap(entry2["last_check"] as? [String: Any])
        XCTAssertEqual(check2["hit"] as? Bool, false, "an invented file must not count as a hit")
        XCTAssertNotNil(check2["top1"], "top1 must be shown even on a miss")
        let custom2 = try XCTUnwrap(r2["custom"] as? [String: Any])
        XCTAssertEqual(custom2["total"] as? Int, 2)
        XCTAssertEqual(custom2["hit"] as? Int, 1)

        let (c3, bench) = try http("GET", "/v1/benchmark")
        XCTAssertEqual(c3, 200)
        let custom = try XCTUnwrap(bench["custom"] as? [String: Any])
        XCTAssertEqual(custom["total"] as? Int, 2)
        XCTAssertEqual(custom["hit"] as? Int, 1)
        let frozenRunFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("evals/run-2026-10-14-metrics.json").path
        if FileManager.default.fileExists(atPath: frozenRunFile) {
            XCTAssertEqual(bench["total"] as? Int, 70, "the frozen benchmark does not change from custom")
        }

        let (c4, r4) = try http("POST", "/v1/benchmark/custom/recheck")
        XCTAssertEqual(c4, 200)
        let custom4 = try XCTUnwrap(r4["custom"] as? [String: Any])
        XCTAssertEqual(custom4["total"] as? Int, 2)
        XCTAssertEqual(custom4["hit"] as? Int, 1)

        let customFile = standDir + "/evals/custom.json"
        XCTAssertTrue(FileManager.default.fileExists(atPath: customFile),
                      "storage is evals/custom.json (stand): \(customFile)")
    }

    func test21CustomBenchmarkValidation() throws {
        let (empty, _) = try http("POST", "/v1/benchmark/custom", body: "{}")
        XCTAssertEqual(empty, 400, "empty body — 400")
        let (partial, _) = try http("POST", "/v1/benchmark/custom",
                                    body: #"{"question":"there is a question"}"#)
        XCTAssertEqual(partial, 400, "without expected_file — 400")
        let (blank, _) = try http("POST", "/v1/benchmark/custom",
                                  body: #"{"question":"  ","expected_file":"x.md"}"#)
        XCTAssertEqual(blank, 400, "blank question — 400")
    }

    // MARK: - UI-4: auto-backup, rollbacks, diff, forget (shared stand, test1x names
    // so they run before the search tests and do not interfere with them)

    /// Enabling via the toggle: PUT auto_backup=true initializes ~/.bmem/backup
    /// (in the stand HOME) and commits immediately — the screen must not wait for 03:00.
    func test10AutoBackupEnableInitializesRepo() throws {
        let (code, after) = try http("PUT", "/v1/config", body: #"{"auto_backup":true}"#)
        XCTAssertEqual(code, 200)
        XCTAssertEqual(after["auto_backup"] as? Bool, true)

        let (pcode, pts) = try http("GET", "/v1/rollback/points")
        XCTAssertEqual(pcode, 200)
        XCTAssertEqual(pts["git_backup"] as? Bool, true, "the backup repository must appear on enable")
        XCTAssertEqual(pts["auto_backup"] as? Bool, true)
        XCTAssertEqual(pts["schedule"] as? String, "every day at 03:00")
        let points = pts["points"] as? [[String: Any]] ?? []
        XCTAssertFalse(points.isEmpty, "first commit immediately on enable: \(pts)")
        let first = points[0]
        XCTAssertFalse((first["commit"] as? String ?? "").isEmpty)
        XCTAssertFalse((first["date"] as? String ?? "").isEmpty)
        XCTAssertEqual(first["author"] as? String, "BMem")
        XCTAssertNotNil(first["changes"])
        // the repository is in the stand HOME, the production ~/.bmem is untouched
        XCTAssertEqual(pts["backup_dir"] as? String, standDir + "/.bmem/backup")
    }

    /// DoD duty at the API level: a note written after the point
    /// is not lost on rollback.
    func test11RollbackKeepsNoteWrittenAfterPoint() throws {
        let (_, pts) = try http("GET", "/v1/rollback/points")
        let points = pts["points"] as? [[String: Any]] ?? []
        guard let oldest = points.last?["commit"] as? String else {
            return XCTFail("no rollback points: \(pts)")
        }
        // a note written AFTER the oldest point
        let fresh = standVault + "/notes/after-point-ui4.md"
        try "written after the point\n".write(toFile: fresh, atomically: true, encoding: .utf8)

        let (code, res) = try http("POST", "/v1/rollback", body: #"{"point":"\#(oldest)"}"#)
        XCTAssertEqual(code, 200, "rollback to a valid point: \(res)")
        XCTAssertEqual(res["ok"] as? Bool, true)
        XCTAssertFalse((res["pre_rollback_commit"] as? String ?? "").isEmpty,
                       "the pre-rollback commit is mandatory — a rollback must be rollback-able")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh),
                      "a note written after the point was lost on rollback")

        // and the list now shows the pre-rollback + the rollback itself
        let (_, pts2) = try http("GET", "/v1/rollback/points")
        let msgs = (pts2["points"] as? [[String: Any]] ?? []).compactMap { $0["message"] as? String }
        XCTAssertTrue(msgs.contains { $0.hasPrefix("pre-rollback") }, "no pre-rollback commit: \(msgs)")
        XCTAssertTrue(msgs.contains { $0.hasPrefix("rollback to") }, "no rollback commit: \(msgs)")
    }

    func test12RollbackDiff() throws {
        let (code, d) = try http("GET", "/v1/rollback/diff?days=7")
        XCTAssertEqual(code, 200)
        XCTAssertEqual(d["days"] as? Int, 7)
        XCTAssertGreaterThanOrEqual(d["commits"] as? Int ?? 0, 1)
        let files = d["files"] as? [[String: Any]] ?? []
        XCTAssertFalse(files.isEmpty, "memory changed during the tests — diff is empty: \(d)")
        XCTAssertTrue(files.allSatisfy { ($0["path"] as? String)?.isEmpty == false })
        // days out of range is clamped, does not crash
        let (c2, _) = try http("GET", "/v1/rollback/diff?days=999")
        XCTAssertEqual(c2, 200)
    }

    /// Forgetting the second project: files go to ~/.bmem/forgotten, the index is
    /// purged, the project disappears from config. hermes stays — search tests need it.
    func test13ForgetProject() throws {
        let throwaway = standDir + "/throwaway"
        try FileManager.default.createDirectory(atPath: throwaway, withIntermediateDirectories: true)
        try "---\ntitle: Trash\npermalink: throwaway/musor\n---\nthrowaway note\n"
            .write(toFile: throwaway + "/musor.md", atomically: true, encoding: .utf8)
        let vault = standVault
        let (pcode, _) = try http("PUT", "/v1/config",
                                  body: #"{"projects":{"hermes":"\#(vault)","throwaway":"\#(throwaway)"}}"#)
        XCTAssertEqual(pcode, 200)

        let (code, res) = try http("POST", "/v1/forget", body: #"{"project":"throwaway"}"#)
        XCTAssertEqual(code, 200, "forget: \(res)")
        XCTAssertEqual(res["ok"] as? Bool, true)
        let archived = res["archived_to"] as? String ?? ""
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived + "/musor.md"),
                      "file not archived into \(archived)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: throwaway + "/musor.md"))
        XCTAssertGreaterThanOrEqual(res["files_archived"] as? Int ?? 0, 1)

        let (_, cfg) = try http("GET", "/v1/config")
        let projects = cfg["projects"] as? [String: String] ?? [:]
        XCTAssertNil(projects["throwaway"], "the project must disappear from config")
        XCTAssertNotNil(projects["hermes"], "hermes must stay (search tests need it)")

        let (again, _) = try http("POST", "/v1/forget", body: #"{"project":"throwaway"}"#)
        XCTAssertEqual(again, 404, "forgetting again — unknown project")
    }

    func testRollbackValidation() throws {
        // backup was already enabled in test10 — the 501 stubs are gone, validation remains
        let (bad, _) = try http("POST", "/v1/rollback", body: "{}")
        XCTAssertEqual(bad, 400, "rollback without point — 400")
        let (ghost, gjson) = try http("POST", "/v1/rollback",
                                      body: #"{"point":"0000000000000000000000000000000000000000"}"#)
        XCTAssertEqual(ghost, 404, "a nonexistent point — 404: \(gjson)")

        let (forgetBad, _) = try http("POST", "/v1/forget", body: "{}")
        XCTAssertEqual(forgetBad, 400)
        let (forgetUnknown, _) = try http("POST", "/v1/forget", body: #"{"project":"net-proekta"}"#)
        XCTAssertEqual(forgetUnknown, 404)
    }

    func testUnknownRouteAndEmbedRegression() throws {
        let (nf, _) = try http("GET", "/v1/nesuschestvuet")
        XCTAssertEqual(nf, 404)

        // regression: the openai endpoint stays alive after control-route delegation
        let (code, emb) = try http("POST", "/v1/embeddings",
                                   body: #"{"model":"x","input":"hello"}"#)
        XCTAssertEqual(code, 200)
        let data = emb["data"] as? [[String: Any]] ?? []
        XCTAssertEqual(data.count, 1)
        XCTAssertEqual((data.first?["embedding"] as? [Any])?.count, 768)
    }

    // MARK: - UI-3: live-decoding stand responses into facade API models

    /// Production-shape responses from the stand must map into BMemAPI models
    /// (BMemApp reads the same structs). JSON goes through Data, as in the UI.
    func testLiveStatusDecodesIntoUIModels() throws {
        let (code, json) = try http("GET", "/v1/status")
        XCTAssertEqual(code, 200)
        let data = try JSONSerialization.data(withJSONObject: json)
        let s = try JSONDecoder().decode(DaemonStatus.self, from: data)
        XCTAssertEqual(s.version, "1.1.2-beta3")
        XCTAssertFalse(s.engine.isEmpty)
        XCTAssertNotNil(s.index)
        // Daemon lifecycle fix: the new fields must map into the UI models (they render the
        // threshold line and the decision to replace a foreign daemon).
        XCTAssertEqual(s.pid, Int(standProcessId), "pid must map into DaemonStatus")
        XCTAssertEqual(s.model_idle_timeout_s, 0, "model_idle_timeout_s must map into DaemonStatus")
        let p = try XCTUnwrap(s.index?.projects?.first)
        XCTAssertEqual(p.name, "hermes", "the stand indexes the single hermes project")
        XCTAssertGreaterThan(p.notes ?? 0, 0)
        XCTAssertGreaterThan(p.chunks ?? 0, 0)
        // indexed_at on the stand may be null (indexing cycle not finished) —
        // null mapping is covered by the golden test testStatusNullIndexedAtDecodesAsNil.
    }

    func testLiveConfigDecodesIntoUIModels() throws {
        let (code, json) = try http("GET", "/v1/config")
        XCTAssertEqual(code, 200)
        let data = try JSONSerialization.data(withJSONObject: json)
        let c = try JSONDecoder().decode(DaemonConfig.self, from: data)
        XCTAssertEqual(c.projects["hermes"]?.hasSuffix("/vault"), true)
        XCTAssertEqual(c.engine, "gemma")
        XCTAssertEqual(c.never_touch?.count, 6, "the never-touch list has 6 entries")
        // PUT through the model: lan_access=true must come back in the config response.
        var patch = c
        patch.lan_access = true
        let (putCode, _) = try http("PUT", "/v1/config",
                                    body: String(data: try JSONSerialization.data(withJSONObject: patch.patchJSON()), encoding: .utf8)!)
        XCTAssertEqual(putCode, 200)
        let (_, after) = try http("GET", "/v1/config")
        XCTAssertEqual(after["lan_access"] as? Bool, true)
    }

    // MARK: - Index reporting: indexed / open / failed instead of eternal dirty=yes

    /// Full counter cycle: a live session tail (>256 KB) is open, not dirt;
    /// open older than 24 h is dirt; an unreadable file is failed and dirt;
    /// after cleanup the stand is clean again. Name testZZ* — the test runs last
    /// and sweeps after itself without affecting neighboring status checks.
    func testZZIndexHealthOpenFailedDirty() throws {
        func indexSection() throws -> [String: Any] {
            let (c, j) = try http("GET", "/v1/status")
            XCTAssertEqual(c, 200)
            return try XCTUnwrap(j["index"] as? [String: Any], "index section missing")
        }
        // Freshness sweep via search: the index is in sync by response time.
        func sweep() throws { _ = try http("GET", "/v1/search?q=coffee&limit=1") }

        // 0) baseline: a healthy stand — three zeros and dirty=false
        try sweep()
        var idx = try indexSection()
        XCTAssertEqual(idx["failed"] as? Int, 0, "baseline failed=0")
        XCTAssertEqual(idx["open"] as? Int, 0, "baseline open=0")
        XCTAssertEqual(idx["dirty"] as? Bool, false, "baseline dirty=false")
        XCTAssertGreaterThanOrEqual(idx["indexed"] as? Int ?? 0, 4, "stand notes are indexed")

        // 1) session tail >256 KB: normally pending — open+=1, dirty NOT touched
        let fm = FileManager.default
        let tail = standVault + "/notes/session-tail.md"
        try String(repeating: "line of a live session transcript.\n", count: 20_000)
            .write(toFile: tail, atomically: true, encoding: .utf8)
        idx = try indexSection()
        XCTAssertGreaterThanOrEqual(idx["open"] as? Int ?? 0, 1,
                                    "index reporting: an oversize session tail must land in open")
        XCTAssertEqual(idx["failed"] as? Int, 0, "a tail is not a failure")
        XCTAssertEqual(idx["dirty"] as? Bool, false,
                       "index reporting: a fresh open file does not make the index dirty (the very nightly false alarm)")

        // 2) the same open aged 48 h — past the 24 h threshold, dirty=yes
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-48 * 3600)], ofItemAtPath: tail)
        idx = try indexSection()
        XCTAssertEqual(idx["dirty"] as? Bool, true, "index reporting: open older than a day must raise dirty")

        // 3) an unreadable file — a real failure: failed+=1, dirty=yes, no double-count in open
        let broken = standVault + "/notes/broken.md"
        try "unreadable note\n".write(toFile: broken, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: broken)
        try sweep()   // ensureFresh -> reindex will record the read failure
        idx = try indexSection()
        XCTAssertEqual(idx["failed"] as? Int, 1, "index reporting: an unreadable file is failed, not silence")
        XCTAssertEqual(idx["dirty"] as? Bool, true, "failed>0 must raise dirty")

        // 4) cleanup: files removed, a run — counters back to zero, dirty=no
        try? fm.removeItem(atPath: tail)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: broken)
        try fm.removeItem(atPath: broken)
        try sweep()
        idx = try indexSection()
        XCTAssertEqual(idx["failed"] as? Int, 0, "index reporting: a failure must clear after fix/removal")
        XCTAssertEqual(idx["open"] as? Int, 0, "open is empty after cleanup")
        XCTAssertEqual(idx["dirty"] as? Bool, false, "failed=0 and open empty — dirty=no")
    }
}
