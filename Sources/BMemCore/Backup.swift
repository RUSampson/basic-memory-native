// UI-4: «Memory & rollbacks» — git backup of the note folders.
//
// One repository: ~/.bmem/backup, inside projects/<project-name>/<relative
// path>.md — a mirror of md files only (all of AI-projects is 22 GB on disk,
// the md notes in it are ~20 MB — git takes the memory, not build junk).
//
// Rollback points = commits of this repository. A commit once a day (03:00,
// the scheduler tick in the daemon) + before every reindex + on feature enable.
//
// Rollback to point P (the rule is agreed with the screen banner: «adds files,
// without erasing»):
//   1) a «pre-rollback» commit of the current state — the rollback is itself rollback-able;
//   2) git restore of the repo working copy to P + a «rollback to P» commit;
//   3) merge into the working folders: a file from the point is placed if the
//      target file is missing (restore of a deleted one) or unchanged since the
//      last backup (revert of edits committed after the point); files with
//      uncommitted edits (dirty — newer than any backup) are NOT touched; files
//      created after the point are never deleted.
import Foundation

public enum BackupError: Error, CustomStringConvertible {
    case notEnabled
    case unknownPoint(String)
    case projectNotFound(String)
    case gitFailed(String)

    public var description: String {
        switch self {
        case .notEnabled: return "git backup is not enabled"
        case .unknownPoint(let p): return "unknown rollback point: \(p)"
        case .projectNotFound(let p): return "project not found: \(p)"
        case .gitFailed(let m): return "git failed: \(m)"
        }
    }
}

public struct BackupManager: Sendable {
    public let backupDir: String
    public let forgottenDir: String
    public let projects: [String: String]        // name -> md-vault path
    public let excludes: [String: [String]]      // nested project roots (as the engine does)

    /// Production constructor: paths from config, excludes computed with the
    /// same computeExcludes as indexing — the mirror must match the index.
    public init(config: Config, backupDir: String? = nil, forgottenDir: String? = nil) {
        self.init(projects: config.projects,
                  excludes: Engine.computeExcludes(from: config),
                  backupDir: backupDir, forgottenDir: forgottenDir)
    }

    public init(projects: [String: String], excludes: [String: [String]] = [:],
                backupDir: String? = nil, forgottenDir: String? = nil) {
        let base = Config.bmemDir()
        self.backupDir = backupDir ?? base + "/backup"
        self.forgottenDir = forgottenDir ?? base + "/forgotten"
        self.projects = projects
        self.excludes = excludes
    }

    public var repoExists: Bool {
        FileManager.default.fileExists(atPath: backupDir + "/.git")
    }

    // MARK: - git

