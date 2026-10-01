import Foundation

// Shared by WardenHelper and `warden-helper-daemon` (the helper build compiles this file too), so it may
// only use Foundation / Darwin. It holds the rule model and the one validator both sides run:
// WardenHelper when it reads the rules file, the helper again on everything it receives.

// MARK: - Limits

enum BlockLimits {
    static let maxFileBytes = 1_048_576      // 1 MB
    static let maxEntries = 5000
}

// MARK: - Rule model

enum BlockRuleKind: String, Codable {
    case domain
    case domainSuffix = "domain_suffix"
    case domainKeyword = "domain_keyword"
    case processName = "process_name"
    case processPath = "process_path"
    case ipCIDR = "ip_cidr"
}

/// One validated, normalised rule. `value` is what `BlockRuleValidator` returned: lower-case
/// names without a trailing dot, CIDRs with host bits masked.
struct BlockRule: Hashable, Codable {
    let kind: BlockRuleKind
    let value: String
}

/// Every rule of the file, split by kind and free of duplicates (first occurrence wins).
struct BlockRuleSet: Equatable, Codable {
    private(set) var rules: [BlockRule]

    static let empty = BlockRuleSet(rules: [])

    init(rules: [BlockRule]) {
        var seen = Set<BlockRule>()
        self.rules = rules.filter { seen.insert($0).inserted }
    }

    var count: Int { rules.count }
    var isEmpty: Bool { rules.isEmpty }

    private func values(_ kind: BlockRuleKind) -> [String] {
        rules.filter { $0.kind == kind }.map { $0.value }
    }
    var domains: [String] { values(.domain) }
    var domainSuffixes: [String] { values(.domainSuffix) }
    var domainKeywords: [String] { values(.domainKeyword) }
    var processNames: [String] { values(.processName) }
    var processPaths: [String] { values(.processPath) }
    var cidrs: [String] { values(.ipCIDR) }
}

// MARK: - Validation

enum BlockRuleIssue: Error, Equatable {
    case empty
    case badDomain
    case badKeyword                 // characters outside a-z 0-9 - _ .
    case keywordTooShort            // a 1-2 character keyword would match almost every name
    case wildcardInExactDomain      // `*.x.com` under `domain`
    case badProcessName
    case badProcessPath             // not absolute, has `.` / `..`, or too short (`/Applications`)
    case protectedProcess
    case badAddress
    case rangeTooBroad              // /0
    case includesLoopback           // would cut the helper's own sinkhole
}

enum BlockRuleValidator {

    static func normalize(_ raw: String, kind: BlockRuleKind) -> Result<String, BlockRuleIssue> {
        switch kind {
        case .domain:       return domain(raw, allowWildcard: false)
        case .domainSuffix: return domain(raw, allowWildcard: true)
        case .domainKeyword: return keyword(raw)
        case .processName:  return processName(raw)
        case .processPath:  return processPath(raw)
        case .ipCIDR:       return cidr(raw)
        }
    }

    // MARK: Domains

    /// Lower-case ASCII name, one trailing dot dropped. Labels are 1-63 characters of
    /// `a-z 0-9 - _` and do not start or end with `-`. Non-ASCII names must be written as
    /// punycode (`xn--…`). `allowWildcard` accepts and removes a leading `*.`.
    static func domain(_ raw: String, allowWildcard: Bool) -> Result<String, BlockRuleIssue> {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.isEmpty { return .failure(.empty) }
        if name.hasPrefix("*.") {
            guard allowWildcard else { return .failure(.wildcardInExactDomain) }
            name.removeFirst(2)
        }
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty, name.utf8.count <= 253 else { return .failure(.badDomain) }

        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
        for label in name.split(separator: ".", omittingEmptySubsequences: false) {
            guard (1...63).contains(label.utf8.count),
                  label.utf8.allSatisfy({ allowed.contains($0) }),
                  !label.hasPrefix("-"), !label.hasSuffix("-") else { return .failure(.badDomain) }
        }
        return .success(name)
    }

    /// Substring of a domain name (`domain_keyword`): lower-case ASCII of `a-z 0-9 - _ .`, at
    /// least `minKeywordLength` characters so a typo cannot sinkhole nearly every name.
    static let minKeywordLength = 3

    static func keyword(_ raw: String) -> Result<String, BlockRuleIssue> {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if word.isEmpty { return .failure(.empty) }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_.".utf8)
        guard word.utf8.count <= 253, word.utf8.allSatisfy({ allowed.contains($0) }) else {
            return .failure(.badKeyword)
        }
        guard word.utf8.count >= minKeywordLength else { return .failure(.keywordTooShort) }
        return .success(word)
    }

    // MARK: Processes

    /// System processes that must never be killed, and WardenHelper's own. A typo in the rules file
    /// must not be able to take the machine down.
    static let protectedProcessNames: Set<String> = [
        "launchd", "kernel_task", "windowserver", "loginwindow", "opendirectoryd", "configd",
        "mdnsresponder", "cfprefsd", "securityd", "distnoted", "wardenhelper", "warden-helper-daemon",
    ]

