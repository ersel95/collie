import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Network)
import Network
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Photos)
import Photos
#endif
#if canImport(CoreLocation)
import CoreLocation
#endif
#if canImport(UserNotifications)
import UserNotifications
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
    /// Display and accessibility settings the device is running with. Nested rather than
    /// flattened so the panel can render it as its own block, and so a report filed by an
    /// SDK that predates it simply has no `accessibility` key.
    public let accessibility: CollieAccessibilityState?
    /// What the tester answered to the system's permission prompts. Nested and optional
    /// for the same reasons as `accessibility`.
    public let permissions: ColliePermissionState?

    public init(
        timezone: String?, screenScale: Double?, screenPoints: String?,
        networkType: String?, batteryLevel: Int?, batteryState: String?,
        lowPowerMode: Bool?, thermalState: String?, orientation: String?,
        freeDiskBytes: Int64?, totalDiskBytes: Int64?,
        totalMemoryBytes: Int64?, appMemoryBytes: Int64?,
        accessibility: CollieAccessibilityState? = nil,
        permissions: ColliePermissionState? = nil
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
        self.accessibility = accessibility
        self.permissions = permissions
    }
}

/// How the device is configured to *present* the app: dark mode, text size, and which
/// accessibility features are switched on.
///
/// A tester rarely mentions any of this — "the button is cut off" and "I can't read the
/// price" are the same sentence whether the device runs at the default text size or at
/// AX5 with bold text — so the report has to carry it. Reading a screenshot back against
/// these values is what turns an unreproducible layout complaint into a known one.
///
/// Still device state, not PII: every field is a system setting, and nothing here names
/// the person, the network or the place.
///
/// The vocabulary is shared with the Android SDK so one panel column reads both platforms.
/// A field the platform has no equivalent for stays `nil` and is omitted from the upload
/// — `nil` means "not knowable here", never "off".
public struct CollieAccessibilityState: Codable, Sendable {
    /// `dark` / `light` / `unspecified`.
    public let interfaceStyle: String?
    /// The text-size multiplier the app actually renders at (1.0 = default).
    public let fontScale: Double?
    /// Dynamic Type category, iOS's own name for the same setting: `L`, `XXL`, `AX3`…
    /// (Android has no equivalent — `fontScale` is the cross-platform field.)
    public let contentSize: String?
    public let boldText: Bool?
    /// VoiceOver on iOS, TalkBack on Android.
    public let screenReader: Bool?
    public let switchControl: Bool?
    public let assistiveTouch: Bool?
    public let speakScreen: Bool?
    public let reduceMotion: Bool?
    public let reduceTransparency: Bool?
    /// "Increase Contrast" on iOS, "High contrast text" on Android.
    public let increaseContrast: Bool?
    public let invertColors: Bool?
    public let grayscale: Bool?
    public let differentiateWithoutColor: Bool?
    public let onOffLabels: Bool?
    public let closedCaptions: Bool?
    public let monoAudio: Bool?

    public init(
        interfaceStyle: String? = nil,
        fontScale: Double? = nil,
        contentSize: String? = nil,
        boldText: Bool? = nil,
        screenReader: Bool? = nil,
        switchControl: Bool? = nil,
        assistiveTouch: Bool? = nil,
        speakScreen: Bool? = nil,
        reduceMotion: Bool? = nil,
        reduceTransparency: Bool? = nil,
        increaseContrast: Bool? = nil,
        invertColors: Bool? = nil,
        grayscale: Bool? = nil,
        differentiateWithoutColor: Bool? = nil,
        onOffLabels: Bool? = nil,
        closedCaptions: Bool? = nil,
        monoAudio: Bool? = nil
    ) {
        self.interfaceStyle = interfaceStyle
        self.fontScale = fontScale
        self.contentSize = contentSize
        self.boldText = boldText
        self.screenReader = screenReader
        self.switchControl = switchControl
        self.assistiveTouch = assistiveTouch
        self.speakScreen = speakScreen
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
        self.invertColors = invertColors
        self.grayscale = grayscale
        self.differentiateWithoutColor = differentiateWithoutColor
        self.onOffLabels = onOffLabels
        self.closedCaptions = closedCaptions
        self.monoAudio = monoAudio
    }
}

