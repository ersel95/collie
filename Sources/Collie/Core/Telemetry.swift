import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Network)
import Network
#endif

/// Point-in-time device state at the moment the report was taken. Device-state only,
/// no PII — no IP / SSID / location / personal data of any kind. Fields that could not
/// be collected are `nil`.
public struct CollieTelemetry: Codable, Sendable {
    public let timezone: String?          // "Europe/Istanbul"
    public let screenScale: Double?       // 3.0
    public let screenPoints: String?      // "390x844" (points)
    public let networkType: String?       // wifi/cellular/wired/none/unknown
    public let batteryLevel: Int?         // 0–100, nil = unknown
    public let batteryState: String?      // charging/full/unplugged/unknown
    public let lowPowerMode: Bool?
    public let thermalState: String?      // nominal/fair/serious/critical
    public let orientation: String?       // portrait/landscapeLeft/...
    public let freeDiskBytes: Int64?
    public let totalDiskBytes: Int64?
    public let totalMemoryBytes: Int64?
    public let appMemoryBytes: Int64?

    public init(
        timezone: String?, screenScale: Double?, screenPoints: String?,
        networkType: String?, batteryLevel: Int?, batteryState: String?,
        lowPowerMode: Bool?, thermalState: String?, orientation: String?,
        freeDiskBytes: Int64?, totalDiskBytes: Int64?,
        totalMemoryBytes: Int64?, appMemoryBytes: Int64?
    ) {
        self.timezone = timezone
        self.screenScale = screenScale
        self.screenPoints = screenPoints
        self.networkType = networkType
        self.batteryLevel = batteryLevel
        self.batteryState = batteryState
        self.lowPowerMode = lowPowerMode
        self.thermalState = thermalState
        self.orientation = orientation
        self.freeDiskBytes = freeDiskBytes
        self.totalDiskBytes = totalDiskBytes
        self.totalMemoryBytes = totalMemoryBytes
        self.appMemoryBytes = appMemoryBytes
    }
}

/// Collects the point-in-time device telemetry.
public enum CollieTelemetryCollector {

    /// Early preparation: enables battery monitoring and starts the network monitor.
    /// Called once when the bug reporter activates (while the banner is being set up),
    /// so the very first report has the battery level/network type populated.
    @MainActor
    public static func prepare() {
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
        CollieNetworkMonitor.shared.start()
    }

    /// Captures the current telemetry. MainActor for the UIKit fields.
    @MainActor
    public static func capture() -> CollieTelemetry {
        let disk = diskBytes()
        return CollieTelemetry(
            timezone: TimeZone.current.identifier,
            screenScale: screenScale(),
            screenPoints: screenPoints(),
            networkType: CollieNetworkMonitor.shared.current,
            batteryLevel: batteryLevel(),
            batteryState: batteryState(),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: thermalStateString(),
            orientation: orientationString(),
            freeDiskBytes: disk.free,
            totalDiskBytes: disk.total,
            totalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory),
            appMemoryBytes: appMemoryBytes()
        )
    }

    // MARK: - Screen

    @MainActor
    private static func screenScale() -> Double? {
        #if canImport(UIKit)
        return Double(UIScreen.main.scale)
        #else
        return nil
        #endif
    }

    @MainActor
    private static func screenPoints() -> String? {
        #if canImport(UIKit)
        let b = UIScreen.main.bounds
        return "\(Int(b.width))x\(Int(b.height))"
        #else
        return nil
        #endif
    }

    // MARK: - Battery

    @MainActor
    private static func batteryLevel() -> Int? {
        #if canImport(UIKit)
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return nil }   // -1 = monitoring off / unknown
        return Int((level * 100).rounded())
        #else
        return nil
        #endif
    }

    @MainActor
    private static func batteryState() -> String? {
        #if canImport(UIKit)
        switch UIDevice.current.batteryState {
        case .charging: return "charging"
        case .full: return "full"
        case .unplugged: return "unplugged"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
        #else
        return nil
        #endif
    }

    // MARK: - Thermal

    private static func thermalStateString() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Orientation

    @MainActor
    private static func orientationString() -> String? {
        #if canImport(UIKit)
        switch UIDevice.current.orientation {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        case .faceUp: return "faceUp"
        case .faceDown: return "faceDown"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
        #else
        return nil
        #endif
    }

    // MARK: - Disk

    private static func diskBytes() -> (free: Int64?, total: Int64?) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard
            let values = try? url.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeTotalCapacityKey,
            ])
        else {
            return (nil, nil)
        }
        let free = values.volumeAvailableCapacityForImportantUsage
        let total = values.volumeTotalCapacity.map(Int64.init)
        return (free, total)
    }

    // MARK: - App memory (mach phys_footprint)

    private static func appMemoryBytes() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Int64(info.phys_footprint)
    }
}

/// Continuously running network path monitor. `pathUpdateHandler` caches the latest
/// interface type; read synchronously while telemetry is collected. Collects no IP/SSID —
/// interface type only.
final class CollieNetworkMonitor: @unchecked Sendable {

    static let shared = CollieNetworkMonitor()

    private let lock = NSLock()
    private var _type: String = "unknown"
    private var started = false

    #if canImport(Network)
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.collie.network.monitor")
    #endif

    var current: String {
        lock.lock(); defer { lock.unlock() }
        return _type
    }

    func start() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        #if canImport(Network)
        monitor.pathUpdateHandler = { [weak self] path in
            self?.set(Self.classify(path))
        }
        monitor.start(queue: queue)
        #endif
    }

    private func set(_ value: String) {
        lock.lock(); _type = value; lock.unlock()
    }

    #if canImport(Network)
    private static func classify(_ path: NWPath) -> String {
        guard path.status == .satisfied else { return "none" }
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.cellular) { return "cellular" }
        if path.usesInterfaceType(.wiredEthernet) { return "wired" }
        return "other"
    }
    #endif
}
