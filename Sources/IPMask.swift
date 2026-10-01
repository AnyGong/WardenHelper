import Foundation

/// The "hide IP" setting: what is shown instead of an address while it is on.
/// Only real addresses are masked; texts such as "..." or "无法获取" pass through.
enum IPMask {
    private static let ipv4Mask = "•••.•••.•••.•••"
    private static let ipv6Mask = "••••:••••:••••:••••"

    /// True for a string that looks like an IPv4 / IPv6 address.
    static func isAddress(_ text: String) -> Bool {
        guard text.contains(where: { $0.isNumber }) else { return false }
        return text.allSatisfy { $0.isHexDigit || $0 == "." || $0 == ":" }
    }

    /// The text to display: the mask while `Preferences.hideIP` is on and `text` is an address.
    static func displayed(_ text: String) -> String {
        guard Preferences.shared.hideIP, isAddress(text) else { return text }
        return text.contains(":") ? ipv6Mask : ipv4Mask
    }
}
