// UI-6: hotkey panel logic tests — hotkey string parsing, mapping of
// /v1/search results to panel rows, 200 ms debounce. The panel core
// (PanelSearchModel) is UI-free and injects fetch — the stub is below.
import XCTest
@testable import BMemAPI

final class HotkeyParserTests: XCTestCase {
    func testDefaultAndConfiguredCombos() {
        // The task default: ⌥Space = optionKey(0x0800) + 49.
        let d = HotkeyParser.parse("⌥Space")
        XCTAssertEqual(d?.carbonModifiers, 0x0800)
        XCTAssertEqual(d?.keyCode, 49)
        XCTAssertEqual(d?.display, "⌥Space")

        // The UI-5 recorder format: ⇧⌘Space = shift|cmd (0x0300) + 49.
        let s = HotkeyParser.parse("⇧⌘Space")
        XCTAssertEqual(s?.carbonModifiers, 0x0300)
        XCTAssertEqual(s?.keyCode, 49)

        // All four modifiers + a letter: the order in the string does not matter.
        let k = HotkeyParser.parse("⌘K⌥⌃⇧")
        XCTAssertEqual(k?.carbonModifiers, 0x1B00)
        XCTAssertEqual(k?.keyCode, 40)  // K
        XCTAssertEqual(k?.display, "⌃⌥⇧⌘K")
    }

    func testNamedKeysAndDigits() {
        XCTAssertEqual(HotkeyParser.parse("⌘Return")?.keyCode, 36)
        XCTAssertEqual(HotkeyParser.parse("⌃Tab")?.keyCode, 48)
        XCTAssertEqual(HotkeyParser.parse("⌘↑")?.keyCode, 126)
        XCTAssertEqual(HotkeyParser.parse("⌃1")?.keyCode, 18)
    }

    func testRejectsBareAndGarbage() {
        XCTAssertNil(HotkeyParser.parse("Space"))     // no modifier
        XCTAssertNil(HotkeyParser.parse(""))          // empty
        XCTAssertNil(HotkeyParser.parse("⌘Ç"))        // a key outside the Latin map
        XCTAssertNil(HotkeyParser.parse("⌘Notakey"))
    }

    func testResolveFallsBackToDefault() {
        // Empty/nil config — the default ⌥Space without the «broken value» flag.
        let empty = HotkeyParser.resolve(configValue: "")
        XCTAssertEqual(empty.hotkey.display, "⌥Space")
        XCTAssertFalse(empty.fellBack)

        // A broken string — the default too, but fellBack=true (a reason for a log).
        let bad = HotkeyParser.resolve(configValue: "⌘Ç")
        XCTAssertEqual(bad.hotkey.display, "⌥Space")
        XCTAssertTrue(bad.fellBack)

        // A valid config value — no fallback.
        let good = HotkeyParser.resolve(configValue: "⇧⌘Space")
        XCTAssertEqual(good.hotkey.keyCode, 49)
        XCTAssertFalse(good.fellBack)
    }
}

final class PanelRowMappingTests: XCTestCase {
    private func result(title: String, score: Double, source: String,
                        kind: String?, mtime: String?) -> PanelSearchResponse.Result {
        .init(title: title, permalink: "p/\(title)", content: "body",
              score: score, file_path: "/tmp/\(title).md", source: source,
              kind: kind, mtime: mtime)
    }

    func testScoreFormatting() {
        XCTAssertEqual(PanelRowMapper.scoreText(0.7849), "0.78")
        XCTAssertEqual(PanelRowMapper.scoreText(1.0), "1.00")
        XCTAssertEqual(PanelRowMapper.scoreText(-0.2), "0.00")
    }

    func testRowsCarryRawFields() throws {
        // UI-8: PanelRow keeps the raw kind/source/mtime — the caption is built
        // by the app in the current language, BMemAPI is language-independent.
        let rows = PanelRowMapper.rows(from: [
            result(title: "s", score: 0.5, source: "agent", kind: "session", mtime: "2026-10-14T09:00:00Z"),
            result(title: "n", score: 0.5, source: "human", kind: "note", mtime: nil),
        ])
        XCTAssertEqual(rows[0].kind, "session")
        XCTAssertEqual(rows[0].source, "agent")
        XCTAssertEqual(rows[0].mtime, "2026-10-14T09:00:00Z")
        XCTAssertNil(rows[1].mtime)
    }

    func testPanelDateRuAndEn() throws {
        // Noon Europe/Moscow — the date does not shift across days in any
        // test-runner timezone.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
        XCTAssertEqual(PanelDate.text(date, lang: "ru", now: now), "14 \u{043E}\u{043A}\u{0442}")
        XCTAssertEqual(PanelDate.text(date, lang: "en", now: now), "Oct 14")
        // A foreign year — the date carries the year so a bare day+month in January does not lie.
        let old = cal.date(from: DateComponents(year: 2025, month: 10, day: 14))!
        XCTAssertEqual(PanelDate.text(old, lang: "ru", now: now), "14 \u{043E}\u{043A}\u{0442} 2025")
        XCTAssertEqual(PanelDate.text(old, lang: "en", now: now), "Oct 14, 2025")
    }

