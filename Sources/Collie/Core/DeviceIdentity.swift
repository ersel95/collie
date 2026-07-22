import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Security)
import Security
#endif

/// Identity of the device/person sending the report.
///
/// - **id**: a persistent per-device identifier. First the UUID stored in the Keychain
///   (survives uninstall); otherwise generated from `identifierForVendor` and written
///   to the Keychain.
/// - **name**: the name entered **once** in the report sheet. Stored after the first
///   entry; not asked again on later submissions.
/// - Model / OS version / locale / screen are collected automatically with each report.
///
/// Contains no real service names / secrets; fully generic.
public struct CollieDeviceIdentity: Sendable {

    public let id: String
    public let name: String?
    public let model: String
    public let osVersion: String
    public let locale: String
    public let screen: String

    /// Collects the current identity (persistent id + stored name + device meta).
    @MainActor
    public static func current() -> CollieDeviceIdentity {
        CollieDeviceIdentity(
            id: persistentDeviceID(),
            name: storedName(),
            model: deviceModel(),
            osVersion: osVersionString(),
            locale: localeIdentifier(),
            screen: screenSize()
        )
    }

    /// Is a tester name stored? (Determines whether the sheet asks for a name on first use.)
    public static var hasStoredName: Bool {
        storedName()?.isEmpty == false
    }

    /// Stores the one-time tester name. Empty/whitespace input is ignored.
    /// Stored **in the Keychain** like the device id → the name survives app
    /// delete/reinstall (UserDefaults would be wiped on reinstall → the name would be
    /// asked again on every install).
    public static func storeName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        KeychainStore.write(trimmed, account: nameAccount)
    }

    static func storedName() -> String? {
        if let value = KeychainStore.read(account: nameAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        return nil
    }

    // MARK: - Persistent device id (Keychain → idfv → random)

    private static func persistentDeviceID() -> String {
        if let existing = KeychainStore.read(account: deviceIDAccount), !existing.isEmpty {
            return existing
        }
        let generated = vendorIdentifier() ?? UUID().uuidString
        KeychainStore.write(generated, account: deviceIDAccount)
        return generated
    }

    private static func vendorIdentifier() -> String? {
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString
        #else
        return nil
        #endif
    }

    // MARK: - Device meta

    private static func deviceModel() -> String {
        // `utsname.machine` yields the hardware model (e.g. "iPhone15,3"). On the
        // simulator it's read from the environment.
        #if targetEnvironment(simulator)
        if let identifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return identifier
        }
        #endif
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { rawBuffer -> String in
            let bytes = rawBuffer.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine.isEmpty ? "unknown" : machine
    }

    private static func osVersionString() -> String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif
    }

    private static func localeIdentifier() -> String {
        Locale.current.identifier
    }

    @MainActor
    private static func screenSize() -> String {
        #if canImport(UIKit)
        let bounds = UIScreen.main.nativeBounds
        return "\(Int(bounds.width))x\(Int(bounds.height))"
        #else
        return "0x0"
        #endif
    }

    // MARK: - App meta (from the bundle)

    /// Bundle identifier.
    public static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "unknown"
    }

    /// Version (`CFBundleShortVersionString`).
    public static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Build (`CFBundleVersion`).
    public static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    // MARK: - Keys

    private static let nameAccount = "com.collie.testerName"
    private static let deviceIDAccount = "com.collie.deviceID"
}

// MARK: - Keychain (generic, dependency-free)

/// Minimal Keychain wrapper — string read/write only. No external dependencies.
enum KeychainStore {

    private static let service = "com.collie.bugreporter"

    static func read(account: String) -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #else
        return UserDefaults.standard.string(forKey: service + "." + account)
        #endif
    }

    static func write(_ value: String, account: String) {
        #if canImport(Security)
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
        #else
        UserDefaults.standard.set(value, forKey: service + "." + account)
        #endif
    }
}
