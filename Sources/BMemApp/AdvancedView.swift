import SwiftUI
import AppKit
import BMemAPI

/// The Advanced screen (reference design/screenshots/06-advanced.png, UI-5).
/// The engine — PUT /v1/config {engine}; LAN access — PUT {lan_access}, while the
/// API key is stored in Keychain (BMemKeychain, Security framework) and never
/// appears in config.json; the memory limit — PUT {memory_limit_mb}; the
/// «What goes where» table computes real sizes from disk.
/// UI-8: strings — Localizable.xcstrings; the table rows store raw bytes and
/// keys, the captions are computed in body — a language switch redraws them instantly.
struct AdvancedView: View {
    @EnvironmentObject private var daemon: DaemonModel
    @ObservedObject private var l10n = L10n.shared

    /// The reindex warning is shown after the action, not in advance: the
    /// reference has none under the segment, it is about a concrete change.
    @State private var engineChanged = false
    @State private var limitGB = 8.0
    @State private var didInitLimit = false
    @State private var limitPutTask: Task<Void, Never>?

    // the LAN key (Keychain)
    @State private var lanKey: String?
    @State private var keyVisible = false
    @State private var keychainError: String?

    // «What goes where» — sizes are computed from disk in the background
    @State private var rows: [WhereRow]?

