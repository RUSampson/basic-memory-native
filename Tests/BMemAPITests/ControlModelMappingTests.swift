// UI-3: XCTest for the mapping of BMemAPI models (DaemonStatus / DaemonConfig).
// The golden JSONs are taken verbatim from docs/control-api.md (UI-1) — if the
// daemon changes a field and docs/models drift apart, the test fails here, not in the UI.
// Live decoding of stand :18123 responses lives in ControlAPITests
// (testLiveStatus/ConfigDecodesIntoUIModels) so no second daemon is started.
import XCTest
import BMemAPI

final class ControlModelMappingTests: XCTestCase {

    // MARK: - GET /v1/status

    private let statusJSON = """
    {
      "version": "1.1.2-beta3",
      "engine": "embeddinggemma-2",
      "engine_dim": 768,
      "model_loaded": false,
      "memory_mb": 5.2,
      "memory_limit_mb": 8192,
      "autostart": false,
      "lan_access": false,
      "telemetry": false,
      "index": {
        "total_chunks": 1284,
        "total_notes": 312,
        "indexed": 312,
        "open": 1,
        "failed": 0,
        "dirty": false,
        "projects": [
          {"name": "hermes", "notes": 151, "chunks": 903, "open": 1, "failed": 0,
           "indexed_at": "2026-10-15T08:30:12Z"}
        ]
      }
    }
    """

    func testStatusGoldenMapping() throws {
        let s = try JSONDecoder().decode(DaemonStatus.self, from: Data(statusJSON.utf8))
        XCTAssertEqual(s.version, "1.1.2-beta3")
        XCTAssertEqual(s.engine, "embeddinggemma-2")
        XCTAssertEqual(s.engine_dim, 768)
        XCTAssertEqual(s.model_loaded, false)
        XCTAssertEqual(try XCTUnwrap(s.memory_mb), 5.2, accuracy: 0.001)
        XCTAssertEqual(s.memory_limit_mb, 8192)
        XCTAssertEqual(s.autostart, false)
        XCTAssertEqual(s.lan_access, false)
        XCTAssertEqual(s.telemetry, false)
        XCTAssertEqual(s.index?.total_chunks, 1284)
        XCTAssertEqual(s.index?.total_notes, 312)
        // Index reporting: three separate numbers + dirty map into the facade model
        XCTAssertEqual(s.index?.indexed, 312)
        XCTAssertEqual(s.index?.open, 1)
        XCTAssertEqual(s.index?.failed, 0)
        XCTAssertEqual(s.index?.dirty, false)
        let p = try XCTUnwrap(s.index?.projects?.first)
        XCTAssertEqual(p.name, "hermes")
        XCTAssertEqual(p.notes, 151)
        XCTAssertEqual(p.chunks, 903)
        XCTAssertEqual(p.open, 1)
        XCTAssertEqual(p.failed, 0)
        XCTAssertEqual(p.indexed_at, "2026-10-15T08:30:12Z")
    }

