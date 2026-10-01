import Cocoa

/// The 菜单栏 > 订阅用量 pop-up that picks which subscription the menu bar shows: automatic (first
/// with data), the one with the least traffic, the one expiring first, or one specific link.
/// The list follows the subscription list live, so a link added in the 订阅管理 tab appears here
/// without reopening the window.
final class BarSubscriptionPicker: NSObject {

    let row: SettingRow
    private let popup: ClosurePopUpButton
    private var signature = ""
    private var observer: NSObjectProtocol?

    override init() {
        let popup = ClosurePopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .regular
        popup.font = NSFont.systemFont(ofSize: ControlMetrics.fontSize)
        popup.target = popup
        popup.action = #selector(ClosurePopUpButton.fire)
        self.popup = popup
        self.row = SettingRow(title: L10n.barSubscription, control: popup,
                              controlSize: NSSize(width: 230, height: 0))
        super.init()

        popup.onChange = { [weak popup] _ in
            let stored = popup?.selectedItem?.representedObject as? String
            Preferences.shared.barSubscription = SubscriptionBarChoice(stored: stored)
        }
        rebuild()
        observer = NotificationCenter.default.addObserver(
            forName: SubscriptionManager.changedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildIfNeeded()
        }
    }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func currentSignature() -> String {
        SubscriptionManager.shared.items.map { "\($0.id)|\($0.name)|\($0.enabled)" }.joined(separator: "\n")
    }

    /// Every log line of a running update posts the change notification; only a changed list rebuilds.
    private func rebuildIfNeeded() {
        if currentSignature() != signature { rebuild() }
    }

    private func rebuild() {
        signature = currentSignature()
        popup.removeAllItems()

        func add(_ title: String, _ choice: SubscriptionBarChoice) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = choice.stored
            popup.menu?.addItem(item)
        }
        add(L10n.barSubFirst, .first)
        add(L10n.barSubLeastTraffic, .leastTraffic)
        add(L10n.barSubSoonestExpiry, .soonestExpiry)

        let items = SubscriptionManager.shared.items
        if !items.isEmpty { popup.menu?.addItem(NSMenuItem.separator()) }
        for sub in items {
            var title = sub.name.isEmpty ? L10n.subUnnamed : sub.name
            if !sub.enabled { title += L10n.subDisabledSuffix }
            add(title, .specific(sub.id))
        }

        // Select the stored choice; a choice that no longer exists shows as the automatic one.
        let stored = Preferences.shared.barSubscription.stored
        let index = (popup.menu?.items ?? []).firstIndex { ($0.representedObject as? String) == stored } ?? 0
        popup.selectItem(at: index)
    }
}
