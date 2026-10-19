// Config: the registry of projects (workspaces), search settings and facade settings.
// The file ~/.bmem/config.json; when missing it seeds from ~/.basic-memory/config.json
// so the native contour starts on the same md vaults without a manual migration.
//
// UI-1: the interface fields (engine, soft memory limit, LAN access, telemetry,
// hotkey, launch at login, index exclusions) live here too and are written via
// PUT /v1/config. The API key is NOT here: it is in Keychain (card UI-5),
// JSON holds only the lan_access flag.
import Foundation

public struct Config: Sendable {
    public var projects: [String: String]   // project name -> md-vault path
    public var defaultProject: String
    public var minSimilarity: Double
    // --- UI-1: facade settings ---
    public var excludeDirs: [String] = []       // index exclusions (folder prefixes)
    public var engine: String = "gemma"         // "gemma" | "qwen"; applied at daemon start
    public var memoryLimitMB: Double = 8192     // soft footprint limit (0 = off)
    public var lanAccess: Bool = false          // listen on LAN (the key is in Keychain, UI-5)
    public var telemetry: Bool = false          // off by default
    public var hotkey: String = ""              // search-panel hotkey string ("" = unset)
    public var launchAtLogin: Bool = false
    // UI-4: auto-backup of the note folders by the git repository ~/.bmem/backup.
    // Repository initialization — on first enable (PUT auto_backup=true).
    public var autoBackup: Bool = false

    /// The home directory honoring HOME from the environment. On macOS 27
    /// NSHomeDirectory() does NOT read $HOME (it uses getpwuid), so we read the
    /// variable ourselves; the fallback is NSHomeDirectory. Stands run with a
    /// substituted HOME; the production run is unaffected (HOME there already is the real home).
    public static func homeDir() -> String {
        if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty { return h }
        return NSHomeDirectory()
    }

    /// The ~/.bmem root honoring HOME from the environment (stands run with a
    /// substituted HOME; Foundation on Darwin takes the home from getpwuid, not HOME).
    static func bmemDir() -> String { homeDir() + "/.bmem" }

    public static func load() -> Config {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: bmemDir(), isDirectory: true)
        let file = dir.appendingPathComponent("config.json")
        let aiPath = homeDir() + "/Documents/AI-projects"
        if let data = try? Data(contentsOf: file),
           var cfg = try? JSONDecoder().decode(Config.self, from: data) {
            // the working AI-projects folder is mixed in unless explicitly removed
            if cfg.projects["ai-projects"] == nil, fm.fileExists(atPath: aiPath) {
                cfg.projects["ai-projects"] = aiPath
            }
            return cfg
        }
        // Migration: take the BM projects if they really exist on disk.
        var projects: [String: String] = [:]
        let bmConfig = URL(fileURLWithPath: homeDir(), isDirectory: true)
            .appendingPathComponent(".basic-memory/config.json")
        if let data = try? Data(contentsOf: bmConfig),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projs = obj["projects"] as? [String: [String: Any]] {
            for (name, entry) in projs {
                if let path = entry["path"] as? String,
                   FileManager.default.fileExists(atPath: path),
                   !name.contains("sandbox"), !name.contains("bmtest") {
                    projects[name] = path
                }
            }
        }
        if projects.isEmpty { projects["hermes"] = dir.appendingPathComponent("vault", isDirectory: true).path }
        let cfg = Config(projects: projects, defaultProject: "hermes", minSimilarity: 0.30)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let out = try? JSONEncoder.pretty.encode(cfg) { try? out.write(to: file) }
        return cfg
    }

    /// Save to ~/.bmem/config.json (UI-1: PUT /v1/config). Backfilling missing
    /// keys with defaults is done by the custom init(from:) — an old file without
    /// the new fields loads and after a PUT is rewritten without losing
    /// anything else.
    public func save() throws {
        let dir = URL(fileURLWithPath: Self.bmemDir(), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(self).write(to: dir.appendingPathComponent("config.json"))
    }
}

// A decoder with per-key defaults: the 1.1.0 file (projects/defaultProject/
// minSimilarity) stays valid after the UI-1 schema extension.
extension Config: Codable {
    private enum CodingKeys: String, CodingKey {
        case projects, defaultProject, minSimilarity, excludeDirs, engine,
             memoryLimitMB, lanAccess, telemetry, hotkey, launchAtLogin, autoBackup
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decodeIfPresent([String: String].self, forKey: .projects) ?? [:]
        defaultProject = try c.decodeIfPresent(String.self, forKey: .defaultProject) ?? "hermes"
        minSimilarity = try c.decodeIfPresent(Double.self, forKey: .minSimilarity) ?? 0.30
        excludeDirs = try c.decodeIfPresent([String].self, forKey: .excludeDirs) ?? []
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? "gemma"
        memoryLimitMB = try c.decodeIfPresent(Double.self, forKey: .memoryLimitMB) ?? 8192
        lanAccess = try c.decodeIfPresent(Bool.self, forKey: .lanAccess) ?? false
        telemetry = try c.decodeIfPresent(Bool.self, forKey: .telemetry) ?? false
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? ""
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        autoBackup = try c.decodeIfPresent(Bool.self, forKey: .autoBackup) ?? false
    }
}

extension JSONEncoder { static let pretty: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }() }