    /// homebrew git first: /usr/bin git on an admin machine returns exit 69
    /// without Xcode CLT (verified), homebrew git is always alive.
    static func gitPath() -> String? {
        ["/opt/homebrew/bin/git", "/usr/bin/git"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    @discardableResult
    private func git(_ args: [String]) throws -> String {
        guard let exe = Self.gitPath() else { throw BackupError.gitFailed("git binary not found") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["-C", backupDir] + args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch { throw BackupError.gitFailed(String(describing: error)) }
        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw BackupError.gitFailed("git \(args.joined(separator: " ")) -> \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return out
    }

    /// Initialization on first feature enable: init + .gitignore against junk +
    /// local commit identity (we must not touch someone else global config).
    public func ensureRepo() throws {
        if repoExists { return }
        let fm = FileManager.default
        try fm.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
        guard let exe = Self.gitPath() else { throw BackupError.gitFailed("git binary not found") }
        let initP = Process()
        initP.executableURL = URL(fileURLWithPath: exe)
        initP.arguments = ["init", "-b", "main", backupDir]
        initP.standardOutput = FileHandle.nullDevice
        initP.standardError = FileHandle.nullDevice
        do { try initP.run() } catch { throw BackupError.gitFailed(String(describing: error)) }
        initP.waitUntilExit()
        if initP.terminationStatus != 0 {  // old git without -b
            let p2 = Process()
            p2.executableURL = URL(fileURLWithPath: exe)
            p2.arguments = ["init", backupDir]
            p2.standardOutput = FileHandle.nullDevice
            p2.standardError = FileHandle.nullDevice
            try p2.run(); p2.waitUntilExit()
        }
        try """
        .DS_Store
        *.tmp
        node_modules/
        .build/
        .venv/
        __pycache__/
        *.swp

        """.write(toFile: backupDir + "/.gitignore", atomically: true, encoding: .utf8)
        _ = try git(["config", "user.name", "BMem"])
        _ = try git(["config", "user.email", "bmem@localhost"])
    }

    // MARK: - sync (backup commit)

    /// Mirrors the project md files into the working tree and commits if there is anything.
    /// Returns the HEAD hash (existing one if the tree is clean) and the change count.
    @discardableResult
    public func sync(reason: String) throws -> (commit: String, changes: Int) {
        try ensureRepo()
        try mirror()
        _ = try git(["add", "-A"])
        let status = try git(["status", "--porcelain"])
        let changes = status.split(separator: "\n").count
        if changes == 0 {
            let head = (try? git(["rev-parse", "HEAD"]))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (head, 0)
        }
        _ = try git(["commit", "-m", reason])
        let head = try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (head, changes)
    }

    /// Copy of each project md files into projects/<name>/; files gone from the
    /// source are deleted from the mirror (deletion lands in history too).
    private func mirror() throws {
        let fm = FileManager.default
        for (name, root) in projects {
            let mirrorRoot = backupDir + "/projects/" + Self.sanitize(name)
            var keep = Set<String>()
            for url in Engine.markdownFiles(in: root, excludes: excludes[name] ?? []) {
                let rel = String(url.path.dropFirst(root.hasSuffix("/") ? root.count : root.count + 1))
                keep.insert(rel)
                let dest = mirrorRoot + "/" + rel
                try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent,
                                       withIntermediateDirectories: true)
                // The source mtime is preserved by copyItem (the copy gets the
                // original mtime) — nothing is compared by it, but cp semantics is cheaper.
                if fm.fileExists(atPath: dest) { try? fm.removeItem(atPath: dest) }
                try fm.copyItem(at: url, to: URL(fileURLWithPath: dest))
            }
            // mirror cleanup: everything missing from the source (except service files)
            if fm.fileExists(atPath: mirrorRoot) {
                for rel in Self.filesUnder(mirrorRoot) where !keep.contains(rel) {
                    try? fm.removeItem(atPath: mirrorRoot + "/" + rel)
                }
            }
        }
    }

    // MARK: - rollback points

    public struct Point: Sendable {
        public let commit: String
        public let date: String       // ISO 8601 (iso-strict)
        public let author: String
        public let message: String
        public let changes: Int       // files changed in this commit
    }

    public func points(limit: Int = 30) throws -> [Point] {
        guard repoExists else { return [] }
        let out = try git(["log", "-n", String(limit), "--date=iso-strict",
                           "--pretty=format:%H\u{1f}%ad\u{1f}%an\u{1f}%s", "--numstat"])
        var points: [Point] = []
        var current: (head: [String], changes: Int)?
        for line in out.components(separatedBy: "\n") {
            if line.contains("\u{1f}") {
                if let c = current { points.append(Self.makePoint(c.head, c.changes)) }
                current = (line.components(separatedBy: "\u{1f}"), 0)
            } else if !line.isEmpty, current != nil {
                current!.changes += 1
            }
        }
        if let c = current { points.append(Self.makePoint(c.head, c.changes)) }
        return points
    }

    private static func makePoint(_ f: [String], _ changes: Int) -> Point {
        Point(commit: f[0], date: f.count > 1 ? f[1] : "", author: f.count > 2 ? f[2] : "",
              message: f.count > 3 ? f[3] : "", changes: changes)
    }

    private func commitDate(_ hash: String) -> Date? {
        guard let s = try? git(["show", "-s", "--date=iso-strict", "--format=%ad", hash])
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return Self.parseISO(s)
    }

    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: - rollback

    public struct Outcome: Sendable {
        public let preCommit: String   // the pre-rollback commit (the rollback is undone by it)
        public let restored: Int       // files restored from the point (they were missing)
        public let reverted: Int       // files reset to the point version
        public let keptNewer: Int      // files with uncommitted edits — untouched
    }

    /// Rollback to a point. The merge rule is in the file header; «newer than
    /// any backup» is computed by git diff of the working tree against HEAD
    /// BEFORE the pre-rollback commit: files changed after the last backup are left alone.
    public func rollback(to point: String) throws -> Outcome {
        try ensureRepo()
        let head0 = ((try? git(["rev-parse", "--verify", "\(point)^{commit}"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        guard head0.count >= 7 else { throw BackupError.unknownPoint(point) }
        let short = String(head0.prefix(7))
        // 1) mirror of the current state + the set of edits after the last
        //    backup (compare the working tree with HEAD before the commit —
        //    otherwise the pre-rollback commit would hide them)
        try mirror()
        let dirty = Set((try? git(["diff", "--name-only", "HEAD"]))?
            .split(separator: "\n").map(String.init) ?? [])
        // 2) the pre-rollback commit — always, empty on a clean tree: the
        //    «state before rollback» marker must be in history for any rollback
        _ = try git(["add", "-A"])
        if try git(["status", "--porcelain"]).isEmpty {
            _ = try git(["commit", "--allow-empty", "-m", "pre-rollback before \(short) (no changes)"])
        } else {
            _ = try git(["commit", "-m", "pre-rollback before \(short)"])
        }
        let preCommit = try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        // 3) checkout of the point into the working tree + commit (history stays linear)
        let hasProjects = !(try git(["ls-tree", "--name-only", head0, "projects/"]))
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasProjects {
            _ = try git(["restore", "--source=\(head0)", "--staged", "--worktree", "--", "projects"])
        }
        _ = try git(["commit", "--allow-empty", "-m", "rollback to \(short)"])
        // 4) merge into the project working folders
        var restored = 0, reverted = 0, kept = 0
        let fm = FileManager.default
        for (name, root) in projects {
            let mirrorRelDir = "projects/" + Self.sanitize(name)
            let mirrorRoot = backupDir + "/" + mirrorRelDir
            guard fm.fileExists(atPath: mirrorRoot) else { continue }
            for rel in Self.filesUnder(mirrorRoot) {
                let file = mirrorRoot + "/" + rel
                let dest = root + "/" + rel
                let repoRel = mirrorRelDir + "/" + rel
                if !fm.fileExists(atPath: dest) {
                    try Self.copy(file, to: dest)
                    restored += 1
                } else if dirty.contains(repoRel) {
                    kept += 1   // an edit newer than any backup — leave it alone
                } else {
                    try Self.copy(file, to: dest)
                    reverted += 1
                }
            }
        }
        return Outcome(preCommit: preCommit, restored: restored, reverted: reverted, keptNewer: kept)
    }

    // MARK: - diff over a window

    public struct DiffFile: Sendable {
        public let path: String
        public let added: Int
        public let deleted: Int
    }

    /// Changes from the state before the window first commit to HEAD.
    public func diff(days: Int) throws -> (commits: Int, files: [DiffFile]) {
        guard repoExists else { return (0, []) }
        let out = try git(["log", "--since=\(days) days ago", "--format=%H"])
        let hashes = out.split(separator: "\n").map(String.init)
        guard let oldest = hashes.last else { return (0, []) }
        let base: String
        // the parent of the oldest window commit — the «before window» point;
        // the root commit has no parent, compare with the empty tree (the
        // canonical git empty-tree sha1, the diff includes the first commit whole)
        if (try? git(["rev-parse", "--verify", "--quiet", "\(oldest)^"])) != nil {
            base = "\(oldest)^"
        } else {
            base = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        }
        let numstat = (try? git(["diff", "--numstat", base, "HEAD"])) ?? ""
        var files: [DiffFile] = []
        for line in numstat.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 3 else { continue }
            files.append(DiffFile(path: String(f[2]),
                                  added: Int(f[0]) ?? 0, deleted: Int(f[1]) ?? 0))
        }
        return (hashes.count, files)
    }

    // MARK: - forget project

    /// Moves the project md files to ~/.bmem/forgotten/<name>-<stamp>/ keeping
    /// the structure. The index and config are cleaned by the caller (Engine/ControlAPI).
    public func archiveProject(_ name: String) throws -> (archivedTo: String, files: Int) {
        guard let root = projects[name],
              FileManager.default.fileExists(atPath: root) else {
            throw BackupError.projectNotFound(name)
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let dest = forgottenDir + "/" + Self.sanitize(name) + "-" + fmt.string(from: Date())
        let fm = FileManager.default
        try fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
        var moved = 0
        for url in Engine.markdownFiles(in: root, excludes: excludes[name] ?? []) {
            let rel = String(url.path.dropFirst(root.hasSuffix("/") ? root.count : root.count + 1))
            let target = dest + "/" + rel
            try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: url, to: URL(fileURLWithPath: target))
            moved += 1
        }
        return (dest, moved)
    }

    // MARK: - scheduler «once a day at 03:00»

    /// A tick every N minutes from the daemon: if enabled and today 03:00 has
    /// arrived and there is no commit after it yet — commit. Missed 03:00 (the
    /// daemon was down) are caught up by the first tick after the time arrives.
    @discardableResult
    public func dailyTick(now: Date = Date()) throws -> (commit: String, changes: Int)? {
        try ensureRepo()
        let cutoff = Calendar.current.date(bySettingHour: 3, minute: 0, second: 0, of: now) ?? now
        if let last = lastCommitDate(), last >= cutoff { return nil }
        if lastCommitDate() == nil && now < cutoff {
            // no commits at all and 03:00 has not arrived — enabling the feature
            // makes the first commit itself, the scheduler must not duplicate it
            return nil
        }
        if now < cutoff { return nil }
        return try sync(reason: "daily auto-backup")
    }

    public func lastCommitDate() -> Date? {
        guard repoExists,
              let s = try? git(["log", "-1", "--date=iso-strict", "--format=%ad"])
                .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty
        else { return nil }
        return Self.parseISO(s)
    }

    // MARK: - misc

    static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "_")
    }

    /// Relative paths of all files under a directory (hidden ones skipped).
    /// IMPORTANT: the string enumerator — the URL version returns canonical
    /// paths (/tmp -> /private/tmp), and any prefix difference with backupDir
    /// breaks the rel computation (on this the mirror cleanup rule ate just-
    /// copied files; caught by tests on 15.10).
    static func filesUnder(_ dir: String) -> [String] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: dir) else { return [] }
        var out: [String] = []
        for case let p as String in en {
            if p.hasPrefix(".") || p.contains("/.") { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir + "/" + p, isDirectory: &isDir), !isDir.boolValue
            else { continue }
            out.append(p)
        }
        return out.sorted()
    }

    static func copy(_ src: String, to dest: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
        try fm.copyItem(atPath: src, toPath: dest)
    }
}