    func testStatusWithoutMetricFieldsDecodesForOldDaemon() throws {
        // Daemon 1.1.1-beta1 without index reporting: the new keys are absent — the model
        // must decode them as nil, not fail (the facade then shows the old line).
        var obj = (try JSONSerialization.jsonObject(with: Data(statusJSON.utf8)) as? [String: Any])!
        var index = obj["index"] as? [String: Any] ?? [:]
        for k in ["indexed", "open", "failed", "dirty"] { index.removeValue(forKey: k) }
        var proj = (index["projects"] as? [[String: Any]])?.first ?? [:]
        proj.removeValue(forKey: "open"); proj.removeValue(forKey: "failed")
        index["projects"] = [proj]
        obj["index"] = index
        let s = try JSONDecoder().decode(DaemonStatus.self,
                                         from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertEqual(s.index?.total_notes, 312)
        XCTAssertNil(s.index?.indexed)
        XCTAssertNil(s.index?.open)
        XCTAssertNil(s.index?.failed)
        XCTAssertNil(s.index?.dirty)
        XCTAssertNil(s.index?.projects?.first?.open)
    }

    func testStatusNullIndexedAtDecodesAsNil() throws {
        // Documented case: indexed_at: null — the project was never indexed.
        let json = statusJSON.replacingOccurrences(
            of: "\"indexed_at\": \"2026-10-15T08:30:12Z\"", with: "\"indexed_at\": null")
        let s = try JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
        XCTAssertNil(s.index?.projects?.first?.indexed_at)
    }

    // MARK: - GET/PUT /v1/config

    private let configJSON = """
    {
      "projects": {"hermes": "/Users/me/Documents/AI-projects/memory/hermes"},
      "default_project": "hermes",
      "min_similarity": 0.3,
      "exclude_dirs": [],
      "engine": "gemma",
      "memory_limit_mb": 8192,
      "lan_access": false,
      "telemetry": false,
      "hotkey": "",
      "launch_at_login": false,
      "auto_backup": false,
      "never_touch": ["~/.ssh", "~/.gnupg", "~/secrets", "~/Library/Keychains",
                      "~/Library/Mail", "~/Library/Caches"]
    }
    """

    func testConfigGoldenMapping() throws {
        let c = try JSONDecoder().decode(DaemonConfig.self, from: Data(configJSON.utf8))
        XCTAssertEqual(c.projects["hermes"], "/Users/me/Documents/AI-projects/memory/hermes")
        XCTAssertEqual(c.default_project, "hermes")
        XCTAssertEqual(try XCTUnwrap(c.min_similarity), 0.3, accuracy: 0.0001)
        XCTAssertEqual(c.exclude_dirs, [])
        XCTAssertEqual(c.engine, "gemma")
        XCTAssertEqual(try XCTUnwrap(c.memory_limit_mb), 8192, accuracy: 0.001)
        XCTAssertEqual(c.lan_access, false)
        XCTAssertEqual(c.telemetry, false)
        XCTAssertEqual(c.hotkey, "")
        XCTAssertEqual(c.launch_at_login, false)
        XCTAssertEqual(c.never_touch?.count, 6)
        XCTAssertEqual(c.never_touch?.first, "~/.ssh")
    }

    /// PUT — partial: the patch contains only set keys, never_touch (read-only)
    /// is never sent.
    func testPatchJSONContainsOnlySetKeys() throws {
        var c = DaemonConfig(projects: ["docs": "/tmp/docs"])
        c.launch_at_login = true
        var patch = c.patchJSON()
        XCTAssertEqual(Set(patch.keys), ["projects", "launch_at_login"])
        c.hotkey = ""            // an empty string is a valid «hotkey reset» value
        patch = c.patchJSON()
        XCTAssertEqual(patch["hotkey"] as? String, "")
        XCTAssertNil(patch["never_touch"])
        XCTAssertNil(patch["engine"])
        XCTAssertNil(patch["lan_access"])
    }

    /// The PUT response is the full config after write: same mapping as GET.
    func testConfigRoundTripsThroughEncoder() throws {
        let c = try JSONDecoder().decode(DaemonConfig.self, from: Data(configJSON.utf8))
        let back = try JSONDecoder().decode(DaemonConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(c, back)
    }

    func testAutoBackupKeyInPatchAndGolden() throws {
        // UI-4: auto_backup — in the golden config and in the PUT patch
        let c = try JSONDecoder().decode(DaemonConfig.self, from: Data(configJSON.utf8))
        XCTAssertEqual(c.auto_backup, false)
        var p = c
        p.auto_backup = true
        XCTAssertEqual(p.patchJSON()["auto_backup"] as? Bool, true)
    }

    // MARK: - UI-4: rollback points / diff

    private let pointsJSON = """
    {
      "git_backup": true,
      "auto_backup": true,
      "schedule": "every day at 03:00",
      "backup_dir": "/Users/me/.bmem/backup",
      "points": [
        {"commit": "aa11bb22cc33dd44ee55ff667788990011223344",
         "date": "2026-10-15T03:00:07+04:00", "author": "BMem",
         "message": "memory auto-backup enabled", "changes": 12},
        {"commit": "bb22cc33dd44ee55ff667788990011223344aa11",
         "date": "2026-10-14T03:00:02+04:00", "author": "BMem",
         "message": "before reindex", "changes": 3}
      ]
    }
    """

    func testRollbackPointsGoldenMapping() throws {
        let r = try JSONDecoder().decode(RollbackPointsResponse.self, from: Data(pointsJSON.utf8))
        XCTAssertEqual(r.git_backup, true)
        XCTAssertEqual(r.auto_backup, true)
        XCTAssertEqual(r.schedule, "every day at 03:00")
        let pts = try XCTUnwrap(r.points)
        XCTAssertEqual(pts.count, 2)
        XCTAssertEqual(pts[0].changes, 12)
        XCTAssertEqual(pts[0].message, "memory auto-backup enabled")
        XCTAssertEqual(pts[1].author, "BMem")
    }

    func testRollbackDiffGoldenMapping() throws {
        let json = """
        {"days": 7, "commits": 4,
         "files": [{"path": "projects/p/notes/a.md", "added": 12, "deleted": 3},
                   {"path": "projects/p/notes/b.md", "added": 0, "deleted": 1}]}
        """
        let d = try JSONDecoder().decode(RollbackDiffResponse.self, from: Data(json.utf8))
        XCTAssertEqual(d.days, 7)
        XCTAssertEqual(d.commits, 4)
        XCTAssertEqual(d.files?.count, 2)
        XCTAssertEqual(d.files?.first?.added, 12)
        XCTAssertEqual(d.files?.last?.deleted, 1)
    }
}
