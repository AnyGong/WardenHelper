import Foundation

/// User-facing text (Simplified Chinese) for the settings window, menu and notifications.
enum L10n {
    // MARK: Status-bar menu — network section
    static let ipLoading = "正在获取…"
    static let refreshing = "正在刷新…"
    static let ipUnknown = "无法获取"
    static let ipCopyTip = "点击复制公网 IP 地址"
    /// The dropdown's first row: a label, so the address is not mistaken for the local one.
    static func ipRow(_ value: String) -> String { "公网 IP：\(value)" }

    static let vpnMenuStateOn = "VPN 已连接"
    static let vpnMenuStateOff = "VPN 未连接"
    static func vpnDetail(tunnel: String, uptime: String) -> String { "隧道 \(tunnel) · 已连接 \(uptime)" }
    static let vpnMenuStateProxy = "系统代理已启用"
    static func proxyDetail(_ what: String) -> String { "系统代理 · \(what)" }
    static let hideIPMenu = "隐藏 IP 地址"
    static let hideIPMenuTip = "录屏或共享屏幕时使用；菜单栏和菜单中的 IP 显示为 •••。也可在「设置 › 通用 › 隐私」中修改"
    static let refreshIPTip = "重新获取公网 IP 和出口地区（应用会在网络变化时自动刷新）"

    // MARK: Status-bar menu — subscription section
    static let subMenuHeader = "订阅"
    static let subMenuHeaderTip = "显示的订阅在「设置 › 显示 › 菜单栏 › 订阅用量」中选择；点击下面任意一行可立即更新"
    static func subMenuHeaderNamed(_ name: String) -> String { "订阅 · \(name)" }
    static let subMenuUpdating = "更新中…"
    static let subMenuTip = "点击立即更新"
    static let subMenuNoData = "暂无流量 / 到期信息"
    static let subMenuSnapshotTag = "快照"
    static func subMenuTraffic(_ t: String, snapshot: Bool) -> String {
        snapshot ? "剩余流量：\(t)（\(subMenuSnapshotTag)）" : "剩余流量：\(t)"
    }
    static func subMenuReset(_ r: String) -> String { "下次重置：\(r)" }
    static func subMenuExpiry(_ e: String) -> String { "到期：\(e)" }

    // MARK: Status-bar menu — traffic section
    static let trafficHeader = "VPN 流量"
    static let trafficHeaderTip = "仅统计经代理节点的流量，直连不计入；各节点的明细见「节点流量报表」"
    static let trafficToday = "今日"
    static let trafficTodayTip = "今天 00:00 起"
    static let trafficMonth = "本月"
    static let trafficMonthTip = "本月 1 日 00:00 起"
    static let trafficSession = "本次启动"
    static let trafficSessionTip = "自 WardenHelper 本次启动起；退出后重新计"
    static let trafficUnavailable = "不可用"
    static func trafficUnavailableReason(_ reason: String) -> String { "不可用 · \(reason)" }

    // MARK: Status-bar menu — actions
    static let refreshIP = "刷新公网 IP"
    static let nodeStatsMenu = "节点流量报表…"
    static let resetTrafficRowTitle = "重置流量统计"
    static let resetTrafficRowDesc = "清零下拉菜单中的今日、本月、本次启动流量和节点流量报表；不影响订阅、设置和已写入的流量日志"
    static let resetTrafficButton = "重置…"
    static let resetTrafficTitle = "重置 VPN 流量统计？"
    static let resetTrafficMessage = "今日、本月、本次启动的累计流量以及各节点的流量统计都会清零，此操作无法撤销。已写入的流量日志不会被删除。"
    static let settings = "设置…"
    static let quit = "退出 WardenHelper"
    static let quitConfirmTitle = "退出 WardenHelper？"
    static let quitConfirmMessage = "退出后菜单栏将不再显示网速，也不会继续记录流量。"
    static let quitConfirmButton = "退出"

    // Duration units
    static let unitDay = "天"
    static let unitHour = "小时"
    static let unitMinute = "分"
    static let unitSecond = "秒"

    // MARK: Settings window — tabs
    static let tabMenuBar = "菜单栏"
    static let tabDropdown = "下拉菜单"
    static let tabSubscription = "订阅管理"
    static let tabAlerts = "通知提醒"
    static let tabGeneral = "通用"
    static let tabRules = "解析规则"
    static let tabTrafficSettings = "统计设置"
    static let tabTrafficReport = "流量报表"
    static let tabBlock = "断开屏蔽"
    static let tabAIEgress = "AI 出口"
    // Sidebar groups
    static let groupDisplay = "显示"
    static let groupSubscription = "订阅"
    static let groupTraffic = "流量"
    static let groupNetwork = "VPN 与网络"
    static let groupApp = "应用"
    // Window titles: the full name of each page
    static let headingMenuBar = "菜单栏显示"
    static let headingDropdown = "下拉菜单内容"
    static let headingSubscription = "订阅管理"
    static let headingRules = "订阅解析规则"
    static let headingTrafficSettings = "流量统计设置"
    static let headingTrafficReport = "节点流量报表"
    static let headingBlock = "VPN 断开时屏蔽"
    static let headingAIEgress = "AI 服务出口检测"
    static let headingAlerts = "通知提醒"
    static let headingGeneral = "通用"
    // Section headers
    static let sectionLayout = "布局"
    static let sectionRegionIP = "地区与 IP"
    static let sectionVPNState = "VPN 状态"
    static let sectionController = "数据来源"
    static let sectionControllerNote = "WardenHelper 通过代理内核的控制器读取代理流量，用于下拉菜单的 VPN 流量、节点流量报表和代理速度；VPN 连接后才开始读取。"
    static let sectionReportSummary = "统计概览"
    static let sectionReportPeriod = "统计周期"
    static let sectionReportNodes = "节点明细"
    static let sectionTrafficLog = "流量日志"
    static let sectionTrafficData = "统计数据"
    static let sectionLaunch = "启动"
    static let sectionPrivacy = "隐私"
    static let sectionBlockFile = "规则文件"
    static let sectionBlockHelper = "特权助手"
    static let sectionBlockLog = "屏蔽日志"
    static let sectionData = "数据管理"

