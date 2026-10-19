// UI-6: global hotkey search panel (Spotlight-like).
// All logic that can be tested without a window: parsing the hotkey string from
// the config into Carbon codes, the /v1/search response DTO, mapping results to
// panel rows, 200 ms debounce. Tested by BMemAPITests; the UI (NSPanel) is in BMemApp.
import Foundation

// MARK: - Hotkey parsing

/// The hotkey string from config.hotkey (the UI-5 mini-recorder format: «⇧⌘Space»,
/// «⌥Space») -> RegisterEventHotKey parameters. Plain numbers, no Carbon types:
/// the core is testable outside the app.
public struct ParsedHotkey: Equatable {
    /// Carbon modifiers: cmdKey 0x0100, shiftKey 0x0200, optionKey 0x0800,
    /// controlKey 0x1000.
    public var carbonModifiers: UInt32
    /// Carbon virtual keycode (Space 49, Return 36, letters/digits — their own).
    public var keyCode: UInt32
    /// Normalized string for display/log (the same format as in the config).
    public var display: String
}

public enum HotkeyParser {
    /// The default hotkey when the config is empty: ⌥Space.
    public static let defaultCombo = "⌥Space"

    private static let cmdMask: UInt32 = 0x0100
    private static let shiftMask: UInt32 = 0x0200
    private static let optionMask: UInt32 = 0x0800
    private static let controlMask: UInt32 = 0x1000

    /// Named keys (match the UI-5 mini-recorder keyName).
    private static let namedKeys: [String: UInt32] = [
        "SPACE": 49, "RETURN": 36, "TAB": 48, "DELETE": 51, "ESC": 53,
        "←": 123, "→": 124, "↓": 125, "↑": 126,
    ]
    /// Uppercase letters -> Carbon keycode (US layout, as Carbon uses).
    private static let letters: [String: UInt32] = [
        "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7,
        "C": 8, "V": 9, "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16,
        "T": 17, "U": 32, "I": 34, "P": 35, "L": 37, "J": 38, "K": 40, "N": 45, "M": 46,
    ]
    private static let digits: [String: UInt32] = [
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25,
        "7": 26, "8": 28, "0": 29,
    ]

    /// Parses «⌃⌥⇧⌘+key». The modifier order in the string does not matter,
    /// Latin case does not matter. Without a modifier — nil (a bare key is
    /// never a global hotkey, the recorder never writes such a value either).
    public static func parse(_ raw: String) -> ParsedHotkey? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        var mods: UInt32 = 0
        var keyRaw = ""
        // Collect modifiers from anywhere in the string, the rest of the
        // characters are the key name (the recorder writes «modifiers+key», but
        // «⌘K⌥» must work too: modifier order is cosmetic).
        for ch in s {
            switch ch {
            case "⌘": mods |= cmdMask
            case "⇧": mods |= shiftMask
            case "⌥": mods |= optionMask
            case "⌃": mods |= controlMask
            default: keyRaw.append(ch)
            }
        }
        keyRaw = keyRaw.trimmingCharacters(in: .whitespaces)
        let keyToken = keyRaw.uppercased()
        guard mods != 0, !keyToken.isEmpty else { return nil }
        guard let code = namedKeys[keyToken] ?? letters[keyToken] ?? digits[keyToken]
        else { return nil }
        // display — canonical modifier order ⌃⌥⇧⌘ + the key name as-is.
        var display = ""
        if mods & controlMask != 0 { display += "⌃" }
        if mods & optionMask != 0 { display += "⌥" }
        if mods & shiftMask != 0 { display += "⇧" }
        if mods & cmdMask != 0 { display += "⌘" }
        display += keyRaw
        return ParsedHotkey(carbonModifiers: mods, keyCode: code, display: display)
    }

    /// The config value or the default ⌥Space; an unparseable string falls back
    /// too (the panel must always open — a broken config is a reason for a log
    /// line, not for a dead hotkey).
    public static func resolve(configValue: String?) -> (hotkey: ParsedHotkey, fellBack: Bool) {
        if let v = configValue, !v.trimmingCharacters(in: .whitespaces).isEmpty,
           let p = parse(v) {
            return (p, false)
        }
        return (parse(defaultCombo)!, configValue?.isEmpty == false)
    }
}

/// Panel transport error: a short human line instead of an NSError dump.
public struct PanelFetchError: LocalizedError {
    public let text: String
    public init(_ text: String) { self.text = text }
    public var errorDescription: String? { text }
}

// MARK: - DTO /v1/search (UI-6: + kind/mtime for the panel subtitle)

public struct PanelSearchResponse: Codable, Equatable {
    public struct Result: Codable, Equatable {
        public let title: String
        public let permalink: String
        public let content: String
        public let score: Double
        public let file_path: String
        public let source: String
        /// frontmatter `type:` («note», «session», …); no field — «note».
        public let kind: String?
        /// file mtime, ISO 8601; missing — nil (subtitle without a date).
        public let mtime: String?
    }
    public let query: String
    public let project: String?
    public let trust: String?
    public let results: [Result]
}

// MARK: - Mapping to panel rows

