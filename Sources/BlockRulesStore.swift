import Foundation

/// Owns the rules WardenHelper enforces: reads the rules file, keeps the last good set, and reloads
/// when the file changes. No root involved; the helper only ever receives `rules`.
///
/// Main thread only, except the file read + parse, which run on a utility queue.
/// A parse failure or a missing file never replaces good rules.
final class BlockRulesStore {
    static let shared = BlockRulesStore()

    /// Posted on the main thread whenever `status` or `rules` changed.
    static let changedNotification = Notification.Name("WardenHelperBlockRulesChanged")

    enum Status: Equatable {
        case notLoaded
        case loaded(Int)
        case missing
        case failed(String)
    }

    private(set) var status: Status = .notLoaded

    /// The last good rule set. `nil` until a file has been read successfully once since
    /// launch: the caller must then not overwrite what the helper has saved.
    private(set) var rules: BlockRuleSet?

    // MARK: State (main thread)

    private var watchedPath: String?               // expanded path currently being watched
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private var debounce: DispatchWorkItem?
    private var generation = 0                      // drops results of superseded reads
    private var lastSignature: FileSignature?
    private var started = false

    private let workQueue = DispatchQueue(label: "warden-helper.blockrules", qos: .utility)
    private static let debounceInterval: TimeInterval = 0.5
    private static let pollInterval: TimeInterval = 3

    private init() {}

    // MARK: - Public

    /// The rules file as an absolute path, or nil when the setting is not an absolute / `~` path.
    static func expandedPath(_ typed: String) -> String? {
        let expanded = (typed.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? (expanded as NSString).standardizingPath : nil
    }

    var currentFileURL: URL? {
        Self.expandedPath(Preferences.shared.blockRulesPath).map { URL(fileURLWithPath: $0) }
    }

    /// Text for the settings status line.
    var statusText: String {
        switch status {
        case .notLoaded:        return L10n.blockNotLoaded
        case .loaded(let n):    return L10n.blockLoaded(n)
        case .missing:          return L10n.blockMissing
        case .failed(let why):
            // A rejected file leaves the previous rules in force; say so.
            if let kept = rules, !kept.isEmpty { return why + L10n.blockKeptOldRules(kept.count) }
            return why
        }
    }

    /// Call once after launch.
    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged),
                                               name: Preferences.changedNotification, object: nil)
        createDefaultFolderIfNeeded()
        pathChanged()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.pollTick() }
        timer.resume()
        pollTimer = timer
    }

    /// Read the file again now (no debounce).
    func reloadNow() { load() }

    // MARK: - Path and watching

    @objc private func preferencesChanged() {
        let path = Self.expandedPath(Preferences.shared.blockRulesPath)
        if path != watchedPath { pathChanged() }
    }

    private func createDefaultFolderIfNeeded() {
        guard Preferences.shared.blockRulesPath == Preferences.defaultBlockRulesPath,
              let path = Self.expandedPath(Preferences.defaultBlockRulesPath) else { return }
        let folder = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    private func pathChanged() {
        createDefaultFolderIfNeeded()
        watchedPath = Self.expandedPath(Preferences.shared.blockRulesPath)
        lastSignature = nil
        rearmWatchers()
        load()
    }

    /// Editors often replace a file (write a temp file, rename it over the original), which
    /// leaves a watch on the old inode dead. So the folder is watched too, and the file's watch
    /// is re-opened after every load. The poll timer covers what neither of them sees.
    private func rearmWatchers() {
        dirSource?.cancel(); dirSource = nil
        fileSource?.cancel(); fileSource = nil
        guard let path = watchedPath else { return }

        let folder = (path as NSString).deletingLastPathComponent
        dirSource = makeSource(path: folder, mask: [.write, .rename, .delete, .link])
        fileSource = makeSource(path: path, mask: [.write, .extend, .rename, .delete])
    }

    private func makeSource(path: String, mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func scheduleReload() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.load() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    private func pollTick() {
        guard let path = watchedPath else { return }
        let now = FileSignature.read(path)
        if now != lastSignature { scheduleReload() }
        // A file that appeared after we started has no watch yet.
        if fileSource == nil, now.exists { rearmWatchers() }
    }

    // MARK: - Loading

    private func load() {
        guard let path = watchedPath else {
            apply(status: .failed(L10n.blockPathNotAbsolute), rules: nil)
            return
        }
        generation += 1
        let mine = generation
        workQueue.async { [weak self] in
            let signature = FileSignature.read(path)
            let outcome = Self.readAndParse(path: path)
            DispatchQueue.main.async {
                guard let self = self, self.generation == mine else { return }
                self.lastSignature = signature
                self.rearmWatchers()                  // the file may be a new inode now
                switch outcome {
                case .missing:
                    self.apply(status: .missing, rules: nil)
                case .unreadable:
                    self.apply(status: .failed(L10n.blockUnreadable), rules: nil)
                case .parsed(.success(let set)):
                    BlockLog.shared.log("block-rules", "loaded n=\(set.count)")
                    self.apply(status: .loaded(set.count), rules: set)
                case .parsed(.failure(let error)):
                    BlockLog.shared.log("block-rules", "rejected \(error.displayText)")
                    self.apply(status: .failed(error.displayText), rules: nil)
                }
            }
        }
    }

    private enum ReadOutcome {
        case missing
        case unreadable
        case parsed(Result<BlockRuleSet, BlockRulesParseError>)
    }

    private static func readAndParse(path: String) -> ReadOutcome {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .missing }
        guard !isDirectory.boolValue, let handle = FileHandle(forReadingAtPath: path) else { return .unreadable }
        defer { try? handle.close() }
        // One byte more than the limit is enough to know the file is too large.
        guard let data = try? handle.read(upToCount: BlockLimits.maxFileBytes + 1) else { return .unreadable }
        return .parsed(BlockRulesParser.parse(data))
    }

    /// Publishes a result. `rules == nil` keeps the previous good set.
    private func apply(status newStatus: Status, rules newRules: BlockRuleSet?) {
        var changed = false
        if status != newStatus { status = newStatus; changed = true }
        if let newRules = newRules, rules != newRules { rules = newRules; changed = true }
        if changed { NotificationCenter.default.post(name: Self.changedNotification, object: self) }
    }
}

/// Enough of a file's metadata to tell that it changed: existence, inode, size, mtime.
private struct FileSignature: Equatable {
    let exists: Bool
    let inode: UInt64
    let size: Int64
    let mtime: Double

    static func read(_ path: String) -> FileSignature {
        var info = stat()
        guard stat(path, &info) == 0 else { return FileSignature(exists: false, inode: 0, size: 0, mtime: 0) }
        let seconds = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        return FileSignature(exists: true, inode: UInt64(info.st_ino), size: Int64(info.st_size), mtime: seconds)
    }
}