    // MARK: Menu bar: VoiceOver summary of the status item
    static let axVPNOn = "VPN 已连接"
    static let axVPNOff = "VPN 未连接"
    static func axExit(_ name: String) -> String { "出口 \(name)" }
    static func axTraffic(_ t: String) -> String { "剩余流量 \(t)" }
    static let axQuotaWarning = "流量或到期时间告急"
    static let axQuotaCritical = "流量已用尽或套餐已到期"
    static let axProxyOn = "系统代理已启用"

    // MARK: Menu bar: exit country as a short Chinese name

    private static let regionNames: [String: String] = [
        "HK": "香港", "MO": "澳门", "TW": "台湾", "CN": "中国", "JP": "日本", "KR": "韩国", "KP": "朝鲜",
        "SG": "新加坡", "US": "美国", "CA": "加拿大", "GB": "英国", "DE": "德国", "FR": "法国",
        "NL": "荷兰", "IT": "意大利", "ES": "西班牙", "PT": "葡萄牙", "CH": "瑞士", "AT": "奥地利",
        "BE": "比利时", "LU": "卢森堡", "IE": "爱尔兰", "IS": "冰岛", "SE": "瑞典", "NO": "挪威",
        "FI": "芬兰", "DK": "丹麦", "PL": "波兰", "CZ": "捷克", "SK": "斯洛伐克", "HU": "匈牙利",
        "RO": "罗马尼亚", "BG": "保加利亚", "GR": "希腊", "RS": "塞尔维亚", "HR": "克罗地亚",
        "SI": "斯洛文尼亚", "EE": "爱沙尼亚", "LV": "拉脱维亚", "LT": "立陶宛", "UA": "乌克兰",
        "BY": "白俄罗斯", "MD": "摩尔多瓦", "RU": "俄罗斯", "TR": "土耳其", "CY": "塞浦路斯",
        "MT": "马耳他", "GE": "格鲁吉亚", "AM": "亚美尼亚", "AZ": "阿塞拜疆", "KZ": "哈萨克斯坦",
        "IL": "以色列", "AE": "阿联酋", "SA": "沙特", "QA": "卡塔尔", "KW": "科威特", "IR": "伊朗",
        "IQ": "伊拉克", "EG": "埃及", "MA": "摩洛哥", "DZ": "阿尔及利亚", "NG": "尼日利亚",
        "KE": "肯尼亚", "ZA": "南非", "IN": "印度", "PK": "巴基斯坦", "BD": "孟加拉", "LK": "斯里兰卡",
        "NP": "尼泊尔", "TH": "泰国", "VN": "越南", "MY": "马来西亚", "ID": "印尼", "PH": "菲律宾",
        "KH": "柬埔寨", "LA": "老挝", "MM": "缅甸", "MN": "蒙古", "AU": "澳大利亚", "NZ": "新西兰",
        "MX": "墨西哥", "BR": "巴西", "AR": "阿根廷", "CL": "智利", "CO": "哥伦比亚", "PE": "秘鲁",
        "VE": "委内瑞拉", "EC": "厄瓜多尔", "UY": "乌拉圭", "PA": "巴拿马", "CR": "哥斯达黎加",
        "DO": "多米尼加", "PR": "波多黎各"
    ]

    /// Short Chinese name for a two-letter country code: the table above first, then the
    /// system's Simplified Chinese name with the long suffixes trimmed, then the code itself.
    static func regionName(_ code: String) -> String {
        let key = code.uppercased()
        if let name = regionNames[key] { return name }
        guard var name = Locale(identifier: "zh_Hans").localizedString(forRegionCode: key) else { return key }
        for suffix in ["特别行政区", "共和国", "联邦", "王国", "自治区"] {
            if name.hasSuffix(suffix), name.count > suffix.count { name = String(name.dropLast(suffix.count)) }
        }
        return name
    }

