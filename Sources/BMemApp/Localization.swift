// L10N: languages are data, not code. The catalog lives in the resource bundle
// as the l10n/ folder (source — Sources/BMemApp/Resources/l10n/): one
// <lang>.json file per language, flat key→value. A new language = drop a file
// into the catalog — it appears in the switcher without a code change. The fallback is
// en; no key there either — a visible ??key?? marker instead of a crash. The
// local name of a language (the endonym in the switcher) is the lang.name key inside its own file.
// Localizable.xcstrings stayed solely for system strings (macOS menus);
// there are no UI strings there — the single source of truth for UI is l10n/.
// The language choice («system» → a concrete one) lives in UserDefaults and
// The language choice («system» → a concrete one) lives in UserDefaults and
// applies instantly: L10n is an ObservableObject, every screen observes it and
// redraws. Stands: --lang=<code> overrides the language for the run (not persisted).
import Foundation
import Combine

/// The catalog is immutable after init; mode is written only from the main
/// thread (UI controls), read from anywhere — UserDefaults is thread-safe.
final class L10n: ObservableObject, @unchecked Sendable {
    static let shared: L10n = {
        let catalogs = loadCatalogs()
        var mode = systemMode
        if let cli = argValue("lang"), catalogs[cli] != nil {
            mode = cli
        } else if let saved = UserDefaults.standard.string(forKey: defaultsKey),
                  saved == systemMode || catalogs[saved] != nil {
            mode = saved
        }
        return L10n(catalogs: catalogs, mode: mode)
    }()

    private static let defaultsKey = "appLanguage"
    /// The pseudo-choice «follow the system language» — the default.
    static let systemMode = "system"
    /// The donor language for missing translations.
    static let fallbackLang = "en"
    /// The order of switcher segments: ru/en first (the historical UI
    /// order), the other languages by code after them.
    private static let preferredOrder = ["ru", "en"]

    /// lang -> (key -> value), from the resource bundle l10n/<lang>.json.
    private let catalogs: [String: [String: String]]

    /// The user choice: "system" (default) or a language code from the catalog.
    @Published var mode: String {
        didSet {
            if mode != oldValue { UserDefaults.standard.set(mode, forKey: Self.defaultsKey) }
        }
    }

    init(catalogs: [String: [String: String]], mode: String) {
        self.catalogs = catalogs
        self.mode = mode
    }

    /// Available languages = the list of the catalog json files (the switcher
    /// is built from this, not from a hardcode).
    var availableLanguages: [String] {
        catalogs.keys.sorted { a, b in
            let pa = Self.preferredOrder.firstIndex(of: a) ?? Self.preferredOrder.count
            let pb = Self.preferredOrder.firstIndex(of: b) ?? Self.preferredOrder.count
            return pa != pb ? pa < pb : a < b
        }
    }

    /// The language named on itself (the endonym from its own file, the lang.name
    /// key) so it does not «disappear» on switching; no key — the language code.
    func displayName(_ lang: String) -> String {
        catalogs[lang]?["lang.name"] ?? lang
    }

    /// Language switcher options: «System» + every catalog file.
    var switcherOptions: [(id: String, title: String)] {
        [(Self.systemMode, t("lang.system"))]
            + availableLanguages.map { ($0, displayName($0)) }
    }

    /// The actual output language: the manual choice (while the file lives),
    /// otherwise the system language if it has a file, otherwise the fallback en.
    var effectiveLang: String {
        if mode != Self.systemMode, catalogs[mode] != nil { return mode }
        let sys = Locale.current.language.languageCode?.identifier ?? Self.fallbackLang
        return catalogs[sys] != nil ? sys : Self.fallbackLang
    }

    /// A string by key in the current language; no translation → en (fallback);
    /// no key anywhere → a visible ??key?? marker instead of a crash.
    func t(_ key: String) -> String {
        if let v = catalogs[effectiveLang]?[key], !v.isEmpty { return v }
        if let v = catalogs[Self.fallbackLang]?[key], !v.isEmpty { return v }
        return "??\(key)??"
    }

    /// A formatted string (the template from the catalog, arguments — %@/%ld).
    func f(_ key: String, _ args: [CVarArg]) -> String {
        let template = t(key)
        guard !args.isEmpty else { return template }
        return String(format: template, arguments: args)
    }

    /// Pluralization by the key.one/.few/.many keys (ru — three forms;
    /// in the en catalog few == many, the ru rule for them gives correct EN).
    /// The number at the start of the result is grouped with a thin space («1 272 chunks»).
    func pk(_ key: String, _ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        let form: String
        if mod10 == 1 && mod100 != 11 { form = ".one" }
        else if (2...4).contains(mod10) && !(12...14).contains(mod100) { form = ".few" }
        else { form = ".many" }
        let s = f(key + form, [n])
        let raw = String(n)
        guard s.hasPrefix(raw) else { return s }
        return Self.grouped(n) + s.dropFirst(raw.count)
    }

    /// Digits grouped with a thin space: 1 272.
    static func grouped(_ n: Int) -> String {
        let digits = String(n)
        var out = ""
        for (i, ch) in digits.reversed().enumerated() {
            if i > 0, i % 3 == 0 { out = "\u{2009}" + out }
            out = String(ch) + out
        }
        return out
    }

    // MARK: - Catalog loading

    private static func loadCatalogs() -> [String: [String: String]] {
        guard let dir = Bundle.module.url(forResource: "l10n", withExtension: nil) else {
            NSLog("BMem i18n: l10n/ not found in resource bundle — UI shows ??key?? markers")
            return [:]
        }
        return loadCatalogs(from: dir)
    }

    /// Reading the catalog from a folder: every <lang>.json is a language (flat
    /// key→value). A broken file is skipped with a log — one broken language
    /// does not crash the app nor hide the others.
    static func loadCatalogs(from dir: URL) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension.lowercased() == "json" {
            let lang = file.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: file),
                  let flat = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else {
                NSLog("BMem i18n: \(file.lastPathComponent) is not a flat key→value JSON — language skipped")
                continue
            }
            out[lang] = flat
        }
        return out
    }
}

/// A UI string by key. Everywhere a Russian literal in Text/Button/… used to be.
func L(_ key: String) -> String { L10n.shared.t(key) }

/// A UI string with arguments: Lf("key", arg1, arg2).
func Lf(_ key: String, _ args: CVarArg...) -> String { L10n.shared.f(key, args) }

/// A diagnostic log to stderr: not UI; the text is taken by key from the catalog,
/// so no Cyrillic literals remained in the code even in logs.
func stderrLog(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

/// «today 03:00» / «yesterday 03:00» / «12 Oct 03:00» — the language comes from L10n.
enum RelativeDate {
    static func label(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let date = f.date(from: iso) else { return iso }
        return label(date)
    }

    static func label(_ date: Date) -> String {
        let cal = Calendar.current
        let time = localizedTime(date)
        if cal.isDateInToday(date) { return Lf("date.today", time) }
        if cal.isDateInYesterday(date) { return Lf("date.yesterday", time) }
        let df = DateFormatter()
        df.locale = Locale(identifier: L10n.shared.effectiveLang == "ru" ? "ru_RU" : "en_US")
        let sameYear = cal.isDate(date, equalTo: Date(), toGranularity: .year)
        df.dateFormat = sameYear ? "d MMM HH:mm" : "d MMM yyyy HH:mm"
        return df.string(from: date)
    }

    private static func localizedTime(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "HH:mm"
        return df.string(from: date)
    }
}
