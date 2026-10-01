import Cocoa

/// Status-bar content. One layout setting (`Preferences.stackedLayout`) controls everything.
///
/// VPN connected, side by side:
///
///   140 GB · 剩 25 天  │  ↑ 2.1 KB  ↓ 3.1 KB  │  🛡 香港   (with arrows the "/s" is dropped)
///
/// VPN connected, top and bottom:
///
///   140 GB     │  ↑ 2.1 KB  │  香港
///   剩 25 天   │  ↓ 3.1 KB  │  🛡
///
/// VPN not connected: by default everything else disappears and only the icon remains, with a
/// diagonal slash through it. With "只显示状态图标" off, the normal bar stays, its text and arrows
/// dimmed to 50%, and the icon carries the same slash.
///
/// Groups, left to right: subscription (remaining traffic + days until the next reset), live
/// speeds (fixed-width slots, so the item never resizes while values change), and the connection
/// icons (VPN shield + exit country name or IP).
///
/// Colour rules ("monochrome when normal, variation when abnormal"):
/// - Normal state is monochrome: everything uses `labelColor` (black in light mode, white in dark
///   mode), so nothing asks for attention. There is no green "all good" colour.
/// - Quota alerts use colour: orange = warning, red = critical (subscription text only).
/// - A VPN fault uses shape: the icon (`lock.icloud.fill`) is slashed, and it is the
///   only thing left in the bar, so no other alert competes with it.
/// - Shield and speed arrows use pure white (dark mode) / pure black (light mode) at full
///   opacity; the arrows are small and bold, and take only their own width.
///
/// Numbers use SF's tabular digits.
final class MenuBarView: NSView {

    // Core data
    private var rawUpload: String = "0 B/s"
    private var rawDownload: String = "0 B/s"
    /// Two-letter exit country code, e.g. "HK"; empty while unknown.
    private var regionCode: String = ""
    /// Chinese short name of that country / region, e.g. "香港"; empty while unknown.
    private var regionName: String = ""
    private var currentIP: String = "..."
    private var isVPN: Bool = false
    /// A system proxy is on while no VPN tunnel is active: not a fault, the shield slot shows
    /// a network glyph instead of the slashed shield.
    private var isProxy: Bool = false
    /// False until the first VPN reading arrives, so launch does not flash the fault icon.
    private var vpnKnown: Bool = false
    /// Remaining traffic + reset countdown + severity (nil = no subscription data).
    private var subInfo: SubscriptionBarInfo?
    /// AI service status icon after the region: solid = normal, slashed = abnormal, nil = not shown.
    private var aiState: AIServiceMonitor.Overall?

    /// The VPN is known to be down.
    private var vpnDown: Bool { vpnKnown && !isVPN && !isProxy }
    /// VPN down and the setting says so: the bar shows only the slashed shield.
    private var statusOnly: Bool { vpnDown && Preferences.shared.vpnDownShowsOnlyIcon }
    /// VPN down but the bar stays: its text and arrows are dimmed to 50%.
    private var dimmed: Bool { vpnDown && !statusOnly }

    // MARK: Layout mode

    /// Top-and-bottom layout: two rows in the 22 pt bar, so everything is a little smaller.
    private var isStacked: Bool { Preferences.shared.stackedLayout }

    // MARK: Fonts (SF Pro with tabular digits for every live number)

    /// Side by side: one point above the system menu-bar text size (13 pt on macOS, the native
    /// clock and date), read from the system rather than hard-coded.
    private static let systemBarSize: CGFloat = NSFont.menuBarFont(ofSize: 0).pointSize
    private static let rowFont = NSFont.monospacedDigitSystemFont(ofSize: systemBarSize + 1, weight: .regular)
    /// Top and bottom: two rows must fit in the 22 pt bar, so two points smaller than the system size, with a clear gap between the rows.
    private static let stackedFont = NSFont.monospacedDigitSystemFont(ofSize: systemBarSize - 2, weight: .regular)
    private var textFont: NSFont { isStacked ? Self.stackedFont : Self.rowFont }

    // MARK: Colors (monochrome by default; orange / red only for alerts)

