// Language lock: Swift code is English-only.
// Comments, daemon/log strings, test names and identifiers must not contain
// Cyrillic; user-facing strings live EXCLUSIVELY in
// Sources/BMemApp/Resources/l10n/*.json (JSON is not scanned here).
// This test is the machine lock: it walks Sources/ and Tests/ and fails on
// any \p{Cyrillic} code point, so Cyrillic cannot silently creep back into
// .swift files. Runs as part of `swift test` (the CI pin).
import XCTest

final class EnglishOnlySourceTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/BMemCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
    }

    /// \p{Cyrillic}: basic block + supplement (the ranges ICU's script covers
    /// for the letters this codebase ever used).
    private func isCyrillic(_ scalar: Unicode.Scalar) -> Bool {
        (0x0400...0x04FF).contains(scalar.value) || (0x0500...0x052F).contains(scalar.value)
    }

    func testNoCyrillicInSwiftSources() throws {
        let fm = FileManager.default
        var offenders: [String] = []
        var scanned = 0
        for dir in ["Sources", "Tests"] {
            let base = repoRoot.appendingPathComponent(dir)
            guard let en = fm.enumerator(at: base, includingPropertiesForKeys: nil) else {
                return XCTFail("cannot walk \(base.path) — the lock lost its subject")
            }
            for case let url as URL in en where url.pathExtension == "swift" {
                scanned += 1
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                for (i, line) in text.components(separatedBy: "\n").enumerated() {
                    if line.unicodeScalars.contains(where: isCyrillic) {
                        let rel = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
                        offenders.append("\(rel):\(i + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(90))")
                    }
                }
            }
        }
        XCTAssertGreaterThan(scanned, 40, "the scan walked suspiciously few .swift files")
        XCTAssertTrue(offenders.isEmpty,
                      "Cyrillic found in \(offenders.count) Swift line(s) — code must be English-only "
                    + "(user strings go to Resources/l10n/*.json):\n"
                    + offenders.prefix(50).joined(separator: "\n"))
    }
}