    // MARK: Settings window — section: menu bar display
    static let menuBarLayout = "排列方式"
    static let menuBarLayoutDesc = "单行横向排开；双行把每组内容分成上下两行，更省宽度，字体略小"
    static let layoutVertical = "双行"
    static let layoutHorizontal = "单行"
    static let sectionSpeed = "网速"
    static let showArrows = "显示方向箭头"
    static let showArrowsDesc = "用 ↑ ↓ 区分上传和下载，并省略“/s”"
    static let showFlag = "显示出口地区"
    static let showFlagDesc = "显示当前公网 IP 所在的国家 / 地区"
    static let showIPInstead = "改为显示公网 IP"
    static let showIPInsteadDesc = "在地区名称的位置显示公网 IP；需先开启上一项"
    static let showShield = "显示 VPN 状态图标"
    static let showShieldDesc = "已连接为实心图标，未连接带斜线"
    static let speedFromProxy = "仅统计代理流量的速度"
    static let speedFromProxyDesc = "VPN 连接时改为读取代理内核的数据，直连流量不计入；未连接或内核不可用时仍显示网卡速度。需先在「统计设置」连接控制器"
    static let vpnDownOnlyIcon = "VPN 断开时只显示状态图标"
    static let vpnDownOnlyIconDesc = "断开时隐藏其他内容，只留带斜线的图标；关闭则保留原有内容并调暗"
    static let sectionMenuInfo = "显示的信息块"
    static let sectionMenuInfoNote = "菜单从上到下依次为：公网 IP 与 VPN 状态（始终显示）→ AI 服务出口 → 订阅 → VPN 流量 → 刷新公网 IP、隐藏 IP 地址、设置、退出（始终显示）。这里只决定是否在菜单中显示，不影响后台检测、流量统计和通知。"
    static let menuBlockSubscription = "显示订阅用量"
    static let menuBlockSubscriptionDesc = "剩余流量、下次重置和到期时间，点击可立即更新；显示哪个订阅在「菜单栏」页的「订阅用量」中选择"
    static let menuBlockVPNTraffic = "显示 VPN 流量"
    static let menuBlockVPNTrafficDesc = "经代理的今日、本月和本次启动流量，附节点流量报表入口；需先在「统计设置」连接控制器"
    static let menuBlockAIServices = "显示 AI 服务出口"
    static let menuBlockAIServicesDesc = "各 AI 服务的出口地区和延迟，点击一行可立即重新检测；需开启「AI 出口」页的后台自动检测"
    static let sectionSubscription = "订阅用量"
    static let showSubscriptionInfo = "显示剩余流量与重置倒计时"
    static let showSubscriptionInfoDesc = "橙色表示低于预警值，红色表示已到期或流量用尽；预警值在「通知提醒」页设置"
    static let barSubscription = "显示的订阅"
    static let barSubFirst = "第一个有数据的订阅"
    static let barSubLeastTraffic = "剩余流量最少的"
    static let barSubSoonestExpiry = "最先到期的"
    static let sectionSubUpdate = "订阅更新"
    static let sectionQuotaAlert = "用量预警"
    static let sectionQuotaAlertNote = "预警值同时决定菜单栏和下拉菜单里订阅信息的颜色：橙色表示接近预警值，红色表示已到期或流量用尽。"
    static let lowTrafficThreshold = "流量预警值"
    static let lowTrafficThresholdDesc = "剩余流量低于此值时变橙；设为 0 则不预警"
    static let expiryThreshold = "到期预警值"
    static let expiryThresholdDesc = "距到期少于此天数时变橙；设为 0 则不预警"
    static let unitGB = "GB"
    static let unitDays = "天"
    static let hideIP = "隐藏 IP 地址"
    static let hideIPDesc = "菜单栏、下拉菜单、「AI 出口」页和提示中的公网 IP 显示为 •••，适合录屏或共享屏幕；点击复制得到的仍是真实地址"
    /// Menu bar: time left until the next traffic reset.
    static func barDays(_ d: Int) -> String { "剩 \(d) 天" }
    static let barResetToday = "剩 0 天"
    static let barResetPending = "待更新"   // the reset date has passed; waiting for a fresh update

