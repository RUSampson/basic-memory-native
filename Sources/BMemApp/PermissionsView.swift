import SwiftUI
import ServiceManagement

/// Screen 3 (reference 03-permissions.png): the honest status of the two
/// permissions — Full Disk Access (a real read probe) and background activity
/// (SMAppService), plus enable steps and the agents card. UI-8: strings — the catalog.
struct PermissionsView: View {
    @ObservedObject private var l10n = L10n.shared

    @State private var fdaGranted = false
    @State private var loginStatus: SMAppService.Status = .notRegistered

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(Section.permissions.title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                Text(Section.permissions.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.bmemSecondary)

                fdaCard
                backgroundCard
                agentsCard
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.bmemWindow)
        .navigationTitle(Section.permissions.title)
        .task { recheck() }
    }

    private func recheck() {
        fdaGranted = FDACheck.isGranted()
        loginStatus = SMAppService.mainApp.status
    }

    /// The label and the text are joined with a space here: in the catalog the
    /// values canonically have no trailing spaces.
    private func whyLines(_ lines: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                (Text(line.0 + " ").foregroundStyle(Color.bmemSecondary)
                 + Text(line.1).foregroundStyle(Color.bmemSecondary))
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: — Full Disk Access

    private var fdaCard: some View {
        Card {
            HStack(spacing: 10) {
                Circle()
                    .fill(fdaGranted ? Color.bmemGreen : Color.bmemSecondary)
                    .frame(width: 14, height: 14)
                Text(L("perms.fda.title"))
                    .font(.system(size: 14, weight: .semibold))
                Text(fdaGranted ? L("perms.fda.granted") : L("perms.fda.denied"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(fdaGranted ? Color.bmemGreen : Color.bmemOrange)
                Spacer()
                Button(L("common.recheck")) { recheck() }
                    .buttonStyle(CompactButtonStyle())
            }

            whyLines([
                (L("perms.why.fda.1a"), L("perms.why.fda.1b")),
                (L("perms.why.fda.2a"), L("perms.why.fda.2b")),
                (L("perms.why.fda.3a"), L("perms.why.fda.3b")),
            ])

            if !fdaGranted {
                Divider().overlay(Color.white.opacity(0.06))
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("perms.how"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(L("perms.how.1"))
                    Text(L("perms.how.2"))
                    Text(L("perms.how.3"))
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.bmemSecondary)
                .fixedSize(horizontal: false, vertical: true)

                Button(L("common.grant")) { FDACheck.openSettings() }
                    .buttonStyle(CompactButtonStyle(prominent: true))
            }
        }
    }

    // MARK: - Background activity

    private var backgroundCard: some View {
        Card {
            HStack(spacing: 10) {
                Circle()
                    .fill(loginStatus == .enabled ? Color.bmemGreen : Color.bmemSecondary)
                    .frame(width: 14, height: 14)
                Text(L("perms.bg.title"))
                    .font(.system(size: 14, weight: .semibold))
                Text(loginStatus == .enabled ? L("perms.bg.on") : L("perms.bg.needed"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(loginStatus == .enabled ? Color.bmemGreen : Color.bmemOrange)
                Spacer()
            }

            whyLines([
                (L("perms.why.fda.1a"), L("perms.why.bg.1b")),
                (L("perms.why.fda.2a"), L("perms.why.bg.2b")),
                (L("perms.why.bg.3a"), L("perms.why.bg.3b")),
            ])
        }
    }

    // MARK: - About agents

    private var agentsCard: some View {
        Card {
            Text(L("perms.agents"))
                .font(.system(size: 12))
                .foregroundStyle(Color.bmemSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
