import Foundation

/// Why a rules file was rejected: text for the settings row, and the line when it is known.
struct BlockRulesParseError: Error, Equatable {
    let message: String
    let line: Int?

    /// What the status line shows, e.g. `第 12 行：JSON 格式错误`.
    var displayText: String { line.map { L10n.blockErrorAtLine($0, message) } ?? message }
}

/// Reads the rules file: a JSON array of objects, each with one or more of
/// `domain`, `domain_suffix` (a leading `*.` is accepted), `domain_keyword`, `process_name`, `process_path`,
/// `ip_cidr` (alias `ip`). A value is a string or an array of strings. One bad entry rejects
/// the whole file, so a half-read list can never replace a good one.
enum BlockRulesParser {

    private static let keyKinds: [String: BlockRuleKind] = [
        "domain": .domain,
        "domain_suffix": .domainSuffix,
        "domain_keyword": .domainKeyword,
        "process_name": .processName,
        "process_path": .processPath,
        "ip_cidr": .ipCIDR, "ip": .ipCIDR,
    ]

    static func parse(_ data: Data) -> Result<BlockRuleSet, BlockRulesParseError> {
        if data.count > BlockLimits.maxFileBytes {
            return .failure(.init(message: L10n.blockErrTooLarge, line: nil))
        }
        var data = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }   // UTF-8 BOM
        guard data.contains(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }) else {
            return .failure(.init(message: L10n.blockErrEmptyFile, line: nil))
        }

        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return .failure(.init(message: L10n.blockErrSyntax, line: syntaxErrorLine(error, in: data)))
        }
        guard let items = json as? [Any] else {
            return .failure(.init(message: L10n.blockErrNotArray, line: nil))
        }

        let text = String(decoding: data, as: UTF8.self)
        var rules: [BlockRule] = []
        var seenValues = 0

        for (index, item) in items.enumerated() {
            let n = index + 1
            guard let object = item as? [String: Any] else {
                return .failure(.init(message: L10n.blockErrNotObject(n), line: nil))
            }
            guard !object.isEmpty else {
                return .failure(.init(message: L10n.blockErrEmptyObject(n), line: nil))
            }
            // Sorted, so the same file always fails on the same entry.
            for key in object.keys.sorted() {
                guard let kind = keyKinds[key] else {
                    return .failure(.init(message: L10n.blockErrUnknownKey(n, key), line: lineOf("\"\(key)\"", in: text)))
                }
                let raw: [Any]
                switch object[key] {
                case let single as String: raw = [single]
                case let many as [Any]:    raw = many
                default:
                    return .failure(.init(message: L10n.blockErrValueType(n, key), line: lineOf("\"\(key)\"", in: text)))
                }
                for element in raw {
                    guard let value = element as? String else {
                        return .failure(.init(message: L10n.blockErrValueType(n, key), line: lineOf("\"\(key)\"", in: text)))
                    }
                    seenValues += 1
                    if seenValues > BlockLimits.maxEntries {
                        return .failure(.init(message: L10n.blockErrTooMany, line: nil))
                    }
                    switch BlockRuleValidator.normalize(value, kind: kind) {
                    case .success(let normalized):
                        rules.append(BlockRule(kind: kind, value: normalized))
                    case .failure(let issue):
                        let shown = value.count > 60 ? String(value.prefix(60)) + "…" : value
                        return .failure(.init(message: L10n.blockErrInvalid(n, key, shown, reason(issue, key: key)),
                                              line: lineOf("\"\(value)\"", in: text)))
                    }
                }
            }
        }
        return .success(BlockRuleSet(rules: rules))
    }

    // MARK: - Helpers

    private static func reason(_ issue: BlockRuleIssue, key: String) -> String {
        switch issue {
        case .empty:                 return L10n.blockWhyEmpty
        case .badDomain:             return L10n.blockWhyBadDomain
        case .badKeyword:            return L10n.blockWhyBadKeyword
        case .keywordTooShort:       return L10n.blockWhyKeywordShort
        case .wildcardInExactDomain: return L10n.blockWhyWildcard
        case .badProcessName:        return L10n.blockWhyBadProcess
        case .badProcessPath:        return L10n.blockWhyBadPath
        case .protectedProcess:      return L10n.blockWhyProtected
        case .badAddress:            return L10n.blockWhyBadAddress
        case .rangeTooBroad:         return L10n.blockWhyTooBroad
        case .includesLoopback:      return L10n.blockWhyLoopback
        }
    }

    /// The line of a JSON syntax error. Foundation words it as "… around line 3, column 5." or,
    /// for some errors, "… around character 42."; nil when it says neither.
    private static func syntaxErrorLine(_ error: Error, in data: Data) -> Int? {
        let info = (error as NSError).userInfo
        let text = (info[NSDebugDescriptionErrorKey] as? String) ?? (error as NSError).localizedDescription
        if let n = firstNumber(after: "line ", in: text), n > 0 { return n }
        if let offset = firstNumber(after: "character ", in: text) {
            let end = min(offset, data.count)
            return data.prefix(end).reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) }
        }
        return nil
    }

    private static func firstNumber(after marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        let digits = text[range.upperBound...].prefix(while: { $0.isASCII && $0.isNumber })
        return Int(digits)
    }

    /// 1-based line of the first occurrence of `needle` (best effort, for the status line).
    private static func lineOf(_ needle: String, in text: String) -> Int? {
        guard let range = text.range(of: needle) else { return nil }
        return text[..<range.lowerBound].reduce(1) { $0 + ($1 == "\n" ? 1 : 0) }
    }
}