    // MARK: Settings window — subscriptions tab
    static let subPickerTitle = "订阅"
    static let subAdd = "添加"
    static let subRemove = "删除"
    static let subNone = "暂无订阅"
    static let subUnnamed = "（未命名）"
    static func subDefaultName(_ n: Int) -> String { "订阅 \(n)" }
    static let subEnabled = "启用"
    static let subEnabledDesc = "关闭后不再自动更新，也不会显示在菜单栏"
    static let subDisabledSuffix = "（已停用）"
    static let subName = "名称"
    static let subLink = "链接"
    static let subLinkPlaceholder = "粘贴订阅链接 https://…"
    static let subInterval = "刷新间隔"
    static let subUnitMinutes = "分钟"
    static let subUnitHours = "小时"
    static let subUnitDays = "天"
    static let subLastUpdated = "上次更新"
    static let subRemaining = "剩余流量"
    static let subExpiry = "到期时间"
    static let subUpdateRow = "更新订阅"
    static let subUpdateNow = "立即更新"
    static let subUpdating = "更新中…"
    static let subSectionConfig = "订阅设置"
    static let subSectionStatus = "用量与更新"
    static let subLogSection = "更新日志"
    static let subLogCopy = "复制"
    static let subLogCopied = "已复制"
    static let subLogExport = "导出…"
    static let subLogButtonTip = "复制或导出的日志只保留链接的域名，不含令牌，可放心分享"
    static let subLogExportTitle = "导出更新日志"
    static func subLogFileHeader(_ name: String) -> String { "WardenHelper 更新日志 · \(name)" }
    static func subLogFileExported(_ date: String) -> String { "导出时间：\(date)" }
    static let subLogStartManual = "开始更新（手动）"
    static let subLogStartAuto = "开始更新（自动）"
    static let subUpdatedPlain = "更新成功"
    static func subLogDone(_ summary: String) -> String { "更新成功：\(summary)" }
    static let subNextReset = "下次重置"
    static let subRealtime = "实时"
    static let subSnapshotStale = "快照，可能过期"
    static let subSnapshotTimeUnknown = "快照时间未知"
    static let subResetPassed = "已过，待更新"
    static let subResetsToday = "今天重置"
    static let subTrafficTipRealtime = "来自订阅响应头 subscription-userinfo，为最近一次成功更新时的用量"
    static let subTrafficTipSnapshot = "来自节点名称，仅是订阅生成时的快照，不代表当前用量；实时剩余流量需由面板 / API 提供"
    static let subResetTip = "快照时间 + 节点名称中“距离下次重置剩余”的天数"
    static let subExpired = "已到期"
    static let subExpiresToday = "今天到期"
    static func subDaysLeft(_ d: Int) -> String { "剩余 \(d) 天" }
    static let subInvalidURL = "链接无效（需要 http:// 或 https://）"
    static let subNoInfo = "订阅中未找到流量 / 到期信息"
    static func subFailed(_ reason: String) -> String { "更新失败：\(reason)" }
    static func subUsingCache(_ reason: String?) -> String {
        reason.map { "更新失败（\($0)），显示缓存数据" } ?? "更新失败，显示缓存数据"
    }
    static func subRemoveTitle(_ name: String) -> String { "删除订阅“\(name)”？" }
    static let subRemoveMessage = "此操作无法撤销。"

    // MARK: Settings window — rules tab (regular expressions)
    static let ruleSectionPatterns = "提取规则"
    static let ruleInfoNode = "信息节点"
    static let ruleInfoNodeHint = "只有名称匹配的节点才会被读取下面三项"
    static let ruleTraffic = "剩余流量"
    static let ruleTrafficHint = "捕获 ① 数值 ② 单位"
    static let ruleReset = "重置天数"
    static let ruleResetHint = "捕获 ① 天数"
    static let ruleExpire = "到期日期"
    static let ruleExpireHint = "捕获 ① yyyy-MM-dd"
    static let ruleVerify = "验证并保存"
    static let ruleTesting = "测试中…"
    static let ruleAllOK = "规则可用，已保存"
    static func ruleSomeFailed(_ n: Int) -> String { "\(n) 项不可用，已恢复为上一次可用的规则" }
    static func ruleFoundNodes(_ n: Int) -> String { "命中 \(n) 个节点" }
    static func ruleFoundDays(_ n: Int) -> String { "\(n) 天" }
    static let ruleEmpty = "不能为空"
    static let ruleSyntax = "正则表达式无效"
    static func ruleGroups(need: Int, have: Int) -> String { "至少需要 \(need) 个捕获组（当前 \(have) 个）" }
    static let ruleNoSample = "没有可测试的订阅数据，请先更新订阅，或使用下方的粘贴测试"
    static let ruleNoMatch = "订阅中没有匹配的内容"
    static let ruleBadCapture = "捕获的内容格式不符"
    static let ruleScope = "适用范围"
    static let ruleScopeDesc = "选择某个订阅可单独设置它的规则，框内留空则沿用全局规则"
    static let ruleScopeGlobal = "全局默认"
    static func ruleInheritFailed(_ n: Int) -> String { "\(n) 项沿用的全局规则在此订阅中不可用，可在框内填写专用规则" }
    static let ruleSampleTitle = "粘贴测试"
    static let ruleSampleHint = "每行一个节点名称，用上方规则即时测试"
    static let ruleSampleEmpty = "在上方粘贴节点名称后，这里显示每条规则捕获到的内容"
    static func ruleSampleSummary(lines: Int, info: Int) -> String { "\(lines) 行 · 命中信息节点 \(info) 行" }
    static let ruleSampleNotInfo = "未命中信息节点规则"
    static let ruleSampleNothing = "是信息节点，但没有提取到内容"

