// L10N: tests for the JSON language catalog (Sources/BMemApp/Resources/l10n/).
// 1) Completeness of en/ru: the key sets are identical, values are non-empty;
//    keys of any drop-in language — a subset of en (a typo in a new file
//    must not reach a release).
// 2) All keys the code references (L/Lf/pk) exist in the en catalog.
// 3) Format placeholders %@/%ld do not diverge between ru and en.
// 4) Sections and plural families are complete.
// 5) No hardcoded Cyrillic in UI code: a scan of all *.swift without
//    exceptions for logs (logs now go through keys too); only comments and
//    an explicit i18n-ignore marker remove a line from the check.
// 6) Drop-in without a code change: <lang>.json in the catalog = a language
//    in the switcher; a missing translation — fallback en; a key nowhere —
//    a visible ??key?? marker.
import XCTest
import BMemAPI
@testable import BMemApp

final class LocalizationTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/BMemAPITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
    }
    private var appSources: URL { repoRoot.appendingPathComponent("Sources/BMemApp") }
    private var catalogDir: URL { appSources.appendingPathComponent("Resources/l10n") }

    private func loadJSON(_ lang: String) throws -> [String: String] {
        let url = catalogDir.appendingPathComponent("\(lang).json")
        let data = try Data(contentsOf: url)
        guard let flat = try JSONSerialization.jsonObject(with: data) as? [String: String]
        else { XCTFail("\(lang).json — not a flat key→value object"); throw NSError(domain: "i10n", code: 1) }
        XCTAssertFalse(flat.isEmpty, "\(lang).json is empty")
        return flat
    }

    /// Completeness: en and ru — mirrored key sets, non-empty values;
    /// any drop-in language — a subset of en.
    func testCatalogsCompleteAndDropInSubsetOfEn() throws {
        let en = try loadJSON("en"), ru = try loadJSON("ru")
        XCTAssertEqual(Set(en.keys), Set(ru.keys), "the en/ru key sets diverged")
        for (k, v) in en { XCTAssertFalse(v.isEmpty, "key \(k): empty value in en") }
        for (k, v) in ru { XCTAssertFalse(v.isEmpty, "key \(k): empty value in ru") }
        let langs = Set(L10n.loadCatalogs(from: catalogDir).keys)
        XCTAssertEqual(langs, ["en", "ru", "test"], "the catalog does not load completely")
        for (lang, kv) in L10n.loadCatalogs(from: catalogDir) where lang != "en" {
            XCTAssertFalse(kv.isEmpty, "\(lang).json is empty")
            let extra = Set(kv.keys).subtracting(en.keys)
            XCTAssertTrue(extra.isEmpty, "\(lang).json: keys absent from en: \(extra.sorted())")
        }
    }

    /// Formal catalog strings: %@/%ld are not skewed (the argument count in
    /// ru and en matches — otherwise EN would crash on String(format:)).
    func testFormatArgsMatchBetweenLanguages() throws {
        let en = try loadJSON("en"), ru = try loadJSON("ru")
        func specifiers(_ s: String) -> [String] {
            // %@, %ld, %N$@, %N$ld — the placeholder class without the position number
            try! NSRegularExpression(pattern: "%(\\d+\\$)?[@ld]")
                .matches(in: s, range: NSRange(s.startIndex..., in: s))
                .map { String(s[Range($0.range, in: s)!]).contains("@") ? "%@" : "%ld" }
                .sorted()
        }
        for key in en.keys {
            XCTAssertEqual(specifiers(ru[key] ?? ""), specifiers(en[key] ?? ""),
                           "key \(key): the ru/en placeholder sets diverged")
        }
    }

    /// Daemon lifecycle fix: the sys.model.unloaded string must carry the
    /// ACTUAL idle-unload threshold as a placeholder, not a literal. The catalog
    /// must not contain «90» (the stale threshold), and rendering with the code
    /// constant BMemTuning must yield its number in any language.
    func testModelUnloadedStringCarriesRealThreshold() throws {
        XCTAssertEqual(BMemTuning.modelIdleTimeoutSeconds, 335,
                       "the threshold constant (watchdog desync fix)")
        for (lang, cat) in [("en", try loadJSON("en")), ("ru", try loadJSON("ru"))] {
        let v = try XCTUnwrap(cat["sys.model.unloaded"], "the key vanished from \(lang)")
            XCTAssertFalse(v.contains("90"), "\(lang): a threshold literal in sys.model.unloaded: \(v)")
            XCTAssertEqual(v.components(separatedBy: "%@").count - 1, 2,
                           "\(lang): expected two placeholders (model name, threshold): \(v)")
            let rendered = String(format: v, "Gemma-2", String(BMemTuning.modelIdleTimeoutSeconds))
            XCTAssertTrue(rendered.contains("335"),
                          "\(lang): the render does not carry the threshold from the constant: \(rendered)")
        }
    }

    /// All static keys from the code exist in the en catalog.
    func testAllKeysReferencedInCodeExist() throws {
        let en = try loadJSON("en")
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: appSources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10)
        let pattern = try NSRegularExpression(pattern: #"\b(?:L|Lf)\("([^"]+)"|\.pk\("([^"]+)"|L10n\.shared\.pk\("([^"]+)"#)
        var referenced = Set<String>()
        for file in files {
            let src = try String(contentsOf: file, encoding: .utf8)
            for raw in src.components(separatedBy: "\n") {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                let line = raw.range(of: "//").map { String(raw[..<$0.lowerBound]) } ?? raw
                for m in pattern.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    for g in [1, 2, 3] {
                        let r = m.range(at: g)
                        if r.location != NSNotFound, let sw = Range(r, in: line) {
                            referenced.insert(String(line[sw]))
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(referenced.count, 100, "the scan found suspiciously few keys")
        for key in referenced {
            // Dynamic keys ("section.\(rawValue).title") are checked
            // separately (testSectionKeysExist); pluralization roots — by forms.
            if key.contains("\\(") { continue }
            if key.hasPrefix("plural.") {
                for form in [".one", ".few", ".many"] {
                    XCTAssertNotNil(en[key + form], "the code references the family \(key), the form \(form) is missing")
                }
                continue
            }
            XCTAssertNotNil(en[key], "the code references the key \(key), which is absent from the en catalog")
        }
    }

    /// Dynamic section keys (section.<id>.title/.subtitle) — all six ids from
    /// enum Section must be in the catalog in both languages.
    func testSectionKeysExist() throws {
        let en = try loadJSON("en"), ru = try loadJSON("ru")
        for id in ["whatRead", "permissions", "memory", "search", "advanced", "system"] {
            for suffix in ["title", "subtitle"] {
                let key = "section.\(id).\(suffix)"
                XCTAssertNotNil(en[key], "no \(key) in en")
                XCTAssertNotNil(ru[key], "no \(key) in ru")
            }
        }
    }

    /// Pluralization keys: every family has the full one/few/many set.
    func testPluralFamiliesComplete() throws {
        let en = try loadJSON("en")
        let families = Set(en.keys.compactMatch(prefix: "plural.", suffixes: [".one", ".few", ".many"]))
        for f in families {
            for form in [".one", ".few", ".many"] {
                XCTAssertNotNil(en["plural.\(f)\(form)"], "the family plural.\(f): no form \(form)")
            }
        }
        XCTAssertFalse(families.isEmpty)
    }

    /// There are no hardcoded strings anymore: the screen code has no Cyrillic
    /// left in literals or logs (logs moved to keys); outside comments and
    /// an explicit i18n-ignore.
    func testNoHardcodedCyrillicStringsInUI() throws {
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: appSources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let cyr = try NSRegularExpression(pattern: "\\p{Cyrillic}")
        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, raw) in lines.enumerated() {
                // The exclusion works on the RAW line: the marker lives in the
                // trailing comment which we strip below.
                if raw.contains("i18n-ignore") { continue }
                // strip the trailing/whole comment (URLs with "//" contain no
                // Cyrillic, the crude cut is safe)
                var line = raw
                if let r = line.range(of: "//") { line = String(line[..<r.lowerBound]) }
                if cyr.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    offenders.append("\(file.lastPathComponent):\(i + 1): \(raw.trimmingCharacters(in: .whitespaces).prefix(80))")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "hardcoded Cyrillic in UI code:\n" + offenders.joined(separator: "\n"))
    }

    /// Drop-in acceptance: a catalog copy + a dropped test.json — the language
    /// appears in the switcher without a code change; missing keys — fallback
    /// en; a key nowhere — a visible ??key?? marker, not a crash.
    func testDropInLanguageAppearsWithoutCodeChange() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("l10n-dropin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for lang in ["en", "ru"] {
            try FileManager.default.copyItem(
                at: catalogDir.appendingPathComponent("\(lang).json"),
                to: dir.appendingPathComponent("\(lang).json"))
        }
        // «Drop» the new language exactly as the acceptance describes: a file + 3 keys.
        try #"""
        {
          "lang.name": "Test",
          "sys.lang": "Interface language (TEST)",
          "section.system.title": "System TEST"
        }
        """#
            .write(to: dir.appendingPathComponent("test.json"), atomically: true, encoding: .utf8)

        let catalogs = L10n.loadCatalogs(from: dir)
        XCTAssertEqual(Set(catalogs.keys), ["en", "ru", "test"],
                       "the new file did not become a catalog language")

        let l = L10n(catalogs: catalogs, mode: "test")
        XCTAssertTrue(l.availableLanguages.contains("test"))
        XCTAssertTrue(l.switcherOptions.contains { $0.id == "test" && $0.title == "Test" },
                      "the switcher did not build a segment for test.json")
        XCTAssertEqual(l.displayName("ru"), "\u{0420}\u{0443}\u{0441}\u{0441}\u{043A}\u{0438}\u{0439}", "the ru endonym must come from lang.name")
        XCTAssertEqual(l.effectiveLang, "test")
        // The key is in test.json — it is taken from it.
        XCTAssertEqual(l.t("section.system.title"), "System TEST")
        // Absent from test.json — fallback to en.
        XCTAssertEqual(l.t("sys.autostart.note"), catalogs["en"]?["sys.autostart.note"])
        // Absent everywhere — a visible marker instead of a crash.
        XCTAssertEqual(l.t("no.such.key"), "??no.such.key??")
        // The language is selected but the file is gone (deleted) — fall back to system/en, no panic.
        let ghost = L10n(catalogs: catalogs, mode: "de")
        XCTAssertTrue(["en", "ru"].contains(ghost.effectiveLang))
        XCTAssertTrue(ghost.t("sys.lang").count > 0)
    }

    /// The switcher order: «System», then ru, en (the historical UI order),
    /// the other languages by code.
    func testSwitcherOrder() throws {
        let catalogs = L10n.loadCatalogs(from: catalogDir)
        let l = L10n(catalogs: catalogs, mode: "system")
        XCTAssertEqual(l.switcherOptions.map(\.id), ["system", "ru", "en", "test"])
        // The «System» title — from the current system language, not a marker.
        let sys = Locale.current.language.languageCode?.identifier ?? "en"
        let expected = (catalogs[sys] ?? catalogs["en"]!)["lang.system"]!
        XCTAssertEqual(l.switcherOptions[0].title, expected)
    }
}

private extension Sequence where Element == String {
    /// Pluralization family ids: keys of the form prefix + id + suffix.
    func compactMatch(prefix: String, suffixes: [String]) -> [String] {
        compactMap { key in
            guard key.hasPrefix(prefix) else { return nil }
            for s in suffixes where key.hasSuffix(s) {
                return String(key.dropFirst(prefix.count).dropLast(s.count))
            }
            return nil
        }
    }
}
