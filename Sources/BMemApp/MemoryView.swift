import SwiftUI
import BMemAPI

/// The Memory & rollbacks screen (reference design/screenshots/04-memory-rollbacks.png,
/// card UI-4). Live data: GET /v1/rollback/points, GET /v1/rollback/diff,
/// POST /v1/rollback, POST /v1/forget, PUT /v1/config {auto_backup}.
/// UI-8: strings — Localizable.xcstrings; the backup schedule is rendered with the
/// app locale (the daemon string «every day at 03:00» is not shown on screen —
/// the daemon is language-independent).
struct MemoryView: View {
    @EnvironmentObject private var daemon: DaemonModel
    @ObservedObject private var l10n = L10n.shared

    @State private var showDiff = false
    @State private var rollbackTarget: RollbackPointsResponse.Point?
    @State private var forgetTarget: String?
    @State private var forgetTyped = ""
    @State private var didInit = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(Section.memory.title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                Text(Section.memory.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.bmemSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                backupCard
                pointsCard
                if showDiff { diffCard }
                forgetCard

                if let err = daemon.rollbackError {
                    NoteBanner(tone: .warning, text: Lf("memory.err", err))
                }
                NoteBanner(tone: .warning,
                           text: L("memory.note"))
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.bmemWindow)
        .navigationTitle(Section.memory.title)
        // UI-9: the duplicated title plate is hidden (commented out per the
        // acceptance requirement), UI-8 strings go through the catalog.
        // .toolbar {
        //     ToolbarItem(placement: .principal) {
        //         Text(Section.memory.title)
        //             .font(.system(size: 13))
        //             .foregroundStyle(.primary)
        //     }
        // }
        .task {
            // pull the screen data on entry; repeated entries do not wait — the
            // DaemonModel cache already exists, refresh on top of it.
            await daemon.refreshRollback()
            if showDiff { await daemon.loadRollbackDiff() }
            didInit = true
        }
        .confirmationDialog(
            rollbackTitle,
            isPresented: Binding(get: { rollbackTarget != nil },
                                 set: { if !$0 { rollbackTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button(L("memory.rollback.go"), role: .destructive) {
                if let p = rollbackTarget {
                    Task {
                        if await daemon.rollback(to: p.commit) {
                            await daemon.refreshRollback()
                        }
                    }
                }
                rollbackTarget = nil
            }
            Button(L("common.cancel"), role: .cancel) { rollbackTarget = nil }
        } message: {
            Text(L("memory.rollback.msg"))
        }
        .alert(L("memory.forget.title"), isPresented: Binding(get: { forgetTarget != nil },
                                                              set: { if !$0 { forgetTarget = nil } })) {
            TextField(L("memory.forget.field"), text: $forgetTyped)
            Button(L("memory.forget.go"), role: .destructive) {
                if let name = forgetTarget, forgetTyped == name {
                    Task {
                        if await daemon.forget(project: name) {
                            await daemon.refreshRollback()
                            await daemon.refreshConfig()
                        }
                    }
                }
                forgetTarget = nil
            }
            Button(L("common.cancel"), role: .cancel) { forgetTarget = nil }
        } message: {
            Text(L("memory.forget.msg"))
        }
    }

    private var rollbackTitle: String {
        guard let p = rollbackTarget else { return L("memory.rollback.q") }
        return Lf("memory.rollback.q.point", RelativeDate.label(p.date))
    }

    // MARK: - the toggle card

    private var backupCard: some View {
        Card {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("memory.backup.title"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(scheduleLine)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.bmemSecondary)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(
                    get: { daemon.rollback?.auto_backup ?? daemon.config?.auto_backup ?? false },
                    set: { newValue in
                        Task {
                            await daemon.putConfig(["auto_backup": newValue])
                            await daemon.refreshRollback()
                        }
                    }))
                    .toggleStyle(.switch)
                    .tint(.bmemGreen)
                    .labelsHidden()
            }
        }
    }

    /// «every day at 03:00 · last: today 03:00, 12 changes» — the schedule is
    /// localized by the app (the daemon is language-independent), the last commit
    /// comes from the actual points.
    private var scheduleLine: String {
        let schedule = L("memory.schedule")
        guard let last = daemon.rollback?.points?.first else {
            return daemon.rollback?.git_backup == true
                ? Lf("memory.backup.nocommits", schedule)
                : Lf("memory.backup.off", schedule)
        }
        return Lf("memory.backup.last", schedule, RelativeDate.label(last.date),
                  l10n.pk("plural.change", last.changes ?? 0))
    }

    // MARK: - rollback points

    private var pointsCard: some View {
        Card {
            HStack {
                Text(L("memory.points.title"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(showDiff ? L("memory.diff.hide") : L("memory.diff.show")) {
                    showDiff.toggle()
                    if showDiff { Task { await daemon.loadRollbackDiff() } }
                }
                .buttonStyle(CompactButtonStyle())
            }
            let points = daemon.rollback?.points ?? []
            if daemon.rollback?.git_backup == false {
                Text(L("memory.points.off"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bmemSecondary)
            } else if points.isEmpty {
                Text(L("memory.points.empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bmemSecondary)
            } else {
                ForEach(Array(points.enumerated()), id: \.element.commit) { idx, p in
                    if idx > 0 {
                        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                    }
                    pointRow(p)
                }
            }
        }
    }

    private func pointRow(_ p: RollbackPointsResponse.Point) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(RelativeDate.label(p.date))
                    .font(.system(size: 13, weight: .medium))
                Text(pointSubtitle(p))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.bmemSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button(L("memory.rollback.go")) { rollbackTarget = p }
                .buttonStyle(CompactButtonStyle())
                .disabled(daemon.rollbackBusy)
        }
        .padding(.vertical, 4)
    }

    /// Second lines per the reference: «12 notes changed · 3 new» /
    /// «agent: reindex of Hermes sessions» — for us that is the commit message.
    private func pointSubtitle(_ p: RollbackPointsResponse.Point) -> String {
        let changes = l10n.pk("plural.note", p.changes ?? 0)
        let msg = p.message ?? ""
        return msg.isEmpty ? changes : "\(changes) · \(msg)"
    }

    // MARK: - diff for a week

    private var diffCard: some View {
        Card {
            HStack {
                Text(L("memory.diff.title"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if let d = daemon.rollbackDiff {
                    Text(Lf("memory.diff.summary",
                            l10n.pk("plural.commit", d.commits ?? 0),
                            l10n.pk("plural.file", d.files?.count ?? 0)))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.bmemSecondary)
                }
            }
            let files = daemon.rollbackDiff?.files ?? []
            if files.isEmpty {
                Text(L("memory.diff.empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bmemSecondary)
            } else {
                ForEach(files.prefix(50)) { f in
                    HStack(spacing: 10) {
                        Text("+\(f.added)")
                            .foregroundStyle(Color.bmemGreen)
                        Text("−\(f.deleted)")
                            .foregroundStyle(Color.bmemOrange)
                        Text(f.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                if files.count > 50 {
                    Text(Lf("memory.diff.more", files.count - 50))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.bmemSecondary)
                }
            }
        }
    }

    // MARK: - forget project

    private var forgetCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("memory.forget.card"))
                    .font(.system(size: 14, weight: .semibold))
                Text(L("memory.forget.sub"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bmemSecondary)
            }
            let names = (daemon.config?.projects ?? [:]).keys.sorted()
            if names.isEmpty {
                Text(L("memory.forget.empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bmemSecondary)
            } else {
                HStack(spacing: 8) {
                    ForEach(names, id: \.self) { name in
                        Button(Lf("memory.forget.btn", name)) {
                            forgetTyped = ""
                            forgetTarget = name
                        }
                        .buttonStyle(CompactButtonStyle())
                        .disabled(daemon.rollbackBusy)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

extension RollbackDiffResponse.File: Identifiable {
    public var id: String { path }
}