    // MARK: Settings window — section: VPN alerts
    static let notifyOnVPNChange = "VPN 状态通知"
    static let notifyOnVPNChangeDesc = "VPN 连接、断开和 WardenHelper 启动时发送系统通知；断开时带提示音"
    static let notifyOnResume = "唤醒 / 解锁后通知"
    static let notifyOnResumeDesc = "从睡眠、锁屏或屏保回来后，通知当前 VPN 状态；需开启上一项"
    static let popupOnDisconnect = "弹窗提醒"
    static let popupOnDisconnectDesc = "WardenHelper 启动、VPN 断开或重新连接、唤醒或解锁后弹出提示窗口；未连接时窗口一直显示，连上后自动关闭"
    // Pop-up window shown when the VPN drops, or when WardenHelper starts without a VPN
    static let vpnPopupDroppedTitle = "VPN 断开了，请注意安全"
    static let vpnPopupLaunchTitle = "还没有连接 VPN"
    static let vpnPopupDroppedBody = "你的网络流量正在直接走本地网络，不再受 VPN 保护。此时访问的网站和服务能看到你的真实 IP，账号与隐私都有暴露的风险。"
    static let vpnPopupLaunchBody = "WardenHelper 启动时没有检测到 VPN 连接。在连上之前，你访问的网站和服务能看到你的真实 IP，建议先连接 VPN，再继续上网。"
    static func vpnPopupStatus(_ interface: String?) -> String {
        interface.map { "当前为直连状态（\($0)）" } ?? "当前为直连状态"
    }
    static let vpnPopupConnectedTitle = "VPN 已连接，网络受保护"
    static let vpnPopupConnectedBody = "WardenHelper 已在菜单栏运行，你的公网流量正在通过 VPN 转发，真实 IP 已被隐藏，可以放心上网。"
    static func vpnPopupStatusOn(_ interface: String?) -> String {
        interface.map { "当前流量经由 VPN 转发（\($0)）" } ?? "当前流量经由 VPN 转发"
    }
    static let vpnPopupReconnectedTitle = "VPN 已连接，网络恢复保护"
    static let vpnPopupReconnectedBody = "VPN 已经连上，你的公网流量重新通过 VPN 转发，真实 IP 再次被隐藏，可以继续放心使用。"
    static let vpnPopupResumeOnTitle = "欢迎回来，VPN 连接正常"
    static let vpnPopupResumeOnBody = "刚刚检测了一下：唤醒 / 解锁之后，你的公网流量仍然通过 VPN 转发，网络处于受保护状态。"
    static let vpnPopupResumeOffTitle = "欢迎回来，但 VPN 没有连接"
    static let vpnPopupResumeOffBody = "唤醒 / 解锁后检测到 VPN 未连接，你的流量正在直接走本地网络，访问的网站和服务能看到你的真实 IP。请先连接 VPN，再继续上网。"
    static let vpnPopupConnectedTipLead = "温馨提示：  "
    static let vpnPopupConnectedTipText = "如果 VPN 意外断开，WardenHelper 会立即发送通知并弹窗提醒你。"
    static let vpnPopupTipLead = "小提醒：  "
    static let vpnPopupTipText = "先暂停登录、下载和付款等敏感操作，等 VPN 连上后再继续。连接成功后，这个提示会自动关闭。"
    static let vpnPopupOpenNetwork = "打开网络设置"
    static let vpnPopupDismiss = "我知道了"
    static let notifyOnSubscription = "更新结果通知"
    static let notifyOnSubscriptionDesc = "手动更新总会通知；自动更新成功时通知，连续失败时只通知第一次"
    static let notifySubOKTitle = "✅ 订阅已更新"
    static let notifySubFailTitle = "⚠️ 订阅更新失败"
    static let notifyOnQuota = "预警通知"
    static let notifyOnQuotaDesc = "流量或到期状态变差时通知一次（正常 → 橙色 → 红色）"
    static let quotaLowTitle = "🟠 流量不足"
    static let quotaEmptyTitle = "🔴 流量已用尽"
    static let quotaExpiringTitle = "🟠 套餐即将到期"
    static let quotaExpiredTitle = "🔴 套餐已到期"
    static func quotaLowNote(limitGB: Int) -> String { "已低于预警值 \(limitGB) GB" }
    static func quotaExpiringNote(limitDays: Int) -> String { "少于预警值 \(limitDays) 天" }

    // MARK: Settings window — section: general
    static let launchAtLogin = "开机自动启动"
    static let restartOnCrash = "异常退出后自动重启"
    static let restartOnCrashDesc = "WardenHelper 意外崩溃后自动重新打开；正常退出不会重启"
    static let refreshRate = "刷新频率"
    static let seconds1 = "1 秒"
    static let seconds2 = "2 秒"
    static let seconds5 = "5 秒"
    static let lockInterface = "监测网卡"
    static let lockInterfaceDesc = "“自动”汇总所有物理网卡；选定后只统计这一块网卡的速度。显示代理流量速度时不受此项影响"