    func testPanelDateParseISO() {
        XCTAssertNotNil(PanelDate.parse("2026-10-14T09:00:00Z"))
        XCTAssertNotNil(PanelDate.parse("2026-10-14"))
        XCTAssertNil(PanelDate.parse("not a date"))
    }

    func testGoldenDecodeAndRows() throws {
        // A slice of the real /v1/search response after UI-6 (kind + mtime).
        let json = """
        {"query":"crash","project":"ai-projects","trust":"all","results":[
          {"title":"FIX-6: crash under memory pressure","permalink":"fix/6",
           "content":"...","score":0.78,"file_path":"/x/fix6.md","source":"agent",
           "kind":"session","mtime":"2026-10-14T09:00:00Z"},
          {"title":"Canon: model unload","permalink":"canon/1",
           "content":"...","score":0.743,"file_path":"/x/canon.md","source":"human",
           "kind":"note","mtime":null}]}
        """
        let resp = try JSONDecoder().decode(PanelSearchResponse.self, from: Data(json.utf8))
        let rows = PanelRowMapper.rows(from: resp.results)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].scoreText, "0.78")
        XCTAssertEqual(rows[0].title, "FIX-6: crash under memory pressure")
        XCTAssertEqual(rows[0].kind, "session")
        XCTAssertEqual(rows[0].source, "agent")
        XCTAssertEqual(rows[0].mtime, "2026-10-14T09:00:00Z")
        XCTAssertEqual(rows[1].kind, "note")
        XCTAssertNil(rows[1].mtime)
        XCTAssertEqual(rows[1].filePath, "/x/canon.md")
    }
}

@MainActor
final class PanelSearchDebounceTests: XCTestCase {
    nonisolated private func response(_ q: String, hits: Int) -> PanelSearchResponse {
        PanelSearchResponse(query: q, project: "p", trust: "all",
                            results: (0..<hits).map {
                                .init(title: "n\($0)", permalink: "p/\($0)", content: "",
                                      score: 0.5, file_path: "/t/\($0).md", source: "human",
                                      kind: "note", mtime: nil)
                            })
    }

    /// Debounce 200 ms: three quick edits -> exactly one fetch with the last string.
    func testDebounceCollapsesBurst() async throws {
        let model = PanelSearchModel()
        actor Box { var queries: [String] = []; func add(_ s: String) { queries.append(s) } }
        let box = Box()
        model.fetch = { q, _ in
            await box.add(q)
            return self.response(q, hits: 2)
        }
        model.setQuery("c")
        model.setQuery("cr")
        model.setQuery("crash")
        try await Task.sleep(for: .milliseconds(600))
        let queries = await box.queries
        XCTAssertEqual(queries, ["crash"], "the debounce must collapse the burst of edits")
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertNotNil(model.lastLatencyMs)
        XCTAssertGreaterThanOrEqual(model.lastLatencyMs ?? 0, 0)
    }

    /// An empty field — do not knock at the daemon and clear the rows.
    func testEmptyQueryNoFetch() async throws {
        let model = PanelSearchModel()
        model.fetch = { [self] q, _ in response(q, hits: 1) }
        model.setQuery("crash")
        model.searchNow()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.rows.count, 1)
        model.setQuery("   ")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.fetchCount, 1, "fetch must not be called for an empty query")
    }

    /// A trust change restarts the search immediately with the current query.
    func testTrustChangeRefetches() async throws {
        let model = PanelSearchModel()
        actor Box { var trusts: [String] = []; func add(_ s: String) { trusts.append(s) } }
        let box = Box()
        model.fetch = { q, t in
            await box.add(t)
            return self.response(q, hits: 1)
        }
        model.setQuery("crash")
        model.searchNow()
        try await Task.sleep(for: .milliseconds(300))
        model.setTrust("agent")
        try await Task.sleep(for: .milliseconds(400))
        let trusts = await box.trusts
        XCTAssertEqual(trusts, ["all", "agent"])
    }

    /// A transport error — rows are empty, the error is visible (the panel does not lie).
    func testFetchErrorSurfaces() async throws {
        let model = PanelSearchModel()
        model.fetch = { _, _ in throw URLError(.cannotConnectToHost) }
        model.setQuery("crash")
        model.searchNow()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNotNil(model.lastError)
    }

    /// Up/down: wrap-around at the edges; after a new response the selection resets to 0.
    func testSelectionCycles() async throws {
        let model = PanelSearchModel()
        model.fetch = { [self] q, _ in response(q, hits: 3) }
        model.setQuery("q")
        model.searchNow()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.rows.count, 3)
        XCTAssertEqual(model.selection, 0)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selection, 1)
        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selection, 0, "from the last row — to the first")
        model.moveSelection(by: -1)
        XCTAssertEqual(model.selection, 2, "from the first up — to the last")
        XCTAssertEqual(model.selectedRow?.permalink, "p/2")
        // A new response — the selection is on the first row again.
        model.searchNow()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.selection, 0)
    }
}