/// What the tester answered to the system's permission prompts, at the moment the report
/// was taken.
///
/// Half the reports that read like a broken feature are a declined prompt: the camera
/// screen that "opens black", the upload that "does nothing", the push that "never
/// arrives". The tester does not connect the two, and nobody triaging the report can see
/// it — so the answers travel with the report.
///
/// **Nothing here ever asks for anything.** Every value is a status read; no permission is
/// requested, no usage description is needed, and the tester sees no prompt because Collie
/// looked. A permission the host app does not use at all stays `nil`.
///
/// No PII: a grant is not the data behind it. Collie reads whether location is allowed,
/// never a coordinate; whether the photo library is allowed, never a photo.
///
/// The vocabulary is shared with the Android SDK: `granted` / `denied` / `notDetermined` /
/// `restricted` / `limited`, plus `always` and `whenInUse` for location and `provisional`
/// / `ephemeral` for notifications.
public struct ColliePermissionState: Codable, Sendable {
    public let camera: String?
    public let microphone: String?
    public let photoLibrary: String?
    /// `always` / `whenInUse` / `denied` / `notDetermined` / `restricted`.
    public let location: String?
    /// `full` / `reduced` — iOS's precise-location toggle, Android's fine-vs-coarse grant.
    /// Only meaningful while location is granted; `nil` otherwise.
    public let locationAccuracy: String?
    public let notifications: String?

    public init(
        camera: String? = nil,
        microphone: String? = nil,
        photoLibrary: String? = nil,
        location: String? = nil,
        locationAccuracy: String? = nil,
        notifications: String? = nil
    ) {
        self.camera = camera
        self.microphone = microphone
        self.photoLibrary = photoLibrary
        self.location = location
        self.locationAccuracy = locationAccuracy
        self.notifications = notifications
    }
}

/// Collects the point-in-time device telemetry.
public enum CollieTelemetryCollector {

