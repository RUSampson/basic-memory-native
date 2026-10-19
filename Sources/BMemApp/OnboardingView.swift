import SwiftUI
import AppKit
import ServiceManagement
import BMemAPI

/// Screen 1 (reference 01-first-launch.png): the greeting, what we index,
/// Full Disk Access, launch at login, the start of indexing with an ETA.
/// The data is live: /v1/config + /v1/status; without the daemon — an honest «no answer».
struct OnboardingView: View {
    let onFinish: () -> Void

    @EnvironmentObject private var daemon: DaemonModel
    @ObservedObject private var l10n = L10n.shared
    @State private var launchAtLogin = false
    @State private var loginTouched = false
    @State private var fdaGranted = false
    @State private var loginError: String?
    /// Local md-file counting (background: scanning a big folder takes ~2 s,
    /// it has no place on the main thread inside body).
    @State private var localCount: Int?

    /// A rough indexing speed, files/sec. The anchor is the production full
    /// reindex of 1 272 files in 272 s (docs/bench-gemma-2026-10-13.md, = 4.67 files/s),
    /// stand calibration and details: docs/ui3-eta-2026-10-15.md.
    /// 1677 files -> ~6 minutes, as in the reference.
    static let filesPerSecond = 4.5

    private var primary: (name: String, path: String)? {
        guard let cfg = daemon.config, !cfg.projects.isEmpty else { return nil }
        let name = cfg.default_project.flatMap { cfg.projects[$0] != nil ? $0 : nil }
            ?? cfg.projects.keys.sorted().first!
        return (name, cfg.projects[name]!)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Circle()
                    .fill(Color.bmemAccent)
                    .frame(width: 56, height: 56)
                    .padding(.top, 48)

                Text(L("onboarding.title"))
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 20)

                Text(L("onboarding.subtitle"))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.bmemSecondary)
                    .padding(.top, 10)

                VStack(spacing: 12) {
                    indexFolderCard
                    fdaCard
                    loginCard
                    if let err = daemon.lastPutError {
                        Text(Lf("onboarding.reject", String(err.prefix(160))))
                            .font(.system(size: 11))
                            .foregroundStyle(Color.bmemOrange)
                            .frame(maxWidth: 640, alignment: .leading)
                    }
                }
                .padding(.top, 28)
                .frame(maxWidth: 640)

                HStack {
                    Spacer()
                    Button(startTitle) { onFinish() }
                        .buttonStyle(CompactButtonStyle(prominent: true))
                        .controlSize(.large)
                        .disabled(primary == nil)
                }
                .frame(maxWidth: 640)
                .padding(.top, 16)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .background(Color.bmemWindow)
        .navigationTitle(L("app.nav.setup"))
        .task {
            fdaGranted = FDACheck.isGranted()
            await daemon.refreshConfig()
            if !loginTouched, let v = daemon.config?.launch_at_login { launchAtLogin = v }
        }
        .task(id: primary?.path) {
            guard let path = primary?.path else { localCount = nil; return }
            localCount = await Task.detached(priority: .utility) { countMdFiles(in: path) }.value
        }
    }

    // MARK: - 1 · What we index

    private var indexFolderCard: some View {
        Card {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("onboarding.folder.card"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(folderLine)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.bmemSecondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button(L("onboarding.folder.change")) { chooseFolder() }
                    .buttonStyle(CompactButtonStyle())
            }
        }
    }

    private var folderLine: String {
        guard let p = primary else {
            if case .unreachable = daemon.state { return L("onboarding.folder.dead") }
            return L("onboarding.folder.none")
        }
        let n = indexedCount(for: p)
        if let n { return Lf("onboarding.folder.line", displayPath(p.path), L10n.shared.pk("plural.mdfile", n)) }
        return Lf("onboarding.folder.counting", displayPath(p.path))
    }

    /// The md-file count: from /v1/status (indexed project notes); while the
    /// project is not in the index yet — a local count over the same folder (background).
    private func indexedCount(for p: (name: String, path: String)) -> Int? {
        if case .online(let s) = daemon.state,
           let proj = s.index?.projects?.first(where: { $0.name == p.name }),
           let notes = proj.notes, notes > 0 {
            return notes
        }
        return localCount
    }

    private var startTitle: String {
        guard let p = primary else { return L("onboarding.start") }
        guard let files = indexedCount(for: p) else { return L("onboarding.start") }
        let minutes = max(1, Int(ceil(Double(files) / Self.filesPerSecond / 60)))
        return Lf("onboarding.start.eta", "~\(minutes)")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("panel.open.prompt")
        panel.message = L("panel.open.message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.lastPathComponent
        var projects = daemon.config?.projects ?? [:]
        projects[name] = url.path
        Task {
            await daemon.putConfig(["projects": projects, "default_project": name])
        }
    }

    // MARK: — 2 · Full Disk Access

    private var fdaCard: some View {
        Card {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(L("onboarding.fda.card"))
                            .font(.system(size: 13, weight: .semibold))
                        if fdaGranted {
                            Text(L("onboarding.fda.granted"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.bmemGreen)
                        }
                    }
                    Text(L("onboarding.fda.why"))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.bmemSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer().frame(width: 16)
                Button(fdaGranted ? L("common.recheck") : L("common.grant")) {
                    if fdaGranted { fdaGranted = FDACheck.isGranted() }
                    else { FDACheck.openSettings() }
                }
                .buttonStyle(CompactButtonStyle(prominent: !fdaGranted))
            }
        }
    }

    // MARK: - Launch at login

    private var loginCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $launchAtLogin) {
                    Text(L("onboarding.login.toggle"))
                        .font(.system(size: 13))
                }
                .toggleStyle(.switch)
                .tint(Color.bmemGreen)
                .onChange(of: launchAtLogin) { _, on in
                    loginTouched = true
                    applyLaunchAtLogin(on)
                }
                if let loginError {
                    Text(loginError)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.bmemOrange)
                }
            }
        }
    }

    /// SMAppService.mainApp (macOS 13+) — the official login registration,
    /// plus the same value in the daemon config (one source for the System screen).
    private func applyLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = Lf("onboarding.login.error", error.localizedDescription)
        }
        Task { await daemon.putConfig(["launch_at_login": on]) }
    }
}
