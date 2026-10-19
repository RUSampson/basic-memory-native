import SwiftUI
import AppKit
import ServiceManagement
import BMemAPI

/// The System screen (reference design/screenshots/07-system.png, UI-5).
/// Autostart — SMAppService (the launchd agent survives a reboot) +
/// a synchronous PUT launch_at_login; the hotkey — our own mini-recorder without
/// external dependencies, the value goes into config.hotkey; the install counter —
/// the telemetry toggle (the counter itself is a no-op stub until signed builds);
/// the daemon status — live lines from GET /v1/status with colored dots.
/// UI-8: strings — Localizable.xcstrings; the interface language switches
/// instantly via the «Interface language» card (System / Russian / English).
struct SystemView: View {
    @EnvironmentObject private var daemon: DaemonModel
    @ObservedObject private var l10n = L10n.shared
    @StateObject private var recorder = HotkeyRecorder()
    /// UI-6: the global panel hotkey status (the «taken» error comes from here).
    @ObservedObject private var panel = HotkeyPanelController.shared

    @State private var autostartError: String?
    @State private var didInitHotkey = false
    @State private var hotkeyDraft = ""

    private var status: DaemonStatus? {
        if case let .online(s) = daemon.state { return s }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(Section.system.title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)

                languageCard
                autostartCard
                hotkeyCard
                telemetryCard
                updatesCard
                statusCard
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.bmemWindow)
        .navigationTitle(Section.system.title)
        // UI-9: the duplicated title plate is hidden (commented out per the
        // acceptance requirement), UI-8 strings go through the catalog.
        // .toolbar {
        //     ToolbarItem(placement: .principal) {
        //         Text(Section.system.title).font(.system(size: 13)).foregroundStyle(.primary)
        //     }
        // }
        .task {
            // onAppear does not fit here: it fires before the first GET /v1/config,
            // and pollLoop manages it later — wait for the config with a short loop.
            for _ in 0..<40 where !didInitHotkey {
                if let cfg = daemon.config {
                    hotkeyDraft = cfg.hotkey ?? ""
                    didInitHotkey = true
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    // MARK: - Interface language (UI-8)

    /// Applied instantly: L10n is an ObservableObject, every screen observes it.
    /// The CLI override --lang is not overridden (stands live in a single run).
    private var languageCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("sys.lang"))
                    .font(.system(size: 14, weight: .semibold))
                Text(L("sys.lang.note"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bmemSecondary)
                // The language list is built from the l10n/ catalog: drop in <lang>.json —
                // the segment appears, the code stays untouched.
                SegmentedRow(options: l10n.switcherOptions,
                             selection: l10n.mode) { pick in
                    l10n.mode = pick
                }
            }
        }
    }

    // MARK: - Autostart

    private var autostartOn: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private var autostartCard: some View {
        Card {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("onboarding.login.toggle"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(L("sys.autostart.note"))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.bmemSecondary)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(
                    get: { autostartOn },
                    set: { enable in
                        do {
                            if enable { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                            autostartError = nil
                        } catch {
                            // An ad-hoc dev bundle may be rejected by launchd —
                            // an honest on-screen error, not a silent toggle.
                            autostartError = String(describing: error)
                        }
                        Task { await daemon.putConfig(["launch_at_login": enable]) }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Color.bmemGreen)
            }
            if let err = autostartError {
                Text(Lf("sys.autostart.err", err))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bmemOrange)
            }
        }
    }

    // MARK: - Hotkey