    private static let textColor = NSColor.labelColor
    /// Dividers: solid white in dark mode, solid black in light mode, no transparency.
    private static let separatorColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor.white : NSColor.black
    }
    /// Icons (arrows, shield): pure white in dark mode, pure black in light mode, full opacity.
    private static let iconColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor.white : NSColor.black
    }

    // MARK: Layout constants

    private let edgePadding: CGFloat = 2.0
    private let itemGap: CGFloat = 3.0                 // region <-> shield (side by side)
    private static let groupGap: CGFloat = 16.0        // total space around a separator (line + margin on each side)
    private static let dotDiameter: CGFloat = 3.0      // middle dot between the VPN icon and the region text
    private static let dotGap: CGFloat = 4.0           // space on each side of that dot
    private static let dotPitch: CGFloat = 5.5         // advance of one masked-IP dot
    private static let arrowGap: CGFloat = 3.5         // speed arrow -> value
    private static let pairGap: CGFloat = 6.0          // up slot -> down slot (side by side)
    private static let rowGap: CGFloat = 3.5           // space between the two text rows (top and bottom)

    // MARK: Glyphs

    /// One VPN icon for every state: the solid `lock.icloud.fill`, drawn as large as the 22 pt bar
    /// allows (a cloud is wider than tall, so the box is its width and the height is about 3/4 of it).
    /// Connected = solid white / black (`iconColor`, no green); disconnected = the same icon with the
    /// diagonal slash. Stacked layout: sized to the bottom row under the region text.
    private static let vpnSymbol = "lock.icloud.fill"
    private static let shieldBox: CGFloat = 23.0
    private static let stackedShieldBox: CGFloat = 14.0
    private static let shieldDownBox: CGFloat = shieldBox
    private static let shieldOnBox: CGFloat = shieldBox
    private static let stackedShieldOnBox: CGFloat = stackedShieldBox
    private static let shieldOn = makeGlyph(named: vpnSymbol, color: iconColor, box: shieldOnBox, pointSize: 22, weight: .regular)
    private static let stackedShieldOn = makeGlyph(named: vpnSymbol, color: iconColor, box: stackedShieldOnBox, pointSize: 14, weight: .regular)
    /// Before the first VPN reading arrives: the same solid icon (no colour change at launch).
    private static let shieldUnknown = shieldOn
    private static let stackedShieldUnknown = stackedShieldOn
    /// VPN not connected: the same icon, full opacity, with the diagonal slash.
    private static let shieldDown = makeSlashedGlyph(named: vpnSymbol, color: iconColor, box: shieldDownBox, pointSize: 22, weight: .regular)
    /// The same slashed icon sized for the stacked layout (the bar stays, VPN down).
    private static let stackedShieldDown = makeSlashedGlyph(named: vpnSymbol, color: iconColor, box: stackedShieldBox, pointSize: 14, weight: .regular)
    /// Row centers inside the 22 pt bar for the region / shield column (top and bottom).
    private static let stackedBottomCenter: CGFloat = 5.5

    /// AI status: `sparkles`, the symbol for AI, in the same white / black as the other icons.
    /// Normal = solid; abnormal = the same icon with the diagonal slash.
    private static let aiSymbol = "sparkles"
    private static let aiBox: CGFloat = 17.0
    private static let stackedAIBox: CGFloat = 14.0
    private static let aiOn = makeGlyph(named: aiSymbol, color: iconColor, box: aiBox, pointSize: 16, weight: .regular)
    private static let aiOff = makeSlashedGlyph(named: aiSymbol, color: iconColor, box: aiBox, pointSize: 16, weight: .regular)
    private static let stackedAIOn = makeGlyph(named: aiSymbol, color: iconColor, box: stackedAIBox, pointSize: 13, weight: .regular)
    private static let stackedAIOff = makeSlashedGlyph(named: aiSymbol, color: iconColor, box: stackedAIBox, pointSize: 13, weight: .regular)

    /// System proxy without a tunnel: outline network glyph, same colour as the VPN icon.
    private static let proxyOn = makeGlyph(named: "network", color: iconColor, box: 18.0, pointSize: 16, weight: .regular) ?? shieldUnknown
    private static let stackedProxyOn = makeGlyph(named: "network", color: iconColor, box: 12.0, pointSize: 10.5, weight: .regular) ?? stackedShieldUnknown

    // Small, bold arrows: the slot reserves only the glyph's real width (see `arrowReserve`).
    private static let rowArrowBox: CGFloat = 11.0
    private static let stackedArrowBox: CGFloat = 8.0
    private static let arrowUpRow = makeGlyph(named: "arrow.up", color: iconColor, box: rowArrowBox, pointSize: 11, weight: .bold)
    private static let arrowDownRow = makeGlyph(named: "arrow.down", color: iconColor, box: rowArrowBox, pointSize: 11, weight: .bold)
    private static let arrowUpStacked = makeGlyph(named: "arrow.up", color: iconColor, box: stackedArrowBox, pointSize: 8, weight: .bold)
    private static let arrowDownStacked = makeGlyph(named: "arrow.down", color: iconColor, box: stackedArrowBox, pointSize: 8, weight: .bold)

    /// Built once; the drawing handler runs at draw time, so colors follow light / dark.
    private static func makeGlyph(named name: String, color: NSColor, box: CGFloat,
                                  pointSize: CGFloat, weight: NSFont.Weight) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let symbol = base.withSymbolConfiguration(config) ?? base
        let natural = symbol.size
        guard natural.width > 0, natural.height > 0 else { return nil }
        let scale = min(box / natural.width, box / natural.height)
        let fitted = NSSize(width: natural.width * scale, height: natural.height * scale)
        return NSImage(size: fitted, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceIn)
            return true
        }
    }

    /// Same as `makeGlyph`, with a diagonal slash (top left to bottom right) cut through the
    /// symbol: a transparent gap first, then a thin line in the middle of it. Pass a colour that
    /// already carries the wanted opacity.
    private static func makeSlashedGlyph(named name: String, color: NSColor, box: CGFloat,
                                         pointSize: CGFloat, weight: NSFont.Weight) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let symbol = base.withSymbolConfiguration(config) ?? base
        let natural = symbol.size
        guard natural.width > 0, natural.height > 0 else { return nil }
        let scale = min(box / natural.width, box / natural.height)
        let fitted = NSSize(width: natural.width * scale, height: natural.height * scale)
        return NSImage(size: fitted, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceIn)

            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX + 0.5, y: rect.maxY - 0.5))
            slash.line(to: NSPoint(x: rect.maxX - 0.5, y: rect.minY + 0.5))
            slash.lineCapStyle = .round

            NSGraphicsContext.current?.compositingOperation = .destinationOut
            slash.lineWidth = 3.6
            NSColor.black.setStroke()
            slash.stroke()

            NSGraphicsContext.current?.compositingOperation = .sourceOver
            slash.lineWidth = 1.4
            color.setStroke()
            slash.stroke()
            return true
        }
    }

    /// Width of one speed slot, cached per (arrows, layout) combination.
    private var slotCache: (key: Int, width: CGFloat)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    /// VPN connected and known.
    private var vpnConnected: Bool { vpnKnown && isVPN }

    // Let the status-bar button receive clicks (menu, highlight) directly.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Updates (only redraw on real change)

    func updateSpeeds(upload: String, download: String) {
        guard upload != rawUpload || download != rawDownload else { return }
        rawUpload = upload
        rawDownload = download
        needsDisplay = true
    }

    /// `code` is the two-letter country code ("" = unknown).
    func updateRegion(_ code: String, ip: String) {
        let clean = String(code.uppercased().prefix(2))
        guard clean != regionCode || ip != currentIP else { return }
        regionCode = clean
        regionName = clean.isEmpty ? "" : L10n.regionName(clean)
        currentIP = ip
        needsDisplay = true
    }

    func setVPN(_ active: Bool) {
        guard !vpnKnown || active != isVPN else { return }
        vpnKnown = true
        isVPN = active
        needsDisplay = true
    }

    func setProxy(_ active: Bool) {
        guard active != isProxy else { return }
        isProxy = active
        needsDisplay = true
    }

    /// `nil` hides the AI icon.
    func setAI(_ state: AIServiceMonitor.Overall?) {
        guard state != aiState else { return }
        aiState = state
        needsDisplay = true
    }

    func updateSubscription(_ info: SubscriptionBarInfo?) {
        guard info != subInfo else { return }
        subInfo = info
        needsDisplay = true
    }

    // MARK: - Vertical placement (all text is aligned by its digit height, not its line box)

    /// Bottom of the text box for a single row centered on the bar.
    private func singleRowY(_ font: NSFont, height: CGFloat) -> CGFloat {
        (height - font.capHeight) / 2.0 + font.descender
    }

    /// Bottom of the text box for row 0 (top) or row 1 (bottom) of a two-row stack.
    private func stackedRowY(_ row: Int, font: NSFont, height: CGFloat) -> CGFloat {
        let cap = font.capHeight
        let bottomBaseline = (height - (2 * cap + Self.rowGap)) / 2.0
        let baseline = row == 0 ? bottomBaseline + cap + Self.rowGap : bottomBaseline
        return baseline + font.descender
    }

    /// Vertical middle of the digits of a text box whose bottom is `y`.
    private func digitCenterY(boxBottom y: CGFloat, font: NSFont) -> CGFloat {
        y - font.descender + font.capHeight / 2.0
    }

    private var textAttributes: [NSAttributedString.Key: Any] {
        [.font: textFont, .foregroundColor: dimmed ? Self.textColor.withAlphaComponent(0.5) : Self.textColor]
    }

    // MARK: - Metrics

    private func textWidth(_ s: String, font: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: s, attributes: [.font: font]).size().width)
    }

    private var showsUp: Bool { let m = Preferences.shared.displayMode; return m == 0 || m == 1 }
    private var showsDown: Bool { let m = Preferences.shared.displayMode; return m == 0 || m == 2 }
    /// Upload and download on one row (needs both directions and the side-by-side layout).
    private var isSideBySide: Bool { showsUp && showsDown && !isStacked }

    // MARK: Dots (every dot in the bar is one drawn filled circle of `dotDiameter`, never a font glyph)

    /// Placeholder for a spaced separator dot (subscription row "140 GB • 25d").
    private static let spacedDot: Character = "\u{E000}"
    private static let bullet: Character = "\u{2022}"   // masked IP digits

    private func dotAdvance(_ ch: Character) -> CGFloat {
        ch == Self.spacedDot ? Self.dotDiameter + Self.dotGap * 2 : Self.dotPitch
    }

    private func isDot(_ ch: Character) -> Bool { ch == Self.bullet || ch == Self.spacedDot }

    /// Width of text in which `•` and the spaced-dot placeholder are drawn as circles.
    private func richWidth(_ s: String, font: NSFont) -> CGFloat {
        var w: CGFloat = 0
        var run = ""
        for ch in s {
            if isDot(ch) {
                if !run.isEmpty { w += textWidth(run, font: font); run = "" }
                w += dotAdvance(ch)
            } else { run.append(ch) }
        }
        if !run.isEmpty { w += textWidth(run, font: font) }
        return w
    }

    /// Draws text left-aligned at `x` (`y` = bottom of the text box); dots become uniform circles
    /// centered on the digits' height.
    private func drawRich(_ s: String, attributes: [NSAttributedString.Key: Any], font: NSFont,
                          x startX: CGFloat, y: CGFloat) {
        var x = startX
        var run = ""
        let dotColor = dimmed ? Self.iconColor.withAlphaComponent(0.5) : Self.iconColor
        func flush() {
            guard !run.isEmpty else { return }
            let a = NSAttributedString(string: run, attributes: attributes)
            a.draw(at: NSPoint(x: x, y: y))
            x += ceil(a.size().width)
            run = ""
        }
        for ch in s {
            if isDot(ch) {
                flush()
                let advance = dotAdvance(ch)
                let d = Self.dotDiameter
                dotColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: x + (advance - d) / 2.0,
                                            y: digitCenterY(boxBottom: y, font: font) - d / 2.0,
                                            width: d, height: d)).fill()
                x += advance
            } else { run.append(ch) }
        }
        flush()
    }

    // Speeds

    private var arrowBox: CGFloat { isStacked ? Self.stackedArrowBox : Self.rowArrowBox }

    /// What a reading looks like in the bar. With arrows the direction is already shown, so the
    /// "/s" is left out ("12 KB" instead of "12 KB/s"); the space before the unit is a thin one.
    /// The font size is untouched, only the characters that carry no information go.
    private func displaySpeed(_ raw: String) -> String {
        var s = raw
        if Preferences.shared.showArrows, s.hasSuffix("/s") { s.removeLast(2) }
        return s.replacingOccurrences(of: " ", with: "\u{2009}")
    }

    /// Width the arrow column really needs: the glyph itself, not the square it is fitted into.
    private var arrowReserve: CGFloat {
        let glyphs = isStacked ? [Self.arrowUpStacked, Self.arrowDownStacked] : [Self.arrowUpRow, Self.arrowDownRow]
        return ceil(glyphs.compactMap { $0?.size.width }.max() ?? arrowBox)
    }

    /// Width of one speed slot: arrow glyph (optional) + widest realistic reading ("999 MB").
    private func speedSlotWidth() -> CGFloat {
        let arrows = Preferences.shared.showArrows
        let key = (arrows ? 1 : 0) | (isStacked ? 2 : 0)
        if let cached = slotCache, cached.key == key { return cached.width }
        let text = max(textWidth(displaySpeed("999 MB/s"), font: textFont),
                       textWidth(displaySpeed("999 KB/s"), font: textFont))
        let width = text + (arrows ? arrowReserve + Self.arrowGap : 0)
        slotCache = (key, width)
        return width
    }

    private func speedBlockWidth() -> CGFloat {
        guard showsUp || showsDown else { return 0 }
        let slot = speedSlotWidth()
        return isSideBySide ? slot * 2 + Self.pairGap : slot
    }

    // Region code / shield

    /// Country name ("香港"), or the address itself when the "IP instead" option is on.
    private var regionText: String {
        if Preferences.shared.showIPInsteadOfFlag { return IPMask.displayed(currentIP) }
        return regionName.isEmpty ? "--" : regionName
    }

    /// Sized from the text itself: the exit country changes rarely, and the groups to its left
    /// simply shift when it does.
    private func regionSlotWidth() -> CGFloat {
        richWidth(regionText, font: textFont)
    }

    /// Region / IP over the shield in one column (top and bottom layout, both shown).
    private var stacksIcons: Bool {
        let p = Preferences.shared
        return p.stackedLayout && p.showFlag && p.showVPNShield
    }

    /// Box of the stacked shield: larger while connected.
    private var stackedShieldSlot: CGFloat {
        vpnConnected && !isProxy ? Self.stackedShieldOnBox : Self.stackedShieldBox
    }

    private var shieldSlot: CGFloat {
        if isStacked { return stackedShieldSlot }
        if vpnDown { return Self.shieldDownBox }
        return vpnConnected && !isProxy ? Self.shieldOnBox : Self.shieldBox
    }

    private var stackedColumnWidth: CGFloat {
        max(regionSlotWidth(), stackedShieldSlot)
    }

    /// The AI icon is shown (setting on, checks running and the first round done).
    private var showsAI: Bool { Preferences.shared.showAIStatus && aiState != nil }
    private var aiSlot: CGFloat { isStacked ? Self.stackedAIBox : Self.aiBox }

    /// Region / IP and/or VPN icon, as one block (the AI icon is added by `adornmentWidth`).
    private func connectionWidth() -> CGFloat {
        let prefs = Preferences.shared
        if stacksIcons { return stackedColumnWidth }
        var w: CGFloat = 0
        if prefs.showFlag { w += regionSlotWidth() }
        if prefs.showVPNShield {
            if w > 0 { w += Self.dotDiameter + Self.dotGap * 2 }
            w += shieldSlot
        }
        return w
    }

    private func adornmentWidth() -> CGFloat {
        var w = connectionWidth()
        if showsAI {
            if w > 0 { w += Self.dotDiameter + Self.dotGap * 2 }     // the same dot as before the region
            w += aiSlot
        }
        return w
    }

    // Subscription: plain text, sized from the actual text (it changes rarely, and the
    // right-anchored groups do not move when it does).

    private var visibleSubInfo: SubscriptionBarInfo? {
        Preferences.shared.showSubscription ? subInfo : nil
    }

    /// Side by side: one row "140 GB · 25d". Top and bottom: traffic over the reset countdown.
    private func subscriptionRows(_ info: SubscriptionBarInfo) -> [String] {
        let parts = [info.trafficText, info.resetText].compactMap { $0 }
        if isStacked || parts.count < 2 { return parts }
        return [parts.joined(separator: String(Self.spacedDot))]
    }

    private func subscriptionBlockWidth() -> CGFloat {
        guard let info = visibleSubInfo else { return 0 }
        return subscriptionRows(info).map { richWidth($0, font: textFont) }.max() ?? 0
    }

    /// Normal = the same monochrome as the rest of the bar; only alerts get a colour.
    private func subscriptionTextColor(_ severity: SubscriptionBarInfo.Status) -> NSColor {
        switch severity {
        case .ok:       return Self.textColor
        case .warning:  return .systemOrange
        case .critical: return .systemRed
        }
    }

    func calculateOptimalWidth() -> CGFloat {
        // VPN down (and the setting on): the slashed shield is the whole item.
        if statusOnly { return ceil(edgePadding * 2 + Self.shieldDownBox) }

        let groups = [subscriptionBlockWidth(), speedBlockWidth(), adornmentWidth()].filter { $0 > 0 }
        let total = edgePadding * 2 + groups.reduce(0, +) + Self.groupGap * CGFloat(max(0, groups.count - 1))
        return ceil(total)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let height = bounds.height

        // VPN down (and the setting on): no traffic, speeds or region, only the shield, centered.
        if statusOnly {
            let box = Self.shieldDownBox
            drawShield(in: NSRect(x: (bounds.width - box) / 2.0, y: (height - box) / 2.0,
                                  width: box, height: box))
            return
        }

        let adornments = adornmentWidth()
        let speeds = speedBlockWidth()
        let sub = subscriptionBlockWidth()

        var right = bounds.width - edgePadding

        // 1. Connection group (rightmost): shield left of the region code
        if adornments > 0 {
            drawAdornments(right: right, height: height)
            right -= adornments
            if speeds > 0 || sub > 0 {
                drawSeparator(right: right, height: height)
                right -= Self.groupGap
            }
        }

        // 2. Live speeds: arrow at the slot's left edge, value right-aligned, so units line up
        if speeds > 0 {
            drawSpeeds(right: right, height: height)
            right -= speeds
            if sub > 0 {
                drawSeparator(right: right, height: height)
                right -= Self.groupGap
            }
        }

        // 3. Subscription summary (leftmost)
        if sub > 0 { drawSubscription(right: right, width: sub, height: height) }
    }

    /// Thin, low-opacity divider centered in the gap that starts at `right` and runs left.
    private func drawSeparator(right: CGFloat, height: CGFloat) {
        let length: CGFloat = isStacked ? 16.0 : 13.0
        Self.separatorColor.setFill()
        NSRect(x: right - Self.groupGap / 2.0 - 0.5,
               y: (height - length) / 2.0,
               width: 1.0, height: length).fill()
    }

    /// Region text centered in its slot; `y` is the bottom of the text box.
    private func drawRegion(slotLeft: CGFloat, slotWidth: CGFloat, y: CGFloat) {
        let w = richWidth(regionText, font: textFont)
        drawRich(regionText, attributes: textAttributes, font: textFont,
                 x: slotLeft + (slotWidth - w) / 2.0, y: y)
    }

    private func drawAdornments(right startRight: CGFloat, height: CGFloat) {
        let prefs = Preferences.shared
        let font = textFont
        var right = startRight

        // AI status icon (rightmost, after the region) with the same middle dot in front of it.
        if showsAI {
            let box = aiSlot
            right -= box
            drawAI(in: NSRect(x: right, y: (height - box) / 2.0, width: box, height: box))
            if connectionWidth() > 0 {
                right -= Self.dotGap + Self.dotDiameter
                Self.iconColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: right, y: (height - Self.dotDiameter) / 2.0,
                                            width: Self.dotDiameter, height: Self.dotDiameter)).fill()
                right -= Self.dotGap
            }
        }

        if stacksIcons {
            // One column: region code (or IP) on top, VPN shield underneath, both centered.
            let column = stackedColumnWidth
            right -= column
            let base = (height - 22.0) / 2.0

            drawRegion(slotLeft: right, slotWidth: column,
                       y: stackedRowY(0, font: font, height: height))

            let box = stackedShieldSlot
            let center = Self.stackedBottomCenter + (box - Self.stackedShieldBox) / 2.0   // bottom edge stays put
            drawShield(in: NSRect(x: right + (column - box) / 2.0,
                                  y: base + center - box / 2.0,
                                  width: box, height: box))
            return
        }

        var drew = false

        // Region code or IP (rightmost)
        if prefs.showFlag {
            let slot = regionSlotWidth()
            right -= slot
            drawRegion(slotLeft: right, slotWidth: slot, y: singleRowY(font, height: height))
            drew = true
        }

        // VPN shield, immediately left of the region code
        if prefs.showVPNShield {
            if drew {
                // White (dark mode) / black (light mode) middle dot between the icon and the region text
                right -= Self.dotGap + Self.dotDiameter
                Self.iconColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: right, y: (height - Self.dotDiameter) / 2.0,
                                            width: Self.dotDiameter, height: Self.dotDiameter)).fill()
                right -= Self.dotGap
            }
            right -= shieldSlot
            drawShield(in: NSRect(x: right, y: (height - shieldSlot) / 2.0,
                                  width: shieldSlot, height: shieldSlot))
        }
    }

    private func drawSpeeds(right: CGFloat, height: CGFloat) {
        let font = textFont
        let centeredY = singleRowY(font, height: height)

        if showsUp && showsDown {
            if isSideBySide {
                drawSpeed(rawDownload, up: false, slotRight: right, y: centeredY)
                drawSpeed(rawUpload, up: true, slotRight: right - speedSlotWidth() - Self.pairGap, y: centeredY)
            } else {
                drawSpeed(rawUpload, up: true, slotRight: right, y: stackedRowY(0, font: font, height: height))
                drawSpeed(rawDownload, up: false, slotRight: right, y: stackedRowY(1, font: font, height: height))
            }
        } else if showsUp {
            drawSpeed(rawUpload, up: true, slotRight: right, y: centeredY)
        } else if showsDown {
            drawSpeed(rawDownload, up: false, slotRight: right, y: centeredY)
        }
    }

    /// One speed reading inside its slot; `y` is the bottom of the text box.
    private func drawSpeed(_ text: String, up: Bool, slotRight: CGFloat, y: CGFloat) {
        let s = NSAttributedString(string: displaySpeed(text), attributes: textAttributes)
        s.draw(at: NSPoint(x: slotRight - ceil(s.size().width), y: y))

        guard Preferences.shared.showArrows else { return }
        let stacked = isStacked
        let image = up ? (stacked ? Self.arrowUpStacked : Self.arrowUpRow)
                       : (stacked ? Self.arrowDownStacked : Self.arrowDownRow)
        guard let arrow = image else { return }
        let slotLeft = slotRight - speedSlotWidth()
        let centerY = digitCenterY(boxBottom: y, font: textFont)
        arrow.draw(in: NSRect(x: slotLeft + (arrowReserve - arrow.size.width) / 2.0,
                              y: centerY - arrow.size.height / 2.0,
                              width: arrow.size.width, height: arrow.size.height),
                   from: .zero, operation: .sourceOver, fraction: dimmed ? 0.5 : 1.0)
    }

    /// One row "140 GB · 25d" or two rows (traffic over reset countdown) in the top-and-bottom
    /// layout. Monochrome normally; orange (warning) or red (critical) for the whole block.
    private func drawSubscription(right: CGFloat, width: CGFloat, height: CGFloat) {
        guard let info = visibleSubInfo else { return }
        let rows = subscriptionRows(info)
        guard !rows.isEmpty else { return }

        let left = right - width
        let font = textFont
        let color = subscriptionTextColor(info.status)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: dimmed ? color.withAlphaComponent(0.5) : color
        ]
        let ys: [CGFloat] = rows.count == 2
            ? [stackedRowY(0, font: font, height: height), stackedRowY(1, font: font, height: height)]
            : [singleRowY(font, height: height)]
        for (text, y) in zip(rows, ys) {
            drawRich(text, attributes: attrs, font: font, x: left, y: y)
        }
    }

    /// Solid white / black `sparkles` when every AI service exits in the designated region; slashed otherwise.
    private func drawAI(in box: NSRect) {
        let normal = aiState == .normal
        let image = isStacked ? (normal ? Self.stackedAIOn : Self.stackedAIOff)
                              : (normal ? Self.aiOn : Self.aiOff)
        guard let image = image else { return }
        image.draw(in: NSRect(x: box.midX - image.size.width / 2.0, y: box.midY - image.size.height / 2.0,
                              width: image.size.width, height: image.size.height),
                   from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    /// Solid white / black lock.icloud.fill while a VPN is active; the same icon slashed when it is not.
    private func drawShield(in box: NSRect) {
        let image: NSImage?
        if vpnDown {
            image = (isStacked && !statusOnly) ? Self.stackedShieldDown : Self.shieldDown
        } else if isProxy {
            image = isStacked ? Self.stackedProxyOn : Self.proxyOn
        } else if !vpnKnown {
            image = isStacked ? Self.stackedShieldUnknown : Self.shieldUnknown
        } else {
            image = isStacked ? Self.stackedShieldOn : Self.shieldOn
        }
        guard let image = image else { return }
        image.draw(in: NSRect(x: box.midX - image.size.width / 2.0, y: box.midY - image.size.height / 2.0,
                              width: image.size.width, height: image.size.height),
                   from: .zero, operation: .sourceOver, fraction: 1.0)
    }
}