    // MARK: Settings window — block rules (VPN 与网络 › 断开屏蔽)
    static let blockLogRow = "日志位置"
    static let vpnAlertsSection = "VPN 状态"
    static let blockEnabled = "VPN 断开时屏蔽"
    static let blockEnabledDesc = "VPN 未连接期间，屏蔽规则文件中列出的网站、进程和 IP；连上 VPN 后自动解除。需先安装下方的特权助手"
    static let blockFileNote = "规则文件是一个 JSON 数组，每一项可包含 domain、domain_suffix、domain_keyword、process_name、process_path、ip_cidr，值为字符串或字符串数组；保存后自动重新加载并检查。"
    static let blockHelperNote = "助手以管理员权限在后台运行，负责设置防火墙规则、屏蔽域名解析并结束指定进程；卸载时会恢复 DNS 设置。"
    static let blockPath = "规则文件"
    static let blockChoose = "选择…"
    static let blockChooseTitle = "选择屏蔽规则文件"
    static let blockChoosePrompt = "选择"
    static let blockStatus = "规则状态"
    static let blockEdit = "编辑"
    static let blockShowFile = "在访达中显示"
    static func blockLoaded(_ n: Int) -> String { "已加载 \(n) 条规则" }
    static let blockMissing = "文件不存在"
    static let blockNotLoaded = "正在读取…"
    static let blockPathNotAbsolute = "路径需要以 / 或 ~ 开头"
    static let blockUnreadable = "无法读取文件"
    static func blockErrorAtLine(_ line: Int, _ message: String) -> String { "第 \(line) 行：\(message)" }
    static func blockKeptOldRules(_ n: Int) -> String { "（仍在使用上一份可用规则，\(n) 条）" }
    static let blockErrTooLarge = "文件超过 1 MB"
    static let blockErrTooMany = "规则超过 5000 条"
    static let blockErrEmptyFile = "文件是空的"
    static let blockErrSyntax = "JSON 格式错误"
    static let blockErrNotArray = "最外层必须是数组 [ … ]"
    static func blockErrNotObject(_ n: Int) -> String { "第 \(n) 项不是对象 { … }" }
    static func blockErrEmptyObject(_ n: Int) -> String { "第 \(n) 项是空对象" }
    static func blockErrUnknownKey(_ n: Int, _ key: String) -> String { "第 \(n) 项有未知字段“\(key)”" }
    static func blockErrValueType(_ n: Int, _ key: String) -> String { "第 \(n) 项的“\(key)”必须是字符串或字符串数组" }
    static func blockErrInvalid(_ n: Int, _ key: String, _ value: String, _ why: String) -> String {
        "第 \(n) 项 \(key)“\(value)”：\(why)"
    }
    static let blockWhyEmpty = "不能为空"
    static let blockWhyBadDomain = "域名无效（非英文域名请写成 xn-- 形式）"
    static let blockWhyBadKeyword = "关键字无效（仅限小写字母、数字、- _ .；非英文请写成 xn-- 形式）"
    static let blockWhyKeywordShort = "关键字过短（至少 3 个字符）"
    static let blockWhyWildcard = "精确域名不能带 *.，请改用 domain_suffix"
    static let blockWhyBadProcess = "进程名无效"
    static let blockWhyBadPath = "路径无效（需为绝对路径，至少两级，不含 . 或 ..）"
    static let blockWhyProtected = "受保护的系统进程，不能屏蔽"
    static let blockWhyBadAddress = "IP 或 CIDR 无效"
    static let blockWhyTooBroad = "范围过大（/0）"
    static let blockWhyLoopback = "包含本机回环地址"

    // Menu row while blocking is on
    static func blockMenuActive(_ n: Int) -> String { "屏蔽中 · \(n) 条规则" }
    static let blockMenuFailed = "屏蔽启用失败，正在重试"
    static let blockMenuTip = "VPN 断开期间按规则屏蔽网站、进程和 IP；规则在「设置 › VPN 与网络 › 断开屏蔽」中管理"

    // MARK: Settings window — block helper (VPN 与网络 › 断开屏蔽 › 特权助手)
    static let helperTitle = "安装状态"
    static let helperChecking = "检测中…"
    static let helperNotInstalled = "未安装：需要先安装助手，屏蔽才会生效"
    static let helperInstalled = "已安装，可以使用"
    static let helperNeedsUpdate = "助手版本较旧，请更新后再使用"
    static let helperInstall = "安装…"
    static let helperUpdate = "更新…"
    static let helperUninstall = "卸载…"
    static let helperInstalling = "正在安装…"
    static let helperUninstalling = "正在处理…"
    static let helperInstallPrompt = "WardenHelper 需要管理员权限来安装或更新屏蔽助手。"
    static let helperUninstallPrompt = "WardenHelper 需要管理员权限来卸载屏蔽助手，并恢复 DNS 设置。"
    static let helperMissingBundled = "应用中没有助手程序，请使用 make 构建的 WardenHelper.app"
    static func helperFailed(_ why: String) -> String { why.isEmpty ? "操作失败" : "操作失败：\(why)" }

    // MARK: Settings window — traffic settings (流量 › 统计设置: controller, traffic log)
    static let controllerAddress = "控制器地址"
    static let controllerAddressDesc = "代理内核的 external-controller 地址，如 127.0.0.1:9090；留空则自动检测"
    static let controllerAddressAuto = "自动检测"
    static let controllerSecret = "密钥"
    static let controllerSecretDesc = "控制器设置了 secret 时填写；保存在系统钥匙串，不随导出文件备份"
    static let controllerSecretPlaceholder = "未设置"
    static let controllerStatus = "连接状态"
    static let controllerTest = "测试连接"
    static let logTraffic = "记录流量日志"
    static let logTrafficDesc = "每小时一个文件，保存在 ~/Library/Logs/WardenHelper/traffic/，文件名含该小时的流量（GB），可用来核对统计"
    static let logShowRow = "日志位置"
    static let logShowButton = "在访达中显示"
    static let controllerTesting = "正在测试…"
    static let controllerWaitingVPN = "VPN 连接后开始读取"
    static func controllerConnected(_ version: String) -> String { "已连接 \(version)" }
    static func controllerTestOK(version: String, parsed: Int, total: Int, outbounds: Int) -> String {
        "已连接 \(version) · 连接 \(parsed)/\(total) 条可解析 · 出站 \(outbounds) 个"
    }
    static func controllerTestPartial(version: String, parsed: Int, total: Int) -> String {
        "已连接 \(version)，但 \(total) 条连接中只有 \(parsed) 条可解析（字段可能与预期不同）"
    }
    static let controllerNotFound = "未找到控制器"
    static let controllerUnauthorized = "密钥错误 (401)"
    static let controllerSecretMissing = "需要密钥 (401)"
    static let controllerBadAddress = "地址无效"
    static let controllerBadResponse = "响应无法识别"
    static func controllerUnreachable(_ address: String) -> String { "无法连接 \(address)" }
    static func controllerFailure(_ f: ControllerFailure) -> String {
        switch f {
        case .notFound: return controllerNotFound
        case .unauthorized: return controllerUnauthorized
        case .secretMissing: return controllerSecretMissing
        case .badAddress: return controllerBadAddress
        case .badResponse: return controllerBadResponse
        case .unreachable(let address): return controllerUnreachable(address)
        }
    }

