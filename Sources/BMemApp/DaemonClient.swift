import Foundation
import AppKit
import BMemAPI

/// Thin client of the daemon control API (docs/control-api.md, UI-1).
/// The daemon may be not running — that is a normal state, not an app error.
///
/// Daemon URL: --daemon-url <url> or BMEM_DAEMON_URL (the UI-3 stand runs
/// against the test daemon :18123 with a temporary DB; production :8123 is the default).
enum DaemonEndpoint {
    static var base: URL {
        if let s = argValue("daemon-url"), let url = URL(string: s), url.scheme?.hasPrefix("http") == true {
            return url
        }
        if let env = ProcessInfo.processInfo.environment["BMEM_DAEMON_URL"],
           let url = URL(string: env), url.scheme?.hasPrefix("http") == true {
            return url
        }
        return URL(string: "http://127.0.0.1:8123")!
    }

    /// The address is not overridden by flags/environment — this is the production default :8123.
    /// Only on it the app starts the daemon itself (UI-7); the stands
    /// (--daemon-url, BMEM_DAEMON_URL) own their daemon from outside; if a
    /// stand also needs autostart (smoke with a nonstandard port) — set
    /// BMEM_APP_SPAWN=1 explicitly.
    static var isDefault: Bool {
        argValue("daemon-url") == nil
            && ProcessInfo.processInfo.environment["BMEM_DAEMON_URL"] == nil
    }
}