    private var lanOn: Bool { daemon.config?.lan_access ?? false }
    private var engine: String { daemon.config?.engine ?? "gemma" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(Section.advanced.title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)

                engineCard
                lanCard
                memoryCard
                whereCard
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.bmemWindow)
        .navigationTitle(Section.advanced.title)
        // UI-9: the duplicated title plate is hidden (commented out per the
        // acceptance requirement), UI-8 strings go through the catalog.
        // .toolbar {
        //     ToolbarItem(placement: .principal) {
        //         Text(Section.advanced.title).font(.system(size: 13)).foregroundStyle(.primary)
        //     }
        // }
        .task {
            // Sizes and the key are read by INDEPENDENT tasks: SecItemCopyMatching
            // sometimes stalls on a long tail (SecurityAgent), the table must not
            // wait for the key.
            Task.detached(priority: .userInitiated) {
                let rows = Self.diskRows()
                await MainActor.run { self.rows = rows }
            }
            Task.detached(priority: .userInitiated) {
                // a tiny pause so --seed-lan-key managed to write (a race only in
                // the test capture, production without the flag does not care)
                try? await Task.sleep(for: .milliseconds(300))
                let key = try? BMemKeychain.read(account: BMemKeychain.lanKeyAccount)
                await MainActor.run { self.lanKey = key }
            }
            for _ in 0..<40 where !didInitLimit {
                if let cfg = daemon.config {
                    limitGB = max(2, min(16, (cfg.memory_limit_mb ?? 8192) / 1024))
                    didInitLimit = true
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    // MARK: - Embedding engine

    private var engineCard: some View {
        Card {
            Text(L("adv.engine"))
                .font(.system(size: 14, weight: .semibold))
            Text(L("adv.engine.hint"))
                .font(.system(size: 12))
                .foregroundStyle(Color.bmemSecondary)
            SegmentedRow(options: [("gemma", L("adv.engine.gemma")),
                                   ("qwen", L("adv.engine.qwen"))],
                          selection: engine) { pick in
                guard pick != engine else { return }
                engineChanged = true
                Task { await daemon.putConfig(["engine": pick]) }
            }
            if engineChanged {
                NoteBanner(tone: .warning,
                           text: L("adv.engine.changed"))
            }
        }
    }

    // MARK: - Network access

    private var lanCard: some View {
        Card {
            Text(L("adv.lan.title"))
                .font(.system(size: 14, weight: .semibold))
            HStack(spacing: 10) {
                Text(lanOn ? L("adv.lan.on") : L("adv.lan.off"))
                    .font(.system(size: 13, weight: .medium))
                Toggle("", isOn: Binding(
                    get: { lanOn },
                    set: { on in Task { await daemon.putConfig(["lan_access": on]) } }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Color.bmemGreen)
                Text(L("adv.lan.enable"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bmemSecondary)
                Spacer(minLength: 0)
            }
            Text(L("adv.lan.note"))
                .font(.system(size: 12))
                .foregroundStyle(Color.bmemSecondary)
                .fixedSize(horizontal: false, vertical: true)
            keyRow
            if let err = keychainError {
                Text(Lf("adv.keychain.err", err))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bmemOrange)
            }
        }
    }

    /// The key field: a masked value from Keychain, show/hide, generation if
    /// there is no key yet. Never written into config.json.
    private var keyRow: some View {
        HStack(spacing: 10) {
            Text(keyText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(lanKey == nil ? Color.bmemSecondary : .white)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .frame(maxWidth: 320, alignment: .leading)
                .background(Color.black.opacity(0.25),
                            in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            Button(keyVisible ? L("adv.key.hide") : L("adv.key.show")) { keyVisible.toggle() }
                .buttonStyle(CompactButtonStyle())
                .disabled(lanKey == nil)
            Text(L("adv.keychain"))
                .font(.system(size: 12))
                .foregroundStyle(Color.bmemSecondary)
            Spacer(minLength: 0)
            if lanKey == nil {
                Button(L("adv.key.gen")) { generateKey() }
                    .buttonStyle(CompactButtonStyle(prominent: true))
            }
        }
        .opacity(lanOn ? 1 : 0.55)
    }

    private var keyText: String {
        guard let key = lanKey else { return L("adv.key.none") }
        return keyVisible ? key : L("adv.key.masked")
    }

    private func generateKey() {
        let fresh = BMemKeychain.generateAPIKey()
        do {
            try BMemKeychain.save(account: BMemKeychain.lanKeyAccount, value: fresh)
            lanKey = fresh
            keychainError = nil
        } catch {
            keychainError = String(describing: error)
        }
    }

    // MARK: - Soft memory limit

    private var memoryCard: some View {
        Card {
            Text(L("adv.mem.title"))
                .font(.system(size: 14, weight: .semibold))
            Text(Lf("adv.mem.hint", gbLabel(limitGB)))
                .font(.system(size: 12))
                .foregroundStyle(Color.bmemSecondary)
            Slider(value: $limitGB, in: 2...16, step: 0.5)
                .tint(Color.bmemAccent)
                .onChange(of: limitGB) { _, newValue in
                    limitPutTask?.cancel()
                    limitPutTask = Task {
                        try? await Task.sleep(for: .milliseconds(600))
                        guard !Task.isCancelled else { return }
                        await daemon.putConfig(["memory_limit_mb": newValue * 1024])
                    }
                }
        }
    }

    private func gbLabel(_ gb: Double) -> String {
        (gb == gb.rounded() ? String(format: "%.0f", gb) : String(format: "%.1f", gb))
            + " " + L("adv.unit.gb")
    }

    // MARK: - What goes where

    private var whereCard: some View {
        Card {
            Text(L("adv.where.title"))
                .font(.system(size: 14, weight: .semibold))
            if let rows {
                ForEach(rows) { row in
                    HStack(spacing: 12) {
                        Text(L(row.nameKey))
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 190, alignment: .leading)
                        Text(Self.formatBytes(row.bytes))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.bmemSecondary)
                            .frame(width: 90, alignment: .leading)
                        Text(row.pathIsBundle ? L("adv.where.inbundle") : L(row.pathKey))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.bmemSecondary)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                Text(L("adv.where.counting"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bmemSecondary)
            }
        }
    }

    // MARK: - Size computation (real files, not constants)

    /// Raw data of a table row: the captions (name/path/units) are drawn in body
    /// in the current language, so switching is instant.
    struct WhereRow: Identifiable {
        let id: String
        let nameKey: String
        let bytes: Int64
        let pathKey: String
        let pathIsBundle: Bool
    }

    private nonisolated static var home: String {
        ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    }

    nonisolated static func diskRows() -> [WhereRow] {
        let fm = FileManager.default
        var rows: [WhereRow] = []

        // Gemma-2: in the release bundle, in dev — next to ~/.bmem/models.
        let bundled = (Bundle.main.resourcePath ?? "/nonexistent") + "/models/embeddinggemma-2-coreml"
        let gemmaPath = fm.fileExists(atPath: bundled)
            ? bundled : home + "/.bmem/models/embeddinggemma-2-coreml"
        let gemmaInBundle = fm.fileExists(atPath: bundled)
        rows.append(WhereRow(id: "gemma",
                             nameKey: "adv.where.gemma",
                             bytes: byteSize(at: gemmaPath),
                             pathKey: "adv.where.gemma.path",
                             pathIsBundle: gemmaInBundle))

        // Qwen3: symlinks to aimodel + tokenizer, counted over the real targets.
        var qwenBytes: Int64 = 0
        for name in ["qwen3-embedding-0.6b_float16_s512_static.aimodel", "tokenizer"] {
            qwenBytes += byteSize(at: home + "/.bmem/models/" + name)
        }
        rows.append(WhereRow(id: "qwen",
                             nameKey: "adv.where.qwen",
                             bytes: qwenBytes,
                             pathKey: "adv.where.qwen.path",
                             pathIsBundle: false))

        // The index: bmem.db + wal.
        var dbBytes = byteSize(at: home + "/.bmem/bmem.db")
        dbBytes += byteSize(at: home + "/.bmem/bmem.db-wal")
        rows.append(WhereRow(id: "index",
                             nameKey: "adv.where.index",
                             bytes: dbBytes,
                             pathKey: "adv.where.index.path",
                             pathIsBundle: false))
        return rows
    }

    /// The size of a file or a directory tree; symlinks are resolved and their
    /// content is counted over the target (the way du without -L would show 0 and confuse).
    private nonisolated static func byteSize(at path: String) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        let real = ((path as NSString).expandingTildeInPath as NSString).resolvingSymlinksInPath
        if !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: real)
            return (attrs?[.size] as? Int64) ?? 0
        }
        let url = URL(fileURLWithPath: real)
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in en {
            let vals = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            total += Int64(vals?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// As in the reference: «561 MB», «1.1 GB» — units from the catalog
    /// (the language at render time).
    nonisolated static func formatBytes(_ bytes: Int64) -> String {
        if bytes == 0 { return "—" }
        let gib = Double(bytes) / (1024 * 1024 * 1024)
        if gib >= 1 { return String(format: "%.1f", gib) + " " + L("adv.unit.gb") }
        let mib = Int((Double(bytes) / (1024 * 1024)).rounded())
        return grouped(mib) + " " + L("adv.unit.mb")
    }

    /// Digits grouped with a thin space: 1 400 MB.
    private nonisolated static func grouped(_ n: Int) -> String {
        let digits = String(n)
        var out = ""
        for (i, ch) in digits.reversed().enumerated() {
            if i > 0, i % 3 == 0 { out = "\u{2009}" + out }
            out = String(ch) + out
        }
        return out
    }
}
