import Foundation
import SystemConfiguration
import Network

/// Detects network changes (VPN connect / disconnect included) from SCDynamicStore, NWPathMonitor
/// and a 1 s interface poll. Events are debounced.
class NetworkChangeDetector {
    
    /// Called on the main thread whenever a network change is detected.
    var onNetworkChange: (() -> Void)?
    
    private var pathMonitor: NWPathMonitor?
    private var interfacePollTimer: Timer?
    private var lastInterfaceSet: Set<String> = []
    
    // Debounce: avoid firing multiple times in quick succession
    private var lastFireTime: Date = .distantPast
    private let debounceInterval: TimeInterval = 0.25
    private var trailingScheduled = false
    
    // SCDynamicStore for network change detection
    private var dynamicStore: SCDynamicStore?
    private var runLoopSource: CFRunLoopSource?
    
    func start() {
        setupDarwinNotification()
        setupPathMonitor()
        setupInterfacePolling()
        
        // Capture initial interface snapshot
        lastInterfaceSet = currentInterfaces()
    }
    
    func stop() {
        // Remove Darwin notification
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        dynamicStore = nil
        
        pathMonitor?.cancel()
        pathMonitor = nil
        
        interfacePollTimer?.invalidate()
        interfacePollTimer = nil
    }
    
    // MARK: - Method 1: SCDynamicStore (Darwin network change notifications)
    
    private func setupDarwinNotification() {
        
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        
        let callback: SCDynamicStoreCallBack = { (store, changedKeys, info) in
            guard let info = info else { return }
            let detector = Unmanaged<NetworkChangeDetector>.fromOpaque(info).takeUnretainedValue()
            detector.fireChangeEvent()
        }
        
        guard let store = SCDynamicStoreCreate(nil, "WardenHelper" as CFString, callback, &context) else {
            return
        }
        
        dynamicStore = store
        
        // Global IPv4 / IPv6 state, service state, interface link, service setup.
        let watchedKeys: [CFString] = [
            "State:/Network/Global/IPv4" as CFString,
            "State:/Network/Global/IPv6" as CFString,
        ]
        
        let watchedPatterns: [CFString] = [
            "State:/Network/Service/.*/IPv4" as CFString,
            "State:/Network/Service/.*/IPv6" as CFString,
            "State:/Network/Interface/.*/Link" as CFString,
            "Setup:/Network/Service/.*/Interface" as CFString,
        ]
        
        SCDynamicStoreSetNotificationKeys(store, watchedKeys as CFArray, watchedPatterns as CFArray)
        
        if let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }
    
    // MARK: - Method 2: NWPathMonitor
    
    private func setupPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            self?.fireChangeEvent()
        }
        monitor.start(queue: DispatchQueue(label: "warden-helper.pathmonitor"))
        pathMonitor = monitor
    }
    
    // MARK: - Method 3: Interface polling
    
    private func setupInterfacePolling() {
        // Cheap safety net; .common modes keep it firing while a menu is open.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkInterfaceChanges()
        }
        RunLoop.main.add(timer, forMode: .common)
        interfacePollTimer = timer
    }
    
    private func checkInterfaceChanges() {
        let current = currentInterfaces()
        if current != lastInterfaceSet {
            lastInterfaceSet = current
            fireChangeEvent()
        }
    }
    
    /// Get the set of currently active (UP, non-loopback) network interface names
    private func currentInterfaces() -> Set<String> {
        var result = Set<String>()
        
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return result }
        
        defer { freeifaddrs(ifaddr) }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            
            if isUp && !isLoopback {
                let name = String(cString: ptr.pointee.ifa_name)
                result.insert(name)
            }
        }
        
        return result
    }
    
    // MARK: - Debounced event firing
    
    /// First event fires at once; later ones in the window merge into one trailing fire.
    private func fireChangeEvent() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            let elapsed = Date().timeIntervalSince(self.lastFireTime)
            if elapsed >= self.debounceInterval {
                self.emit()
            } else if !self.trailingScheduled {
                self.trailingScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + (self.debounceInterval - elapsed)) { [weak self] in
                    guard let self = self else { return }
                    self.trailingScheduled = false
                    self.emit()
                }
            }
        }
    }

    private func emit() {
        lastFireTime = Date()
        lastInterfaceSet = currentInterfaces()
        onNetworkChange?()
    }
}