    /// Exact, case-sensitive process name; no path separators or control characters.
    static func processName(_ raw: String) -> Result<String, BlockRuleIssue> {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .failure(.empty) }
        guard name.utf8.count <= 128, !name.contains("/"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return .failure(.badProcessName) }
        if protectedProcessNames.contains(name.lowercased()) { return .failure(.protectedProcess) }
        return .success(name)
    }

    /// Places whose programs must never be killed: the system, the helper and WardenHelper. A rule may
    /// not be one of these, inside one, or a parent of one (`/usr`, `/Applications`).
    static let protectedPaths: [String] = [
        "/System", "/usr/bin", "/usr/sbin", "/usr/libexec", "/bin", "/sbin",
        "/Library/PrivilegedHelperTools/warden-helper-daemon", "/Applications/WardenHelper.app",
    ]

    static func isProtectedPath(_ path: String) -> Bool {
        protectedPaths.contains { p in
            path == p || path.hasPrefix(p + "/") || p.hasPrefix(path + "/")
        }
    }

    /// Absolute path of a program (`/Applications/QQ.app/Contents/MacOS/QQ`) or of a folder /
    /// app bundle (`/Applications/QQ.app`, which covers everything running from inside it).
    /// Case-sensitive, at least two components, no `.` or `..`; trailing `/` is dropped. The
    /// system reports the real path of a running program, so write `/private/tmp/x`, not `/tmp/x`.
    static func processPath(_ raw: String) -> Result<String, BlockRuleIssue> {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { return .failure(.empty) }
        guard path.hasPrefix("/"), path.utf8.count <= 1023,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return .failure(.badProcessPath) }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return .failure(.badProcessPath) }
        if isProtectedPath(path) { return .failure(.protectedProcess) }
        return .success(path)
    }

    // MARK: Addresses

    /// `1.2.3.4`, `1.2.3.0/24`, `2001:db8::/32`. A bare address is a host route (/32, /128).
    /// Host bits are masked (`211.2.3.1/23` -> `211.2.2.0/23`); the result is canonical text.
    static func cidr(_ raw: String) -> Result<String, BlockRuleIssue> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .failure(.empty) }

        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let addressText = String(parts[0])
        let isV6 = addressText.contains(":")
        let maxPrefix = isV6 ? 128 : 32

        var prefix = maxPrefix
        if parts.count == 2 {
            let p = parts[1]
            guard !p.isEmpty, p.utf8.count <= 3, p.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let n = Int(p), n <= maxPrefix else { return .failure(.badAddress) }
            prefix = n
        }

        var bytes = [UInt8](repeating: 0, count: isV6 ? 16 : 4)
        let parsed = bytes.withUnsafeMutableBytes { inet_pton(isV6 ? AF_INET6 : AF_INET, addressText, $0.baseAddress) }
        guard parsed == 1 else { return .failure(.badAddress) }
        if prefix == 0 { return .failure(.rangeTooBroad) }

        let network = masked(bytes, prefix: prefix)
        let loopback: [UInt8] = isV6 ? [UInt8](repeating: 0, count: 15) + [1] : [127, 0, 0, 1]
        if masked(loopback, prefix: prefix) == network || (!isV6 && network[0] == 127) {
            return .failure(.includesLoopback)
        }

        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let printed = network.withUnsafeBytes {
            inet_ntop(isV6 ? AF_INET6 : AF_INET, $0.baseAddress, &buffer, socklen_t(buffer.count))
        }
        guard printed != nil else { return .failure(.badAddress) }
        return .success("\(String(cString: buffer))/\(prefix)")
    }

    private static func masked(_ bytes: [UInt8], prefix: Int) -> [UInt8] {
        var out = bytes
        for i in 0..<out.count {
            let bitsKept = max(0, min(8, prefix - i * 8))
            out[i] &= bitsKept == 0 ? 0 : UInt8(truncatingIfNeeded: 0xFF << (8 - bitsKept))
        }
        return out
    }
}

// MARK: - Helper IPC (WardenHelper <-> warden-helper-daemon)

/// Constants both sides must agree on.
enum BlockIPC {
    /// Bump whenever the helper's behaviour changes. WardenHelper shows 需要更新 when the running
    /// helper reports a lower number than the one bundled in the app.
    static let helperVersion = 9

    static let label = "com.warden-helper.helper"
    static let socketPath = "/var/run/warden-helper-daemon.sock"
    static let stateDirectory = "/var/db/warden-helper"
    static let installedBinary = "/Library/PrivilegedHelperTools/warden-helper-daemon"
    static let launchDaemonPlist = "/Library/LaunchDaemons/com.warden-helper.helper.plist"
    static let logPath = "/var/log/warden-helper-daemon.log"

    /// One request or reply is one JSON line; a longer one is refused. 5000 rules fit many times over.
    static let maxMessageBytes = 4 * 1024 * 1024
}

/// `type` is `"apply"` (set the armed state and, when `rules` is present, the rules) or `"status"`.
/// An `apply` without `rules` keeps the rules the helper already has.
///
/// `"events"` answers like `status` and adds what the helper logged since `since` (an event
/// number; without `since` only the current number comes back, no history).
struct HelperRequest: Codable {
    var type: String
    var armed: Bool?
    var rules: [BlockRule]?
    var since: Int?
}

/// One `block-*` line of the helper's log. `text` is `tag field=value ...`.
struct HelperEvent: Codable {
    var seq: Int
    var ms: Int64                  // Unix time, milliseconds
    var text: String
}

struct HelperResponse: Codable {
    var ok: Bool
    var error: String?
    var version: Int?
    var armed: Bool?
    var ruleCount: Int?
    var pid: Int32?
    /// `"pending"` (being applied), `"ok"` or `"failed"` (retrying) - how far the blocking got.
    var enforcement: String?
    var seq: Int?                  // number of the newest event
    var events: [HelperEvent]?
}
