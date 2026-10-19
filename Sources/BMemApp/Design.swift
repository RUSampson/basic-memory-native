import SwiftUI

/// Design tokens were taken from the references design/screenshots/*.png (UI-2).
extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }

    /// Window content background
    static let bmemWindow = Color(hex: 0x1C1C1E)
    /// Sidebar background (slightly lighter than the content, as in the references)
    static let bmemSidebar = Color(hex: 0x26262A)
    /// Card background
    static let bmemCard = Color(hex: 0x2C2C2E)
    /// Accent
    static let bmemAccent = Color(hex: 0x0A84FF)
    /// Secondary text
    static let bmemSecondary = Color(hex: 0x8E8E93)
    /// Green status/toggles
    static let bmemGreen = Color(hex: 0x30D158)
    /// Orange warning
    static let bmemOrange = Color(hex: 0xFF9F0A)
    /// Green info-banner background
    static let bmemGreenBanner = Color(hex: 0x1E3A28)
    /// Orange warning-banner background
    static let bmemOrangeBanner = Color(hex: 0x3A2E1E)
}

enum Radius {
    /// Card corner radius (8-10 on the references)
    static let card: CGFloat = 10
    /// Compact button/chip corner radius (6)
    static let control: CGFloat = 6
}

/// Section card: background #2C2C2E, radius 10, inner padding 16.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.bmemCard, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

/// A compact system button (28-32 px, radius 6) — not custom «squares».
struct CompactButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                prominent
                    ? AnyShapeStyle(Color.bmemAccent)
                    : AnyShapeStyle(Color.white.opacity(configuration.isPressed ? 0.14 : 0.08)),
                in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

/// A note banner under the cards (green info / orange warning).
struct NoteBanner: View {
    enum Tone { case info, warning }

    let tone: Tone
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tone == .info ? Color.bmemGreen : Color.bmemOrange)
                .frame(width: 10, height: 10)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(tone == .info ? Color.bmemGreen : Color.bmemOrange)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            tone == .info ? Color.bmemGreenBanner : Color.bmemOrangeBanner,
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
    }
}

/// A segment row as in references 05/06: one row across the whole card width,
/// the selected segment — a solid blue plate with white text, the rest —
/// gray text on the container dark background.
struct SegmentedRow: View {
    let options: [(id: String, title: String)]
    let selection: String
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.id) { option in
                let selected = option.id == selection
                Button { onSelect(option.id) } label: {
                    Text(option.title)
                        .font(.system(size: 13, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? Color.white : Color.bmemSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(
                            selected ? AnyShapeStyle(Color.bmemAccent)
                                     : AnyShapeStyle(Color.white.opacity(0.06)),
                            in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.black.opacity(0.25),
                    in: RoundedRectangle(cornerRadius: Radius.control + 2, style: .continuous))
    }
}