    /// Early preparation: enables battery monitoring, starts the network monitor and
    /// fetches the notification authorization. Called once when the bug reporter activates
    /// (while the banner is being set up), so the very first report has the battery level,
    /// the network type and the notification grant populated.
    @MainActor
    public static func prepare() {
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
        CollieNetworkMonitor.shared.start()
        CollieNotificationAuthorizationMonitor.shared.start()
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
            appMemoryBytes: appMemoryBytes(),
            accessibility: accessibilityState(),
            permissions: permissionState()
        )
    }

    // MARK: - Permissions (status reads only — nothing is ever requested)

    /// Reads the grants the tester gave the *host app*. Every call below is a status
    /// query: `authorizationStatus`, never `requestAccess`. A prompt raised by a bug
    /// reporter would be a bug of its own, and would teach testers to decline.
    ///
    /// The notification grant is the one status with no synchronous API, so it comes from
    /// the cache `prepare()` fills (see `CollieNotificationAuthorizationMonitor`).
    @MainActor
    private static func permissionState() -> ColliePermissionState? {
        #if canImport(UIKit)
        let location = locationAuthorization()
        return ColliePermissionState(
            camera: captureAuthorization(for: .video),
            microphone: captureAuthorization(for: .audio),
            photoLibrary: photoLibraryAuthorization(),
            location: location.status,
            locationAccuracy: location.accuracy,
            notifications: CollieNotificationAuthorizationMonitor.shared.current
        )
        #else
        return nil
        #endif
    }

    #if canImport(AVFoundation)
    private static func captureAuthorization(for mediaType: AVMediaType) -> String? {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return nil
        }
    }
    #else
    private static func captureAuthorization(for mediaType: Any) -> String? { nil }
    #endif

    private static func photoLibraryAuthorization() -> String? {
        #if canImport(Photos)
        // `.readWrite`: the level a host asks for when the tester picks or saves an image.
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: return "granted"
        case .limited: return "limited"   // "Selected Photos"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return nil
        }
        #else
        return nil
        #endif
    }

    /// The precise-location toggle is only reported while location is actually granted:
    /// `accuracyAuthorization` answers `.fullAccuracy` on a device that was never asked,
    /// which would read as "precise location allowed" for an app that has none.
    @MainActor
    private static func locationAuthorization() -> (status: String?, accuracy: String?) {
        #if canImport(CoreLocation)
        // Instantiating the manager reads the status; it starts nothing and prompts for
        // nothing (that is `requestWhenInUseAuthorization`, which Collie never calls).
        let manager = CLLocationManager()
        let status: String?
        switch manager.authorizationStatus {
        case .authorizedAlways: status = "always"
        case .authorizedWhenInUse: status = "whenInUse"
        case .denied: status = "denied"
        case .restricted: status = "restricted"
        case .notDetermined: status = "notDetermined"
        @unknown default: status = nil
        }
        guard status == "always" || status == "whenInUse" else { return (status, nil) }
        switch manager.accuracyAuthorization {
        case .fullAccuracy: return (status, "full")
        case .reducedAccuracy: return (status, "reduced")
        @unknown default: return (status, nil)
        }
        #else
        return (nil, nil)
        #endif
    }

    // MARK: - Accessibility & appearance

    /// Every switch is a synchronous `UIAccessibility` read, so this costs nothing and
    /// needs no preparation — unlike the battery and the network path.
    @MainActor
    private static func accessibilityState() -> CollieAccessibilityState? {
        #if canImport(UIKit)
        return CollieAccessibilityState(
            interfaceStyle: interfaceStyleString(),
            fontScale: fontScale(),
            contentSize: contentSizeString(),
            boldText: UIAccessibility.isBoldTextEnabled,
            screenReader: UIAccessibility.isVoiceOverRunning,
            switchControl: UIAccessibility.isSwitchControlRunning,
            assistiveTouch: UIAccessibility.isAssistiveTouchRunning,
            speakScreen: UIAccessibility.isSpeakScreenEnabled,
            reduceMotion: UIAccessibility.isReduceMotionEnabled,
            reduceTransparency: UIAccessibility.isReduceTransparencyEnabled,
            increaseContrast: UIAccessibility.isDarkerSystemColorsEnabled,
            invertColors: UIAccessibility.isInvertColorsEnabled,
            grayscale: UIAccessibility.isGrayscaleEnabled,
            differentiateWithoutColor: UIAccessibility.shouldDifferentiateWithoutColor,
            onOffLabels: UIAccessibility.isOnOffSwitchLabelsEnabled,
            closedCaptions: UIAccessibility.isClosedCaptioningEnabled,
            monoAudio: UIAccessibility.isMonoAudioEnabled
        )
        #else
        return nil
        #endif
    }

    /// Read outside any draw or layout callback (the report is sent from a button tap),
    /// where `UITraitCollection.current` resolves to the screen's traits — the *device's*
    /// appearance setting, which is what was asked for. A host that overrides the style
    /// for its own windows therefore does not hide the setting the tester is running.
    @MainActor
    private static func interfaceStyleString() -> String? {
        #if canImport(UIKit)
        switch UITraitCollection.current.userInterfaceStyle {
        case .dark: return "dark"
        case .light: return "light"
        case .unspecified: return "unspecified"
        @unknown default: return "unspecified"
        }
        #else
        return nil
        #endif
    }

    /// iOS exposes Dynamic Type as a *category*, not a number, so the multiplier is
    /// measured instead: how tall a body-text point size comes back after scaling. That is
    /// the same quantity Android reports as `fontScale`, which is what lets one panel
    /// column compare the two platforms.
    @MainActor
    private static func fontScale() -> Double? {
        #if canImport(UIKit)
        let base = 17.0   // the body text style's default point size
        let scaled = Double(UIFontMetrics(forTextStyle: .body).scaledValue(for: CGFloat(base)))
        return ((scaled / base) * 100).rounded() / 100
        #else
        return nil
        #endif
    }

    /// The raw values are `UICTContentSizeCategoryL`-style identifiers; the short forms
    /// are what a person triaging a report reads.
    @MainActor
    private static func contentSizeString() -> String? {
        #if canImport(UIKit)
        switch UIApplication.shared.preferredContentSizeCategory {
        case .extraSmall: return "XS"
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        case .extraLarge: return "XL"
        case .extraExtraLarge: return "XXL"
        case .extraExtraExtraLarge: return "XXXL"
        case .accessibilityMedium: return "AX1"
        case .accessibilityLarge: return "AX2"
        case .accessibilityExtraLarge: return "AX3"
        case .accessibilityExtraExtraLarge: return "AX4"
        case .accessibilityExtraExtraExtraLarge: return "AX5"
        default: return UIApplication.shared.preferredContentSizeCategory.rawValue
        }
        #else
        return nil
        #endif
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

/// Caches the notification authorization, because it is the one permission with no
/// synchronous status API — `getNotificationSettings` answers on a callback, and telemetry
/// is captured synchronously while the report is being built. Same shape as
/// `CollieNetworkMonitor`: fetched ahead of time, read from the cache at capture.
///
/// Refreshed whenever the app becomes active. Changing this setting means a trip to
/// Settings and back, and a permission prompt resigns and restores active around itself —
/// both are exactly that notification, so the cached value cannot go stale behind a change
/// the tester just made.
///
/// Reading the settings never prompts; Collie does not call `requestAuthorization`.
final class CollieNotificationAuthorizationMonitor: @unchecked Sendable {

    static let shared = CollieNotificationAuthorizationMonitor()

    private let lock = NSLock()
    private var _status: String?
    private var started = false

    /// `nil` until the first fetch answers, or wherever notifications do not exist.
    var current: String? {
        lock.lock(); defer { lock.unlock() }
        return _status
    }

    func start() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        #if canImport(UIKit) && canImport(UserNotifications)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.refresh()
        }
        #endif
        refresh()
    }

    private func refresh() {
        // UIKit-only on purpose: `UNUserNotificationCenter.current()` traps in a process
        // without an app bundle, which is what the macOS test run is.
        #if canImport(UIKit) && canImport(UserNotifications)
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            self?.set(Self.describe(settings.authorizationStatus))
        }
        #endif
    }

    private func set(_ value: String?) {
        lock.lock(); _status = value; lock.unlock()
    }

    #if canImport(UserNotifications)
    private static func describe(_ status: UNAuthorizationStatus) -> String? {
        switch status {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return nil
        }
    }
    #endif
}
