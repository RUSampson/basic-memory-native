import SwiftUI
import AppKit
import BMemAPI

/// Screen 2 (reference 02-what-i-read.png): index folders (add/remove/pause),
/// the read-only «what I never touch» list, the network banner + the LAN flag.
/// Everything live goes through GET/PUT /v1/config. UI-8: strings come from Localizable.xcstrings.
struct WhatReadView: View {
    @EnvironmentObject private var daemon: DaemonModel
    @ObservedObject private var l10n = L10n.shared

    /// Paused folders (toggle off): name -> path. Stored on the app side —
    /// the daemon config does not have them, «waiting» = not in projects.
    @AppStorage("pausedFolders") private var pausedJSON = "{}"

    /// md files per path; computed in the background (scanning a big folder takes seconds).
    @State private var counts: [String: Int] = [:]

    private var paused: [String: String] {
        get { (try? JSONDecoder().decode([String: String].self, from: Data(pausedJSON.utf8))) ?? [:] }
        nonmutating set { pausedJSON = String(data: (try? JSONEncoder().encode(newValue)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("whatread.title"))
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                Text(Section.whatRead.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.bmemSecondary)

                foldersCard
                neverTouchCard
                networkBanner
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.bmemWindow)
        .navigationTitle(Section.whatRead.title)
        .task { await daemon.refreshConfig() }
        .task(id: folderRows.map(\.path).joined(separator: "\n")) {
            for path in folderRows.map(\.path) where counts[path] == nil {
                counts[path] = await Task.detached(priority: .utility) { countMdFiles(in: path) }.value
            }
        }
    }

    // MARK: - Index folders

    private var foldersCard: some View {
        Card {
            HStack {
                Text(L("whatread.folders"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(L("whatread.add")) { addFolder() }
                    .buttonStyle(CompactButtonStyle())
            }

            let rows = folderRows
            if rows.isEmpty {
                Text(L("whatread.folders.empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bmemSecondary)
            }
            ForEach(rows) { row in
                Divider().overlay(Color.white.opacity(0.06))
                folderRow(row)
            }
        }
    }

    private struct FolderRow: Identifiable {
        let name: String
        let path: String
        let watched: Bool
        var id: String { path }
    }

    private var folderRows: [FolderRow] {
        var rows: [FolderRow] = []
        for (name, path) in daemon.config?.projects ?? [:] {
            rows.append(FolderRow(name: name, path: path, watched: true))
        }
        for (name, path) in paused where daemon.config?.projects[name] == nil {
            rows.append(FolderRow(name: name, path: path, watched: false))
        }
        return rows.sorted { $0.path < $1.path }
    }

    private func folderRow(_ row: FolderRow) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayPath(row.path))
                    .font(.system(size: 13, weight: .medium))
                    .textSelection(.enabled)
                Text("\(counts[row.path].map { l10n.pk("plural.file", $0) } ?? L("whatread.row.counting")) · \(row.watched ? L("whatread.row.watching") : L("whatread.row.pause"))")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bmemSecondary)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(
                get: { row.watched },
                set: { setWatched(row, on: $0) }
            ))
            .toggleStyle(.switch)
            .tint(Color.bmemGreen)
            .labelsHidden()
            Text(row.watched ? L("whatread.row.watching") : L("whatread.row.waiting"))
                .font(.system(size: 12))
                .foregroundStyle(Color.bmemSecondary)
                .frame(width: 44, alignment: .leading)
            Button {
                removeFolder(row)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bmemSecondary)
            }
            .buttonStyle(.plain)
            .help(L("whatread.row.remove.help"))
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("panel.open.prompt")
        panel.message = L("panel.open.message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var projects = daemon.config?.projects ?? [:]
        var p = paused
        let name = url.lastPathComponent
        projects[name] = url.path
        p[name] = nil
        paused = p
        Task { await daemon.putConfig(["projects": projects]) }
    }

    /// The toggle: off — the folder leaves projects (the index stops reading it),
    /// it stays in the list as «waiting»; on — it comes back.
    private func setWatched(_ row: FolderRow, on: Bool) {
        var projects = daemon.config?.projects ?? [:]
        var p = paused
        if on {
            projects[row.name] = row.path
            p[row.name] = nil
        } else {
            projects[row.name] = nil
            p[row.name] = row.path
        }
        paused = p
        Task { await daemon.putConfig(["projects": projects]) }
    }

    private func removeFolder(_ row: FolderRow) {
        var projects = daemon.config?.projects ?? [:]
        var p = paused
        projects[row.name] = nil
        p[row.name] = nil
        paused = p
        Task { await daemon.putConfig(["projects": projects]) }
    }

    // MARK: - What I never touch

    private var neverTouchCard: some View {
        Card {
            Text(L("whatread.exclude.title"))
                .font(.system(size: 14, weight: .semibold))
            Text((daemon.config?.never_touch ?? []).joined(separator: " · "))
                .font(.system(size: 12))
                .foregroundStyle(Color.bmemSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("whatread.exclude.note"))
                .font(.system(size: 12))
                .foregroundStyle(Color.bmemSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(L("whatread.exclude.add")) { excludePath() }
                    .buttonStyle(CompactButtonStyle())
                if let ex = daemon.config?.exclude_dirs, !ex.isEmpty {
                    Text(Lf("whatread.exclude.mine", ex.joined(separator: " · ")))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.bmemSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private func excludePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = L("whatread.exclude.prompt")
        panel.message = L("whatread.exclude.message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var dirs = daemon.config?.exclude_dirs ?? []
        guard !dirs.contains(url.path) else { return }
        dirs.append(url.path)
        Task { await daemon.putConfig(["exclude_dirs": dirs]) }
    }

    // MARK: - Network

    private var networkBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(Color.bmemGreen).frame(width: 10, height: 10)
                Text(L("whatread.net.banner"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bmemGreen)
                Spacer(minLength: 0)
            }
            Text(Lf("whatread.net.lan", lanText))
                .font(.system(size: 11))
                .foregroundStyle(Color.bmemSecondary)
                .padding(.leading, 20)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.bmemGreenBanner, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private var lanText: String {
        guard let cfg = daemon.config else { return L("whatread.net.lan.unknown") }
        return cfg.lan_access == true ? L("whatread.net.lan.on") : L("whatread.net.lan.off")
    }
}
