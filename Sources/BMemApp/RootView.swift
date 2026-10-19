import SwiftUI

/// The main screen: a sidebar of six sections + content (references 02-07).
struct RootView: View {
    @EnvironmentObject private var daemon: DaemonModel
    @ObservedObject private var l10n = L10n.shared
    @State private var selection: Section = RootView.initialSection()

    /// The starting section: --section <case> for the click test, otherwise the first.
    static func initialSection() -> Section {
        if let want = argValue("section").map({ $0.lowercased() }),
           let s = Section.allCases.first(where: {
               String(describing: $0).lowercased() == want || $0.rawValue.lowercased() == want
           }) {
            return s
        }
        return .whatRead
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Section.allCases) { section in
                    SidebarItem(section: section, isSelected: selection == section) {
                        selection = section
                    }
                }
                Spacer()
                Text(Lf("sidebar.version", "BMem 1.1.2-beta3"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.bmemSecondary)
                    .padding(.bottom, 4)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.bmemSidebar)
            .navigationSplitViewColumnWidth(230)
        } detail: {
            Group {
                switch selection {
                case .whatRead: WhatReadView()
                case .permissions: PermissionsView()
                case .memory: MemoryView()
                case .search: SearchView()
                case .advanced: AdvancedView()
                case .system: SystemView()
                }
            }
            .id(selection)
            // UI-9: the duplicated section-title plate in the toolbar is hidden per the
            // owner remark: the .principal texts are commented out on the screens and
            // the navigationTitle heading was removed from the titlebar here. The
            // titlebar itself (traffic lights, sidebar button, window dragging) is
            // kept — .toolbar(.hidden, for: .windowToolbar) does not work: it removes
            // the whole strip together with the buttons (verified by shots on 16.10).
            .toolbar(removing: .title)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

/// A sidebar item: when selected — a solid blue plate with white text (as in the references).
private struct SidebarItem: View {
    let section: Section
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 12))
                    .frame(width: 18)
                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                isSelected ? AnyShapeStyle(Color.bmemAccent) : AnyShapeStyle(Color.clear),
                in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
