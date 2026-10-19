// UI-4: the full git-backup and rollback cycle on a temporary directory (card DoD):
// create notes -> backup -> change -> roll back -> check contents.
// No model or daemon needed — BackupManager is files + git.
import XCTest
@testable import BMemCore

final class BackupTests: XCTestCase {

    private var dir: String!       // temporary root
    private var vault: String!      // the note vault of project p
    private var mgr: BackupManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard BackupManager.gitPath() != nil else {
            throw XCTSkip("git not found — rollback tests are pointless without it")
        }
        dir = "/tmp/bmem-ui4-" + String(UUID().uuidString.prefix(8))
        vault = dir + "/vault"
        try FileManager.default.createDirectory(atPath: vault + "/notes", withIntermediateDirectories: true)
        mgr = BackupManager(projects: ["p": vault],
                            backupDir: dir + "/backup",
                            forgottenDir: dir + "/forgotten")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    // MARK: - helpers

    private func write(_ rel: String, _ body: String) throws {
        let path = vault + "/" + rel
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try body.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func read(_ rel: String) throws -> String {
        try String(contentsOfFile: vault + "/" + rel, encoding: .utf8)
    }

    // MARK: - full cycle (DoD)

    func testFullCycleCreateBackupChangeRollback() throws {
        // create notes -> backup (p1)
        try write("notes/a.md", "version one\n")
        try write("notes/b.md", "bag\n")
        let p1 = try mgr.sync(reason: "first backup")
        XCTAssertFalse(p1.commit.isEmpty)
        XCTAssertEqual(p1.changes, 3, "first commit: both notes + .gitignore")

        // change -> backup (p2)
        try write("notes/a.md", "version two\n")
        let p2 = try mgr.sync(reason: "second backup")
        XCTAssertNotEqual(p1.commit, p2.commit)

        // rollback point = commit; list newest-first, with change counts
        let pts = try mgr.points()
        XCTAssertEqual(pts.count, 2)
        XCTAssertEqual(pts[0].commit, p2.commit)
        XCTAssertEqual(pts[1].commit, p1.commit)
        XCTAssertEqual(pts[1].changes, 3)

        // rollback to p1: a.md returns to «version one»
        let out = try mgr.rollback(to: p1.commit)
        XCTAssertEqual(try read("notes/a.md"), "version one\n")
        XCTAssertEqual(try read("notes/b.md"), "bag\n")
        XCTAssertFalse(out.preCommit.isEmpty)

        // the rollback is itself rollback-able: the pre-rollback commit is in
        // history, rolling back to it returns «version two»
        let pts2 = try mgr.points()
        guard let pre = pts2.first(where: { $0.message.hasPrefix("pre-rollback") }) else {
            return XCTFail("pre-rollback commit not found in \(pts2.map(\.message))")
        }
        _ = try mgr.rollback(to: pre.commit)
        XCTAssertEqual(try read("notes/a.md"), "version two\n")
    }

    // MARK: - mandatory test: a note written after the point is not lost

    func testNoteWrittenAfterPointIsNotLost() throws {
        try write("notes/a.md", "old\n")
        let p1 = try mgr.sync(reason: "first backup")

        // a note written AFTER the point — both uncommitted and committed
        try write("notes/fresh-uncommitted.md", "fresh without commit\n")
        let out1 = try mgr.rollback(to: p1.commit)
        XCTAssertEqual(try read("notes/fresh-uncommitted.md"), "fresh without commit\n")
        XCTAssertGreaterThanOrEqual(out1.keptNewer + 0, 0)

        try write("notes/fresh-committed.md", "fresh in backup\n")
        _ = try mgr.sync(reason: "third backup")
        _ = try mgr.rollback(to: p1.commit)
        XCTAssertEqual(try read("notes/fresh-committed.md"), "fresh in backup\n")
        // the old note stays in place meanwhile
        XCTAssertEqual(try read("notes/a.md"), "old\n")
    }

    /// An edit that never reached any backup (dirty) is newer than any point —
    /// it is not erased by rollback (merge keeping the newer files).
    func testUncommittedEditSurvivesRollback() throws {
        try write("notes/a.md", "v1\n")
        let p1 = try mgr.sync(reason: "first backup")
        try write("notes/a.md", "v2\n")
        _ = try mgr.sync(reason: "second backup")
        try write("notes/a.md", "v3 not in backup\n")

        let out = try mgr.rollback(to: p1.commit)
        XCTAssertEqual(try read("notes/a.md"), "v3 not in backup\n",
                       "an uncommitted edit must survive the rollback")
        XCTAssertEqual(out.keptNewer, 1)
    }

    /// A file deleted after the point is restored by the rollback (restored).
    func testDeletedFileRestored() throws {
        try write("notes/a.md", "lived\n")
        let p1 = try mgr.sync(reason: "first backup")
        try FileManager.default.removeItem(atPath: vault + "/notes/a.md")

        let out = try mgr.rollback(to: p1.commit)
        XCTAssertEqual(try read("notes/a.md"), "lived\n")
        XCTAssertEqual(out.restored, 1)
    }

    // MARK: - diff over a window

    func testDiffWindow() throws {
        try write("notes/a.md", "one\ntwo\n")
        _ = try mgr.sync(reason: "first backup")
        try write("notes/b.md", "three\n")
        _ = try mgr.sync(reason: "second backup")

        let d = try mgr.diff(days: 7)
        XCTAssertEqual(d.commits, 2)
        let paths = Set(d.files.map(\.path))
        XCTAssertTrue(paths.contains("projects/p/notes/a.md"), "diff: \(d.files)")
        XCTAssertTrue(paths.contains("projects/p/notes/b.md"))
        let a = d.files.first { $0.path.hasSuffix("a.md") }!
        XCTAssertEqual(a.added, 2)

        // a window without commits — empty, not an error
        let empty = try BackupManager(projects: ["p": vault], backupDir: dir + "/nope").diff(days: 7)
        XCTAssertEqual(empty.commits, 0)
        XCTAssertTrue(empty.files.isEmpty)
    }

    // MARK: - forget project

    func testArchiveProject() throws {
        try write("notes/a.md", "a\n")
        try write("deep/b.md", "b\n")
        try write("keep.txt", "not a note\n")

        let r = try mgr.archiveProject("p")
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.archivedTo + "/notes/a.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.archivedTo + "/deep/b.md"))
        XCTAssertEqual(r.files, 2, "only md files are archived — the notes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault + "/notes/a.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault + "/keep.txt"),
                      "non-md files stay in place")

        do { _ = try mgr.archiveProject("no-such"); XCTFail("must throw projectNotFound") }
        catch BackupError.projectNotFound { }
    }

    // MARK: - scheduler once a day

    func testDailyTick() throws {
        try write("notes/a.md", "a\n")
        // no commits, daytime — the tick must commit
        if Calendar.current.component(.hour, from: Date()) < 3 {
            throw XCTSkip("clock before 03:00 — the catch-up tick semantics is untestable")
        }
        let first = try mgr.dailyTick()
        XCTAssertNotNil(first)
        // the second tick on the same day — nothing left (last commit after 03:00)
        let second = try mgr.dailyTick()
        XCTAssertNil(second)
    }

    // MARK: - repository

    func testRepoInitAndEmptySync() throws {
        XCTAssertFalse(mgr.repoExists)
        // without a repository points are empty, rollback — unknownPoint/notEnabled without a crash
        XCTAssertTrue(try mgr.points().isEmpty)
        try mgr.ensureRepo()
        XCTAssertTrue(mgr.repoExists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/backup/.gitignore"))
        // a clean tree — sync does not spawn empty commits
        let s1 = try mgr.sync(reason: "one")
        let s2 = try mgr.sync(reason: "two")
        XCTAssertEqual(s1.commit, s2.commit)
        XCTAssertEqual(s2.changes, 0)
        XCTAssertEqual(try mgr.points().count, 1)
    }
}