    static let resetRowTitle = "恢复默认设置"
    static let resetRowDesc = "所有设置回到初始值；订阅、流量统计和控制器密钥不受影响"
    static func aboutVersion(_ v: String) -> String { "版本 \(v)" }
    static let resetButton = "重置…"
    static let resetTitle = "恢复默认设置？"
    static let resetMessage = "所有设置都会恢复为初始值，此操作无法撤销。流量统计、订阅和控制器密钥不受影响。"
    static let resetConfirm = "重置"
    static let cancel = "取消"

    // MARK: Settings window — export / import
    static let backupRowTitle = "导出 / 导入"
    static let backupRowDesc = "把设置和订阅列表保存为文件，用于备份或迁移到另一台 Mac；控制器密钥不包含在内"
    static let backupExportButton = "导出…"
    static let backupImportButton = "导入…"
    static let backupOK = "好"
    static let backupExportTitle = "导出设置"
    static let backupExportMessage = "订阅链接带有访问令牌，请妥善保管导出的文件。"
    static let backupExportPrompt = "导出"
    static let backupIncludeSubscriptions = "包含订阅列表（含链接）"
    static let backupExportFailed = "导出失败"
    static let backupImportTitle = "导入设置"
    static let backupImportPrompt = "导入"
    static let backupImportFailed = "无法导入"
    static let backupNotReadable = "这不是有效的 WardenHelper 设置文件。"
    static let backupTooNew = "此文件来自更新版本的 WardenHelper，请先升级后再导入。"
    static let backupTooLarge = "文件过大，不像是 WardenHelper 设置文件。"
    static let backupEmpty = "文件中没有可导入的内容。"
    static let backupConfirmTitle = "导入设置？"
    static let backupConfirmButton = "导入"
    static let backupWillReplaceSettings = "当前的设置会被文件中的设置替换（监测网卡除外）。"
    static func backupWillMergeSubscriptions(_ n: Int) -> String {
        "文件中的 \(n) 个订阅会合并到列表：相同的更新，新的添加，其余保留，并立即刷新。"
    }
    static let backupDoneTitle = "导入完成"
    static func backupDoneMessage(settings: Bool, added: Int?, updated: Int?) -> String {
        var parts: [String] = []
        if settings { parts.append("设置已恢复") }
        if let added = added, let updated = updated { parts.append("订阅：新增 \(added) 个，更新 \(updated) 个") }
        return parts.joined(separator: "；")
    }

    // MARK: Notifications (markers: 🟢 connected, 🔴 dropped, ⚪️ not in use)
    static let vpnActive = "🟢 VPN 已连接"
    static let vpnInactive = "⚪️ VPN 未连接"
    static let notifyVPNOnTitle = "🟢 VPN 已连接"
    static let notifyVPNOffTitle = "🔴 VPN 已断开"
    static func notifyVPNOnBody(_ interface: String?) -> String {
        interface.map { "公网流量已通过 VPN（\($0)）转发" } ?? "公网流量已通过 VPN 转发"
    }
    static func notifyVPNOffBody(_ interface: String?) -> String {
        interface.map { "已切换为直连（\($0)），公网流量不再经过 VPN" } ?? "已切换为直连，公网流量不再经过 VPN"
    }
    // Status prompt after sleep / lock / screensaver, once the user is back
    static func resumeVPNOffBody(_ interface: String?) -> String {
        interface.map { "当前为直连（\($0)），公网流量未经过 VPN" } ?? "当前为直连，公网流量未经过 VPN"
    }
    static let resumeOfflineTitle = "⚪️ 当前无网络"
    static let resumeOfflineBody = "暂时无法判断 VPN 状态"

    // Launch notification (every start)
    static let welcomeTitle = "WardenHelper 已在菜单栏运行"
    static let welcomeVPNOn = "🟢 当前已连接 VPN"
    static let welcomeVPNOff = "⚠️ 当前未连接 VPN，请注意隐私安全"

    // MARK: Network interface names (settings dropdown)
    static let autoAllInterfaces = "自动（物理网卡）"
    static func network(_ n: String) -> String { "网络 (\(n))" }
    static func vpnTunnel(_ n: String) -> String { "VPN 隧道 (\(n))" }
    static func cellular(_ n: String) -> String { "蜂窝网络 (\(n))" }
    static func interfaceOffline(_ label: String) -> String { "\(label) · 未连接" }