/// One result row: «0.78 | title | subtitle». UI-8: PanelRow keeps the raw
/// fields (kind/source/mtime); the human-readable caption is built by the app
/// (HotkeyPanelView) in the current language — BMemAPI is language-independent.
public struct PanelRow: Equatable, Identifiable {
    public var id: String { permalink }
    public let permalink: String
    public let scoreText: String
    public let title: String
    /// frontmatter `type:` («note», «session», …); nil — no field.
    public let kind: String?
    /// «agent» | «human» | other — see the caption mapping in the app.
    public let source: String
    /// file mtime, ISO 8601; nil — the caption has no date.
    public let mtime: String?
    public let filePath: String
}

public enum PanelRowMapper {
    /// Scoring on the reference — two digits after the dot (0.78).
    public static func scoreText(_ score: Double) -> String {
        String(format: "%.2f", min(max(score, 0), 9.99))
    }

    public static func rows(from results: [PanelSearchResponse.Result]) -> [PanelRow] {
        results.map {
            PanelRow(permalink: $0.permalink,
                     scoreText: scoreText($0.score),
                     title: $0.title,
                     kind: $0.kind,
                     source: $0.source,
                     mtime: $0.mtime,
                     filePath: $0.file_path)
        }
    }
}

/// Dates for panel captions: the language is a parameter (ru: day + short
/// month, en: «Oct 14»); the year is added only for foreign years so that a
/// bare day+month in January does not lie about last year.
public enum PanelDate {
    public static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withFullDate]
        return f.date(from: s)
    }

    public static func text(_ date: Date, lang: String, now: Date = Date()) -> String {
        let cal = Calendar(identifier: .gregorian)
        let f = DateFormatter()
        f.locale = Locale(identifier: lang == "ru" ? "ru_RU" : "en_US")
        let sameYear = cal.isDate(date, equalTo: now, toGranularity: .year)
        if lang == "ru" {
            f.dateFormat = sameYear ? "d MMM" : "d MMM yyyy"
            // the ru locale prints the month abbreviation with a trailing dot; the reference has none.
            return f.string(from: date).replacingOccurrences(of: ".", with: "")
        }
        f.dateFormat = sameYear ? "MMM d" : "MMM d, yyyy"
        return f.string(from: date)
    }
}

// MARK: - Panel search model: 200 ms debounce, latency, trust

/// The panel core: query field -> debounce -> fetch -> rows. The UI wrapper only
/// draws; the whole call sequence is verified by XCTest (fetch is an injection,
/// the real HTTP lives in the app).
@MainActor
public final class PanelSearchModel: ObservableObject {
    /// Transport injection: (query, trust) -> daemon response. The app supplies
    /// the real GET /v1/search, tests supply a stub.
    public var fetch: ((String, String) async throws -> PanelSearchResponse)?

    @Published public private(set) var rows: [PanelRow] = []
    @Published public private(set) var query = ""
    @Published public private(set) var trust = "all"
    @Published public private(set) var searching = false
    /// The selected row index (up/down arrows in the panel).
    @Published public private(set) var selection = 0
    /// Counter-signal «ask the search field for focus» (grows on show).
    @Published public var focusRequest = 0
    /// Duration of the last completed request in ms (the «in 0.4 s» footer).
    @Published public private(set) var lastLatencyMs: Double?
    /// The last request error (the daemon died — the panel shows it honestly).
    @Published public private(set) var lastError: String?

    /// Debounce as required by the task: 200 ms after the last keystroke.
    public let debounceNs: UInt64 = 200_000_000
    private var task: Task<Void, Never>?
    /// Counter of started fetches — tests check that the debounce kills extras.
    public private(set) var fetchCount = 0

    public init() {}

    public func setQuery(_ q: String) {
        query = q
        schedule()
    }

    public func setTrust(_ t: String) {
        trust = t
        schedule()
    }

    /// Immediate search (--panel-shot mode: do not wait for the debounce).
    public func searchNow() {
        task?.cancel()
        task = Task { [weak self] in await self?.run() }
    }

    public func cancelPending() {
        task?.cancel()
        task = nil
    }

    public var selectedRow: PanelRow? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    /// A mouse click on a row — select it (before opening).
    public func select(index: Int) {
        guard rows.indices.contains(index) else { return }
        selection = index
    }

    /// Up/down with wrap-around at the edges — like Spotlight.
    public func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        let n = rows.count
        selection = ((selection + delta) % n + n) % n
    }

    private func schedule() {
        task?.cancel()
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            rows = []
            lastLatencyMs = nil
            lastError = nil
            return
        }
        let debounce = debounceNs
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: debounce)
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    private func run() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let fetch else { return }
        searching = true
        defer { searching = false }
        fetchCount += 1
        let start = ContinuousClock.now
        do {
            let resp = try await fetch(q, trust)
            // While it flew, the user could have cleared the field — do not revive.
            if query.trimmingCharacters(in: .whitespaces) != q { return }
            rows = PanelRowMapper.rows(from: resp.results)
            selection = 0
            // 1 ms = 10^15 attoseconds; /1e12 gave microseconds under an ms label.
            lastLatencyMs = Double(start.duration(to: ContinuousClock.now).attoseconds) / 1e15
            lastError = nil
        } catch {
            // A cancelled task (a new query edit arrived mid-flight) is not a
            // user error — silence is more honest than red text.
            if Task.isCancelled || error is CancellationError { return }
            if let u = error as? URLError, u.code == .cancelled { return }
            lastError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            rows = []
        }
    }
}
