// UI-3: DTOs of the daemon control API responses (docs/control-api.md).
// A separate lightweight dependency-free target: BMemAPITests unit-tests it,
// and BMemApp links against it without CoreAIKit/SQLite for two structs.
// Field names are snake_case as in the JSON, no keyword traps.

import Foundation

/// GET /v1/status
public struct DaemonStatus: Codable, Equatable {
    public struct IndexInfo: Codable, Equatable {
        public struct Project: Codable, Equatable {
            public let name: String
            public let notes: Int?
            public let chunks: Int?
            public let indexed_at: String?
            /// Index reporting: files normally awaiting indexing / genuinely failed.
            /// Optional — old daemons do not serve them.
            public let open: Int?
            public let failed: Int?
        }
        public let total_chunks: Int?
        public let total_notes: Int?
        /// Index reporting: three separate numbers + honest dirty (see docs/control-api.md).
        public let indexed: Int?
        public let open: Int?
        public let failed: Int?
        public let dirty: Bool?
        public let projects: [Project]?
    }

    public let version: String
    public let engine: String
    public let engine_dim: Int?
    public let model_loaded: Bool?
    public let memory_mb: Double?
    /// UI-5: footprint peak since daemon start (the «idle X · peak Y» line).
    public let memory_peak_mb: Double?
    public let memory_limit_mb: Int?
    public let autostart: Bool?
    public let lan_access: Bool?
    public let telemetry: Bool?
    public let index: IndexInfo?
    /// Daemon lifecycle fix: daemon pid — the app takes the old daemon down by signal
    /// correctly (graceful shutdown instead of «do not touch»). Old daemons do not serve it.
    public let pid: Int?
    /// Daemon lifecycle fix: the actual idle-unload threshold in seconds — the UI renders
    /// sys.model.unloaded from it (the literal «90 s» was a defect).
    /// Old daemons do not serve it; the display default is BMemTuning.
    public let model_idle_timeout_s: Int?
}

/// GET /v1/config (response) and PUT /v1/config (response — the full config after write).
/// The PUT patch — the same fields but optional: send only changed keys
/// (the daemon answers 400 to unknown keys and 400 to invalid values).
public struct DaemonConfig: Codable, Equatable {
    public var projects: [String: String]
    public var default_project: String?
    public var min_similarity: Double?
    public var exclude_dirs: [String]?
    public var engine: String?
    public var memory_limit_mb: Double?
    public var lan_access: Bool?
    public var telemetry: Bool?
    public var hotkey: String?
    public var launch_at_login: Bool?
    /// UI-4: auto-backup via git repository ~/.bmem/backup (PUT — enables the feature).
    public var auto_backup: Bool?
    /// read-only showcase list «what I never touch» (the daemon neither stores
    /// nor accepts it in PUT).
    public var never_touch: [String]?

    public init(projects: [String: String] = [:], default_project: String? = nil,
                min_similarity: Double? = nil, exclude_dirs: [String]? = nil,
                engine: String? = nil, memory_limit_mb: Double? = nil,
                lan_access: Bool? = nil, telemetry: Bool? = nil, hotkey: String? = nil,
                launch_at_login: Bool? = nil, auto_backup: Bool? = nil,
                never_touch: [String]? = nil) {
        self.projects = projects
        self.default_project = default_project
        self.min_similarity = min_similarity
        self.exclude_dirs = exclude_dirs
        self.engine = engine
        self.memory_limit_mb = memory_limit_mb
        self.lan_access = lan_access
        self.telemetry = telemetry
        self.hotkey = hotkey
        self.launch_at_login = launch_at_login
        self.auto_backup = auto_backup
        self.never_touch = never_touch
    }

    /// PUT patch: only non-empty keys (the daemon catches name typos with 400,
    /// extra nulls serve no purpose here).
    public func patchJSON() -> [String: Any] {
        var out: [String: Any] = [:]
        if !projects.isEmpty { out["projects"] = projects }
        if let default_project { out["default_project"] = default_project }
        if let min_similarity { out["min_similarity"] = min_similarity }
        if let exclude_dirs { out["exclude_dirs"] = exclude_dirs }
        if let engine { out["engine"] = engine }
        if let memory_limit_mb { out["memory_limit_mb"] = memory_limit_mb }
        if let lan_access { out["lan_access"] = lan_access }
        if let telemetry { out["telemetry"] = telemetry }
        if let hotkey { out["hotkey"] = hotkey }
        if let launch_at_login { out["launch_at_login"] = launch_at_login }
        if let auto_backup { out["auto_backup"] = auto_backup }
        return out
    }
}

// MARK: - UI-5: «Search» and «Advanced»

/// GET /v1/benchmark — frozen benchmark + custom benchmarks.
public struct BenchmarkResponse: Codable, Equatable {
    public struct CustomEntry: Codable, Equatable {
        public struct Check: Codable, Equatable {
            public let hit: Bool
            public let top1: String?
            public let checked_at: String?
        }
        public let id: String
        public let question: String
        public let expected_file: String
        public let last_check: Check?
    }
    public struct Custom: Codable, Equatable {
        public let total: Int
        public let hit: Int
        public let entries: [CustomEntry]?
    }
    public let engine: String
    public let total: Int
    public let hit: Int
    public let run_date: String?
    public let source: String?
    /// var: POST custom updates the section on top of the last GET response.
    public var custom: Custom?
}

/// Mapping of the «Strictness» slider (Search screen, 0..1) -> the strictness
/// parameter for GET /v1/search. The slider IS strictness: left edge 0 — the
/// engine serves everything down to its threshold, right edge 1 — only nearly
/// exact matches. The value is clamped and rounded to hundredths: the query
/// string must stay short and stable (0.7, not 0.6999999999999999).
public enum StrictnessMapping {
    public static func queryValue(slider: Double) -> Double {
        (min(max(slider, 0), 1) * 100).rounded() / 100
    }
    /// Value for the query string: dot separator, no trailing zeros.
    public static func queryItem(slider: Double) -> String {
        let v = queryValue(slider: slider)
        return v == v.rounded() ? String(format: "%.1f", v) : String(v)
    }
}

// MARK: - UI-4: «Memory & rollbacks»

/// GET /v1/rollback/points
public struct RollbackPointsResponse: Codable, Equatable {
    public struct Point: Codable, Equatable {
        public let commit: String
        public let date: String        // ISO 8601
        public let author: String?
        public let message: String?
        public let changes: Int?
    }
    public let git_backup: Bool
    public let auto_backup: Bool?
    public let schedule: String?
    public let backup_dir: String?
    public let points: [Point]?
}

/// GET /v1/rollback/diff?days=N
public struct RollbackDiffResponse: Codable, Equatable {
    public struct File: Codable, Equatable {
        public let path: String
        public let added: Int
        public let deleted: Int
    }
    public let days: Int
    public let commits: Int?
    public let files: [File]?
}
