import SwiftUI
import BMemAPI

/// The six sidebar sections. The order follows design/screenshots;
/// the texts (UI-8) come from Localizable.xcstrings under keys section.<id>.title/.subtitle.
/// rawValue is a stable English id: it is also the card id and the
/// --section=<case> matching in the click test; it never changes with the language.
enum Section: String, CaseIterable, Identifiable {
    case whatRead = "whatRead"
    case permissions = "permissions"
    case memory = "memory"
    case search = "search"
    case advanced = "advanced"
    case system = "system"

    var id: String { rawValue }
    var title: String { L("section.\(rawValue).title") }

    /// Section subtitles — verbatim from the references, kept in the catalog.
    var subtitle: String { L("section.\(rawValue).subtitle") }

    var symbol: String {
        switch self {
        case .whatRead: return "doc.text.magnifyingglass"
        case .permissions: return "lock.shield"
        case .memory: return "clock.arrow.circlepath"
        case .search: return "magnifyingglass"
        case .advanced: return "slider.horizontal.3"
        case .system: return "gearshape"
        }
    }
}