@MainActor
final class DaemonModel: ObservableObject {
    enum State: Equatable {
        case checking
        case unreachable
        case online(DaemonStatus)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.checking, .checking), (.unreachable, .unreachable): return true
            case let (.online(a), .online(b)): return a.version == b.version && a.engine == b.engine
            default: return false
            }
        }
    }

    @Published private(set) var state: State = .checking
    /// The last successfully read /v1/config; nil — not read yet or the daemon is unreachable.
    @Published private(set) var config: DaemonConfig?
    /// The last PUT /v1/config error (shown honestly in the UI, not swallowed).
    @Published var lastPutError: String?

    private let baseURL = DaemonEndpoint.base

    func refresh() async {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/status"))
        request.timeoutInterval = 1.5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                state = .unreachable
                return
            }
            state = .online(try JSONDecoder().decode(DaemonStatus.self, from: data))
        } catch {
            state = .unreachable
        }
    }

    func refreshConfig() async {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/config"))
        request.timeoutInterval = 1.5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let cfg = try? JSONDecoder().decode(DaemonConfig.self, from: data)
        else { return }
        config = cfg
    }

    /// PUT /v1/config with a partial patch; the response is the full config after write.
    func putConfig(_ patch: [String: Any]) async {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/config"))
        request.httpMethod = "PUT"
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: patch)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                lastPutError = String(data: data, encoding: .utf8) ?? "HTTP \(code)"
                return
            }
            lastPutError = nil
            config = try JSONDecoder().decode(DaemonConfig.self, from: data)
        } catch {
            lastPutError = String(describing: error)
        }
    }

    /// Periodic status and config refresh (footer, UI-3 screens).
    /// UI-7: the first unreachable on the default address launches the bundled
    /// daemon — on first launch the app itself starts/finds the daemon.
    /// Daemon lifecycle fix: a live daemon of a FOREIGN version is also not left as is —
    /// the app takes it down and starts its own from the bundle (see replaceForeignDaemon).
    func pollLoop() async {
        while !Task.isCancelled {
            await refresh()
            if case .unreachable = state {
                spawnBundledDaemonOnce()
            } else if case .online(let st) = state, needsDaemonReplacement(st) {
                await replaceForeignDaemon(st)
                await refresh()   // the new daemon may come up faster than the tick
            }
            await refreshConfig()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    // MARK: - UI-7: autostart of the bundled daemon

    /// Whether we already tried to start the daemon in this app run (one
    /// attempt — repeated polls must not stack up processes).
    private var daemonSpawnAttempted = false

    /// In the release bundle the daemon binary sits next to the app
    /// (Contents/MacOS/bmem, like launcher/bmem in the 1.1.1 dmg). If nobody
    /// answered on the default :8123 — we start it once; a live daemon (CLI
    /// path, launchd, Login Item) the app simply finds. The child process
    /// survives the app exit (not killed with the parent).
    private func spawnBundledDaemonOnce() {
        guard !daemonSpawnAttempted else { return }
        daemonSpawnAttempted = true
        guard DaemonEndpoint.isDefault
            || ProcessInfo.processInfo.environment["BMEM_APP_SPAWN"] == "1" else { return }
        guard let helper = Bundle.main.path(forAuxiliaryExecutable: "bmem") else { return }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let dir = home + "/.bmem"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let logPath = dir + "/daemon.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: helper)
        p.arguments = ["daemon"]
        p.environment = ProcessInfo.processInfo.environment
        if let fh = FileHandle(forWritingAtPath: logPath) {
            p.standardOutput = fh
            p.standardError = fh
        } else {
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
        }
        do {
            try p.run()
        } catch {
            stderrLog(Lf("log.daemon.notUp", String(describing: error)) + "\n")
        }
    }

    // MARK: - Daemon lifecycle fix: the app owns the daemon
    //
    // Defect: the user updated the dmg while :8123 kept serving the old
    // daemon from ~/.local/bin — the app «found» it and silently left it as is.
    // Invariant: after the app starts, the daemon version in /v1/status == the
    // app version. If a daemon of another version sits on the port — we take it
    // down correctly (POST /v1/shutdown -> SIGTERM by pid -> SIGKILL as a last
    // resort) and start our own from the bundle. Budget 2 attempts per run:
    // an endless ping-pong (e.g. a launchd agent stubbornly reviving the old
    // one) must not stack kill cycles.

    /// The app version from Info.plist; empty — a build without a bundle
    /// (`swift run`), nothing to compare against, we do not interfere.
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// The app may own the daemon at this address (the same criterion as the
    /// UI-7 autostart) and the bundled binary is in place.
    private var mayOwnDaemon: Bool {
        (DaemonEndpoint.isDefault
            || ProcessInfo.processInfo.environment["BMEM_APP_SPAWN"] == "1")
            && Bundle.main.path(forAuxiliaryExecutable: "bmem") != nil
    }

    private var replaceAttempts = 0
    private var replacingDaemon = false

    private func needsDaemonReplacement(_ st: DaemonStatus) -> Bool {
        mayOwnDaemon && !appVersion.isEmpty && !replacingDaemon
            && replaceAttempts < 2 && st.version != appVersion
    }

    private func replaceForeignDaemon(_ st: DaemonStatus) async {
        replacingDaemon = true
        replaceAttempts += 1
        defer { replacingDaemon = false }
        stderrLog(Lf("log.daemon.replacing", st.version, appVersion) + "\n")
        // 1. a polite request: daemons since this fix do reply+drain+exit;
        //    old ones answer 404 — not an error, we move to signals.
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/shutdown"))
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        _ = try? await URLSession.shared.data(for: req)
        if await waitDaemonGone(until: 20) { finishReplacement(); return }
        // 2. SIGTERM: pid from /v1/status (daemons with the fix), otherwise by
        //    the port listener (lsof). A daemon with the fix drains on SIGTERM too.
        let port = baseURL.port ?? 8123
        if let pid = st.pid ?? Self.listenerPid(port: port), pid > 0 {
            kill(pid_t(pid), SIGTERM)
            if await waitDaemonGone(until: 20) { finishReplacement(); return }
            kill(pid_t(pid), SIGKILL)
            _ = await waitDaemonGone(until: 10)
        }
        // 3. even if we did not wait it out — try to start ours: flock will not
        //    let two daemons live, and the next tick will assess the honest state.
        finishReplacement()
    }

    /// Short /v1/status probes: the port is free (transport error or non-200)
    /// = the daemon is gone.
    private func waitDaemonGone(until seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var r = URLRequest(url: baseURL.appendingPathComponent("v1/status"))
            r.timeoutInterval = 1
            let alive: Bool
            if let (data, resp) = try? await URLSession.shared.data(for: r),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                alive = true
            } else {
                alive = false
            }
            if !alive { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// Taken down — allow autostart a new attempt and start the bundled one.
    private func finishReplacement() {
        daemonSpawnAttempted = false
        spawnBundledDaemonOnce()
    }

    private static func listenerPid(port: Int) -> Int? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-tiTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: "\n").first.flatMap { Int($0) }
    }

    // MARK: - UI-4: «Memory & rollbacks»

    /// The last GET /v1/rollback/points (toggle, schedule, point list).
    @Published private(set) var rollback: RollbackPointsResponse?
    /// The last GET /v1/rollback/diff (the «Diff for a week» panel).
    @Published private(set) var rollbackDiff: RollbackDiffResponse?
    /// The last rollback/forget/diff error — shown honestly on screen.
    @Published var rollbackError: String?
    /// Rollback/forget in progress (buttons are unclickable meanwhile).
    @Published private(set) var rollbackBusy = false

    func refreshRollback() async {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/rollback/points"))
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let r = try? JSONDecoder().decode(RollbackPointsResponse.self, from: data)
        else { return }
        rollback = r
    }

    func loadRollbackDiff(days: Int = 7) async {
        var request = URLRequest(url: baseURL
            .appendingPathComponent("v1/rollback/diff")
            .appending(queryItems: [URLQueryItem(name: "days", value: String(days))]))
        request.timeoutInterval = 10
        rollbackError = nil
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let d = try? JSONDecoder().decode(RollbackDiffResponse.self, from: data)
        else { rollbackError = L("memory.diff.fail"); return }
        rollbackDiff = d
    }

    /// POST /v1/rollback {point}. The error (404 point, 409 backup off, 500)
    /// goes into rollbackError with the daemon response text — the screen shows it.
    @discardableResult
    func rollback(to point: String) async -> Bool {
        await postControl("v1/rollback", body: ["point": point])
    }

    /// POST /v1/forget {project}.
    @discardableResult
    func forget(project: String) async -> Bool {
        await postControl("v1/forget", body: ["project": project])
    }

    private func postControl(_ path: String, body: [String: Any]) async -> Bool {
        rollbackBusy = true
        defer { rollbackBusy = false }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                rollbackError = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap {
                    "\(($0["error"] as? String) ?? "HTTP \(code)")"
                } ?? "HTTP \(code)"
                return false
            }
            rollbackError = nil
            return true
        } catch {
            rollbackError = String(describing: error)
            return false
        }
    }

    // MARK: - UI-5: «Search» — accuracy benchmark

    /// The last GET /v1/benchmark (frozen benchmark + custom entries).
    @Published private(set) var benchmark: BenchmarkResponse?
    /// The last benchmark-block error (404 «no data» is a screen error too).
    @Published var benchmarkError: String?
    /// A custom benchmark add/recheck in progress.
    @Published private(set) var benchmarkBusy = false

    func refreshBenchmark() async {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/benchmark"))
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 404 {
            benchmarkError = L("search.benchmark.never")
            return
        }
        guard http.statusCode == 200,
              let b = try? JSONDecoder().decode(BenchmarkResponse.self, from: data)
        else { benchmarkError = "HTTP \(http.statusCode)"; return }
        benchmarkError = nil
        benchmark = b
    }

    /// POST /v1/benchmark/custom {question, expected_file} — add and check.
    @discardableResult
    func addCustomBenchmark(question: String, expectedFile: String) async -> Bool {
        await postBenchmark("v1/benchmark/custom",
                            body: ["question": question, "expected_file": expectedFile])
    }

    /// POST /v1/benchmark/custom/recheck — re-check all custom benchmarks.
    @discardableResult
    func recheckCustomBenchmark() async -> Bool {
        await postBenchmark("v1/benchmark/custom/recheck", body: [:])
    }

    private func postBenchmark(_ path: String, body: [String: Any]) async -> Bool {
        benchmarkBusy = true
        defer { benchmarkBusy = false }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                benchmarkError = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap {
                    "\(($0["error"] as? String) ?? "HTTP \(code)")"
                } ?? "HTTP \(code)"
                return false
            }
            benchmarkError = nil
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let custom = obj["custom"] {
                // Update the custom section on top of the last GET response:
                // the frozen benchmark numbers stay unchanged.
                if var b = benchmark {
                    b.custom = try? JSONDecoder().decode(BenchmarkResponse.Custom.self,
                                                         from: JSONSerialization.data(withJSONObject: custom))
                    benchmark = b
                } else {
                    await refreshBenchmark()
                }
            }
            return true
        } catch {
            benchmarkError = String(describing: error)
            return false
        }
    }
}

