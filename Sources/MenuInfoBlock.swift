import Foundation

/// The information blocks of the dropdown menu. Each one has its own switch in Settings
/// (菜单栏 > 下拉菜单), shown or hidden independently of the others.
///
/// To add a block: add a case here (key, title, description), then add its rows in `AppDelegate`
/// with `addInfoItem(_:block:to:)`. The Settings row, the stored preference and the
/// reset / export / import handling follow from this enum.
enum MenuInfoBlock: String, CaseIterable {
    // Declared in menu order (top to bottom); the Settings page lists them the same way.
    case aiServices
    case subscription
    case vpnTraffic

    /// UserDefaults key (default on).
    var preferenceKey: String { "showMenuBlock.\(rawValue)" }

    var title: String {
        switch self {
        case .subscription: return L10n.menuBlockSubscription
        case .vpnTraffic:   return L10n.menuBlockVPNTraffic
        case .aiServices:   return L10n.menuBlockAIServices
        }
    }

    var detail: String? {
        switch self {
        case .subscription: return L10n.menuBlockSubscriptionDesc
        case .vpnTraffic:   return L10n.menuBlockVPNTrafficDesc
        case .aiServices:   return L10n.menuBlockAIServicesDesc
        }
    }
}