    // MARK: Settings sidebar search
    static let settingsSearchPlaceholder = "搜索设置"
    static let settingsSearchNoResults = "没有找到相关设置"

    // MARK: Traffic report page (流量 › 流量报表)
    /// Tab labels, in `StatsPeriod` order. 1 天 / 本周 / 本月 are calendar periods.
    static let statsPeriodTitles = ["15 分钟", "30 分钟", "1 小时", "6 小时", "12 小时", "1 天", "本周", "本月"]
    static let nodeColumnName = "节点"
    static let nodeColumnUp = "上传"
    static let nodeColumnDown = "下载"
    static let nodeColumnTotal = "合计"
    static let nodeUnknown = "未知节点"
    static let nodeStatsEmpty = "此时间段内没有节点流量"
    static func nodeStatsRange(_ period: StatsPeriod, since: String) -> String {
        period.isCalendar ? "统计区间：\(since) 起（自然\(period == .day ? "日" : period == .week ? "周" : "月")）"
                          : "统计区间：最近 \(period.title)（\(since) 起）"
    }
    static func nodeStatsFooter(count: Int, up: String, down: String) -> String {
        "共 \(count) 个节点   合计：↑ \(up)   ↓ \(down)"
    }
    static let nodeStatsSearchPlaceholder = "搜索节点名称"
    static let nodeStatsSearchTip = "模糊搜索：忽略大小写，字符按顺序出现即可；空格分隔多个关键词，需同时满足"
    static let nodeStatsNoMatch = "没有匹配的节点"
    static func nodeStatsFooterFiltered(count: Int, total: Int, up: String, down: String) -> String {
        "匹配 \(count) / \(total) 个节点   合计：↑ \(up)   ↓ \(down)"
    }
    static let nodeStatsNote = "仅统计经代理节点的流量，直连不计入；点击表头可按该列升序 / 降序排序。"

    // MARK: AI 出口 (VPN 与网络 › AI 出口; the bar icon is under 菜单栏 › AI 状态)
    static let aiSectionSettings = "检测设置"
    static let aiSectionServices = "各服务出口"
    static let aiLatencyNote = "延迟是整次探测请求的耗时，包含连接与 TLS 握手。"
    static let sectionAIBar = "AI 状态"
    static let aiRefreshInterval = "检测间隔"
    static let aiRefreshIntervalDesc = "每隔多少秒检测一次，可填 3–3600，默认 60；网络或 VPN 变化后会自动加测一次"
    static let aiBackgroundCheck = "后台自动检测"
    static let aiBackgroundCheckDesc = "开启后，即使不打开本页也会定时检测，结果用于下拉菜单、菜单栏图标和变化通知；关闭后只在本页打开时检测"
    static let aiMenuHeader = "AI 服务出口"
    static let aiMenuHeaderTip = "各 AI 服务当前经哪个国家 / 地区出口及延迟；点击任意一行立即重新检测"
    static let aiShowBarIcon = "显示 AI 状态图标"
    static let aiShowBarIconDesc = "显示在地区之后：ChatGPT、Claude、Grok、Gemini 的出口都在期望地区时为实心，否则带斜线。需开启「AI 出口」页的后台自动检测"
    static let aiExpectedRegion = "期望出口地区"
    static let aiExpectedRegionDesc = "四个 AI 服务的出口都在此地区才算正常，默认台湾"
    static let axAINormal = "AI 服务出口正常"
    static func axAIAbnormal(_ region: String) -> String { "AI 服务出口异常，应为\(region)" }
    static let aiMenuFailed = "检测失败"
    static let aiMenuClickTip = "点击立即重新检测"
    static let sectionAIAlerts = "AI 服务"
    static let notifyOnAIRegion = "AI 出口地区变化通知"
    static let notifyOnAIRegionDesc = "某个 AI 服务的出口国家 / 地区与上一次检测不同时通知；需开启「AI 出口」页的后台自动检测"
    static let notifyAIRegionTitle = "AI 出口地区已变化"
    static func notifyAIRegionBody(_ from: String, _ to: String) -> String {
        "\(AIServiceMonitor.flagEmoji(from)) \(regionName(from))  →  \(AIServiceMonitor.flagEmoji(to)) \(regionName(to))"
    }
    static let aiRefreshNow = "手动检测"
    static let aiRefreshButton = "立即检测"
    static let aiChecking = "检测中..."
    static let aiRefreshing = "检测中..."
    static let aiLoadingMark = "..."
    static let aiNoIP = "未匹配到有效 IP"
    static let aiNoIPGoogle = "未匹配到有效 IP（请检查代理的分流状况）"
    static let aiLocalIP = "返回的是本地地址，非出口 IP（网络切换中，请稍后重试）"
    static let aiTimedOut = "请求超时"
    static let aiCannotResolve = "无法解析域名"
    static let aiCannotConnect = "连接失败"
    static let aiTLSFailed = "TLS 连接失败"
    static let aiRequestFailed = "请求失败"
    static let aiFailedPrefix = "检测失败："
    static let aiLabelIP = "出口 IP"
    static let aiLabelNode = "CF 节点"
    static let aiLabelOwner = "IP 归属"
    static let aiUnknownPlace = "未知地区"
    static func aiUpdatedAt(_ time: String) -> String { "最近检测 \(time)" }
}