// MARK: - Helper functions for UI-3 screens

/// Path for display: the home directory collapses to ~ (as in the references).
func displayPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    if path == home { return "~" }
    return path
}

/// The number of md files in a folder (recursively, skipping hidden dirs and
/// heavy masks — this is a showcase number «what would enter the index», not an engine promise).
func countMdFiles(in path: String) -> Int {
    let fm = FileManager.default
    guard let en = fm.enumerator(at: URL(fileURLWithPath: path),
                                 includingPropertiesForKeys: [.isRegularFileKey],
                                 options: [.skipsHiddenFiles]) else { return 0 }
    var count = 0
    for case let url as URL in en {
        let dir = url.deletingLastPathComponent().lastPathComponent
        if dir == "node_modules" || dir == ".build" || dir == ".git" { en.skipDescendants(); continue }
        if url.pathExtension == "md" { count += 1 }
    }
    return count
}

/// An honest Full Disk Access check: read a TCC-protected file.
/// Without FDA FileHandle-forReading on ~/Library/Safari/Bookmarks.plist returns
/// permission denied; with FDA it opens. Read-only, we write nothing.
enum FDACheck {
    static func isGranted() -> Bool {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Safari/Bookmarks.plist")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        return (try? h.close()) != nil
    }

    /// The «Full Disk Access» pane in System Settings (HT202235).
    @MainActor
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
