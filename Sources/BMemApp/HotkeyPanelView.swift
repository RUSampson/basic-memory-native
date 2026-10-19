// UI-6: the hotkey panel content per the reference design/screenshots/08-hotkey-panel.png.
// A search field with a magnifier and a «⌘↵ open» chip, trust segments, rows
// «scoring · title · subtitle», a footer «N hits in X s · local» /
// «esc close · ⌘↵ open note». UI-8: strings — Localizable.xcstrings;
// the row subtitle is built here from the raw PanelRow fields (kind/source/
// mtime) so the language switches instantly while BMemAPI stays language-independent.
import SwiftUI
import BMemAPI

struct HotkeyPanelView: View {
    @EnvironmentObject private var model: PanelSearchModel
    @EnvironmentObject private var controller: HotkeyPanelController
    @ObservedObject private var l10n = L10n.shared

    @State private var text = ""
        @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

            SegmentedRow(options: [("all", L("trust.all")),
                                   ("human", L("trust.human")),
                                   ("agent", L("trust.agent"))],
                          selection: model.trust) { newValue in
                model.setTrust(newValue)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            resultsList

            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 640, height: 480, alignment: .top)
        .background(Color.bmemWindow.opacity(0.92))
        .foregroundStyle(.white)
        // The stand (--panel-shot) sets the query in the model before the first
        // render — onChange will not catch it, pull it into the field on appear.
        .onAppear { text = model.query }
        .onChange(of: model.focusRequest) { _, _ in
            searchFocused = true
        }
        // --panel-shot/stand sets the query in the model directly — the field
        // must show it, as in the reference (otherwise the placeholder would stay).
        .onChange(of: model.query) { _, newValue in
            if text != newValue { text = newValue }
        }
        .onChange(of: text) { _, newValue in
            // A sync from the model (onAppear/stand) must not restart, let alone
            // cancel, an already-flying fetch.
            if newValue != model.query { model.setQuery(newValue) }
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(Color.bmemAccent)
            TextField("", text: $text, prompt: Text(L("panel.placeholder"))
                .foregroundStyle(Color.bmemSecondary))
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
                .onSubmit { controller.openSelected(activate: true) }
            Button(L("panel.open.btn")) { controller.openSelected(activate: false) }
                .buttonStyle(CompactButtonStyle())
                .disabled(model.selectedRow == nil)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color.white.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: Radius.control + 2, style: .continuous))
    }

    // MARK: - Results

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        resultRow(row, selected: index == model.selection)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.select(index: index)
                                controller.openSelected(activate: true)
                            }
                    }
                    if let err = model.lastError {
                        Text(Lf("panel.err.daemon", err))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.bmemOrange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 16)
                    }
                }
                .padding(.horizontal, 8)
            }
            .onChange(of: model.selection) { _, new in
                withAnimation(.easeOut(duration: 0.08)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    /// «session/note · agent/human · date» — labels from the catalog, the date —
    /// PanelDate in the current language locale.
    private func subtitle(_ row: PanelRow) -> String {
        var parts = [L(row.kind?.lowercased() == "session" ? "panel.kind.session" : "panel.kind.note"),
                     L(row.source == "agent" ? "panel.source.agent" : "panel.source.human")]
        if let iso = row.mtime, let date = PanelDate.parse(iso) {
            parts.append(PanelDate.text(date, lang: l10n.effectiveLang))
        }
        return parts.joined(separator: " · ")
    }

    private func resultRow(_ row: PanelRow, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Text(row.scoreText)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.bmemGreen)
                .frame(width: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.system(size: 14, weight: selected ? .medium : .regular))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle(row))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.bmemSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if selected {
                Text(L("panel.open.row"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.bmemSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            ZStack(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(Color.bmemAccent.opacity(0.18))
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.bmemAccent)
                        .frame(width: 3)
                        .padding(.vertical, 6)
                }
            }
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(leftFooter)
                .font(.system(size: 11))
                .foregroundStyle(Color.bmemSecondary)
            Spacer()
            Text(L("panel.footer.keys"))
                .font(.system(size: 11))
                .foregroundStyle(Color.bmemSecondary)
        }
        .overlay(alignment: .top) {
            Divider().opacity(0.4)
        }
    }

    /// «4 hits in 0.4 s · local»; while flying — «searching…»; empty — a hint.
    private var leftFooter: String {
        if model.searching { return L("panel.searching") }
        guard let ms = model.lastLatencyMs, !model.rows.isEmpty else {
            return model.lastError == nil ? L("panel.type") : L("panel.offline")
        }
        return Lf("panel.hits.line", l10n.pk("plural.hit", model.rows.count),
                  String(format: "%.1f", ms / 1000))
    }
}
