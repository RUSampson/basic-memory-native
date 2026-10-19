// UI-5: XCTest for the Keychain wrapper (save/read/delete), the strictness
// mapping of the Search slider → /v1/search and the golden DTO mapping of the
// accuracy benchmark. The tests create Keychain items under their own bundle
// id (xctest) with unique accounts — the dev app production record is untouched,
// parallel runs do not collide.
import XCTest
import BMemAPI

final class KeychainAndStrictnessTests: XCTestCase {

    // MARK: - Keychain wrapper (Security framework)

    /// A unique account per run: no dependence on leftovers of past runs.
    private func testAccount() -> String { "test-\(UUID().uuidString)" }

    func testKeychainSaveReadDeleteRoundTrip() throws {
        let account = testAccount()
        defer { try? BMemKeychain.delete(account: account) }

        XCTAssertNil(try BMemKeychain.read(account: account), "a fresh account must not exist")

        try BMemKeychain.save(account: account, value: "key-123")
        XCTAssertEqual(try BMemKeychain.read(account: account), "key-123")

        // Saving the same account again — an update, not a duplicate and not an error.
        try BMemKeychain.save(account: account, value: "key-456")
        XCTAssertEqual(try BMemKeychain.read(account: account), "key-456")

        let existed = try BMemKeychain.delete(account: account)
        XCTAssertTrue(existed, "delete must report that the item existed")
        XCTAssertNil(try BMemKeychain.read(account: account))

        let again = try BMemKeychain.delete(account: account)
        XCTAssertFalse(again, "delete of a missing item — false, not an exception")
    }

    func testKeychainUnicodeAndLongValues() throws {
        let account = testAccount()
        defer { try? BMemKeychain.delete(account: account) }
        let long = String(repeating: "πü", count: 500)
        try BMemKeychain.save(account: account, value: long)
        XCTAssertEqual(try BMemKeychain.read(account: account), long)
    }

    func testGenerateAPIKeyShape() {
        let key = BMemKeychain.generateAPIKey()
        XCTAssertEqual(key.count, 40, "20 bytes of hex = 40 characters")
        XCTAssertTrue(key.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                      "the key must be lowercase hex: \(key)")
        XCTAssertNotEqual(BMemKeychain.generateAPIKey(), BMemKeychain.generateAPIKey(),
                          "two consecutive generations must not match")
    }

    // MARK: - Strictness mapping (slider 0..1 -> /v1/search strictness)

    func testStrictnessClampsAndRounds() {
        XCTAssertEqual(StrictnessMapping.queryValue(slider: -0.5), 0)
        XCTAssertEqual(StrictnessMapping.queryValue(slider: 1.5), 1)
        XCTAssertEqual(StrictnessMapping.queryValue(slider: 0.69999), 0.7, accuracy: 0.0001)
        XCTAssertEqual(StrictnessMapping.queryValue(slider: 0.304), 0.30, accuracy: 0.0001)
    }

    func testStrictnessMonotonic() {
        var previous = -1.0
        for step in 0...100 {
            let v = StrictnessMapping.queryValue(slider: Double(step) / 100)
            XCTAssertGreaterThanOrEqual(v, previous, "the mapping must be non-decreasing")
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThanOrEqual(v, 1)
            previous = v
        }
    }

    func testStrictnessQueryItemRoundTrip() throws {
        // The query-string value must parse back by the daemon (0..1, dot separator).
        for slider in [0.0, 0.3, 0.7, 1.0, 0.456] {
            let item = StrictnessMapping.queryItem(slider: slider)
            XCTAssertFalse(item.contains(","), "only a dot in the query string: \(item)")
            let parsed = try XCTUnwrap(Double(item))
            XCTAssertEqual(parsed, StrictnessMapping.queryValue(slider: slider), accuracy: 0.0001)
        }
        XCTAssertEqual(StrictnessMapping.queryItem(slider: 1), "1.0")
        XCTAssertEqual(StrictnessMapping.queryItem(slider: 0), "0.0")
    }

    // MARK: - Golden benchmark DTO (GET /v1/benchmark with the custom section)

    func testBenchmarkGoldenMapping() throws {
        let json = """
        {
          "engine": "gemma", "total": 70, "hit": 58,
          "run_date": "2026-10-14", "source": "run-2026-10-14-metrics.json",
          "custom": {
            "total": 2, "hit": 1,
            "entries": [
              {"id": "a1", "question": "coffee maker", "expected_file": "human1.md",
               "last_check": {"hit": true, "top1": "/vault/notes/human1.md",
                              "checked_at": "2026-10-15T12:00:00Z"}},
              {"id": "a2", "question": "no such thing", "expected_file": "x.md",
               "last_check": {"hit": false, "top1": null,
                              "checked_at": "2026-10-15T12:00:01Z"}}
            ]
          }
        }
        """
        let b = try JSONDecoder().decode(BenchmarkResponse.self, from: Data(json.utf8))
        XCTAssertEqual(b.total, 70)
        XCTAssertEqual(b.hit, 58)
        XCTAssertEqual(b.custom?.total, 2)
        XCTAssertEqual(b.custom?.hit, 1)
        let entries = try XCTUnwrap(b.custom?.entries)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].last_check?.hit, true)
        XCTAssertEqual(entries[0].last_check?.top1, "/vault/notes/human1.md")
        XCTAssertNil(entries[1].last_check?.top1, "top1: null must decode to nil")
    }

    func testBenchmarkWithoutCustomDecodes() throws {
        // The daemon response before UI-5 (without the custom section) must decode —
        // the facade does not crash on an old daemon.
        let json = #"{"engine":"gemma","total":70,"hit":58,"run_date":"","source":"run.json"}"#
        let b = try JSONDecoder().decode(BenchmarkResponse.self, from: Data(json.utf8))
        XCTAssertNil(b.custom)
    }
}