    private var hotkeyCard: some View {
        Card {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("sys.hotkey"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(L("sys.hotkey.note"))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.bmemSecondary)
                }
                Spacer(minLength: 0)
                Button(recorder.recording ? L("sys.hotkey.press")
                                          : Lf("sys.hotkey.record", hotkeyDraft.isEmpty ? L("sys.hotkey.unset") : hotkeyDraft)) {
                    if recorder.recording { recorder.stop() } else { recorder.start() }
                }
                .buttonStyle(CompactButtonStyle(prominent: recorder.recording))
            }
            if let captured = recorder.captured {
                Text(Lf("sys.hotkey.captured", captured))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bmemGreen)
            }
            // UI-6: the honest registration status of the global panel hotkey.
            if let err = panel.registerErrorText {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bmemOrange)
            } else if let hk = panel.activeHotkey {
                Text(Lf("sys.hotkey.active", hk))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bmemSecondary)
            }
        }
        .onDisappear { recorder.stop() }
        .onChange(of: recorder.captured) { _, newValue in
            guard let newValue else { return }
            hotkeyDraft = newValue
            Task { await daemon.putConfig(["hotkey": newValue]) }
        }
    }

    // MARK: - Telemetry

    private var telemetryCard: some View {
        Card {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("sys.telemetry"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(L("sys.telemetry.note"))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.bmemSecondary)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(
                    get: { daemon.config?.telemetry ?? false },
                    set: { on in
                        Task {
                            await daemon.putConfig(["telemetry": on])
                            if on { Telemetry.pingInstall() }
                        }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Color.bmemGreen)
            }
        }
    }

    // MARK: - Updates

    private var updatesCard: some View {
        Card {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("sys.updates"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(L("sys.updates.note"))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.bmemSecondary)
                }
                Spacer(minLength: 0)
                Button(L("sys.updates.btn")) {}
                    .buttonStyle(CompactButtonStyle())
                    .disabled(true)
            }
        }
    }

    // MARK: - Daemon status

    private var statusCard: some View {
        Card {
            Text(L("sys.status"))
                .font(.system(size: 14, weight: .semibold))
            if let s = status {
                // Index reporting: the dot turns red only for a real reason —
                // failed>0 or a stuck open file; a live session tail is not an alarm.
                statusRow(s.index?.dirty == true ? .orange : .green, L("sys.status.index"), indexLine(s))
                statusRow(.green, L("sys.status.mem"), memoryLine(s))
                statusRow(s.model_loaded == true ? .green : .orange, L("sys.status.model"), modelLine(s))
            } else {
                statusRow(.orange, L("sys.status.daemon"), daemon.state == .checking
                    ? Lf("sys.status.checking", DaemonEndpoint.base.host ?? "")
                    : L("sys.status.dead"))
            }
        }
    }

    private enum Dot { case green, orange }

    private func statusRow(_ dot: Dot, _ name: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(dot == .green ? Color.bmemGreen : Color.bmemOrange)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            Text(name)
                .font(.system(size: 12))
                .foregroundStyle(Color.bmemSecondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
    }

    private func indexLine(_ s: DaemonStatus) -> String {
        let chunks = s.index?.total_chunks ?? 0
        let projects = s.index?.projects?.count ?? 0
        let base = Lf("sys.index.line", l10n.pk("plural.chunk", chunks),
                  l10n.pk("plural.project", projects), freshness(s))
        // Index reporting: three separate numbers instead of «dirty=yes all night»:
        // indexed / open (session tails and fresh files) / failed.
        // An old daemon without the new fields — the old single line.
        guard let idx = s.index, let open = idx.open, let failed = idx.failed else { return base }
        let indexed = idx.indexed ?? idx.total_notes ?? 0
        return base + "\n" + Lf("sys.index.health", l10n.pk("plural.mdfile", indexed), open, failed)
    }

    /// Freshness = the newest indexed_at among the projects.
    private func freshness(_ s: DaemonStatus) -> String {
        let dates = (s.index?.projects ?? []).compactMap { p -> Date? in
            guard let raw = p.indexed_at else { return nil }
            return ISO8601DateFormatter().date(from: raw)
        }
        guard let newest = dates.max() else { return L("fresh.never") }
        let mins = Int(Date().timeIntervalSince(newest) / 60)
        if mins < 10 { return L("fresh.now") }
        if mins < 60 { return Lf("fresh.min", mins) }
        let hours = mins / 60
        if hours < 24 { return Lf("fresh.hour", hours) }
        return Lf("fresh.day", hours / 24)
    }

    private func memoryLine(_ s: DaemonStatus) -> String {
        let mb = Int((s.memory_mb ?? 0).rounded())
        let idle = Lf("sys.mem.idle", mb, L("adv.unit.mb"))
        if let peak = s.memory_peak_mb {
            return idle + " · " + Lf("sys.mem.peak", Int(peak.rounded()), L("adv.unit.mb"))
        }
        let limit = Int(s.memory_limit_mb ?? 0)
        return idle + " · " + Lf("sys.mem.limit", limit, L("adv.unit.mb"))
    }

    private func modelLine(_ s: DaemonStatus) -> String {
        let name: String
        switch s.engine {
        case "embeddinggemma-2": name = L("sys.model.gemma")
        case "qwen3-embedding-0.6b": name = L("sys.model.qwen")
        default: name = s.engine
        }
        if s.model_loaded == true { return Lf("sys.model.loaded", name) }
        // Daemon lifecycle fix: the threshold is taken as-is from /v1/status (the watchdog
        // drives the same number); the catalog literal was the «90 s while the
        // threshold is 335» defect. An old daemon does not serve the field — show the code constant.
        let secs = s.model_idle_timeout_s ?? BMemTuning.modelIdleTimeoutSeconds
        return Lf("sys.model.unloaded", name, String(secs))
    }
}

/// A KeyboardShortcuts-style hotkey mini-recorder without external dependencies:
/// while recording, a local monitor catches keyDown; the combo must contain
/// ⌘/⌥/⌃ (like Spotlight), Esc cancels. The value is a string like
/// «⇧⌘Space», the same string goes into config.hotkey.
@MainActor
final class HotkeyRecorder: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var captured: String?

    private var monitor: Any?

    func start() {
        captured = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording else { return event }
            if event.keyCode == 53 { self.stop(); return nil }  // Esc
            if let combo = Self.combo(from: event) {
                self.captured = combo
                self.stop()
                return nil
            }
            return event
        }
    }

    func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func combo(from event: NSEvent) -> String? {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let mods = (f.contains(.control) ? "⌃" : "")
            + (f.contains(.option) ? "⌥" : "")
            + (f.contains(.shift) ? "⇧" : "")
            + (f.contains(.command) ? "⌘" : "")
        guard !mods.isEmpty else { return nil }  // a bare letter is not a hotkey
        return mods + (keyName(event) ?? "")
    }

    private static func keyName(_ event: NSEvent) -> String? {
        switch event.keyCode {
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 51: return "Delete"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
            return chars.uppercased()
        }
    }
}
