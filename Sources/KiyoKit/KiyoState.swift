import Foundation

/// The last settings this tool wrote, cached for display only.
///
/// The camera cannot be asked what it is currently set to (GET_CUR on the
/// read-back selector does not work on tested firmware), so this file is a
/// record of what *we* sent — nothing more. Anyone may have changed the camera
/// since, from Synapse on another machine or another copy of this tool. Never
/// present it as the device's state.
public struct KiyoState: Codable, Sendable {
    public static let currentSchema = 2

    public var schema: Int
    public var updatedAt: String?
    public var locationID: String?
    public var serial: String?
    public var firmware: String?
    public var fieldOfView: String?
    public var hdr: String?
    public var hdrMode: String?
    public var autofocus: String?
    public var zoomAbsolute: UInt16?
    public var approximateFieldOfView: Double?
    /// Whether the last write included the persist command.
    public var persisted: Bool?

    public init() {
        self.schema = Self.currentSchema
    }

    /// Whether this cache belongs to `device`. Prefer the device serial when
    /// available because a location ID identifies a port, not a physical
    /// camera. Without a serial, refuse to merge partial settings.
    public func belongs(to device: KiyoDeviceInfo) -> Bool {
        guard !device.serial.isEmpty, let serial else { return false }
        return serial == device.serial
    }

    /// A weaker match used only to restore non-authoritative menu checkmarks.
    /// When the camera has no serial, location and firmware are the best
    /// available fingerprint. Never use this to merge state for a camera write.
    public func canRestoreDisplay(for device: KiyoDeviceInfo) -> Bool {
        if !device.serial.isEmpty, let serial { return serial == device.serial }
        guard device.serial.isEmpty, serial == nil else { return false }
        return locationID == device.locationHex && firmware == device.firmwareVersion
    }

    /// Folds a just-applied batch in, leaving untouched settings alone.
    public mutating func record(_ settings: KiyoSettings, on device: KiyoDeviceInfo, saved: Bool) {
        schema = Self.currentSchema
        updatedAt = ISO8601DateFormatter().string(from: Date())
        locationID = device.locationHex
        serial = device.serial.isEmpty ? nil : device.serial
        firmware = device.firmwareVersion

        if let value = settings.fieldOfView { fieldOfView = value.rawValue }
        if let value = settings.hdr { hdr = value.rawValue }
        if let value = settings.hdrMode { hdrMode = value.rawValue }
        if let value = settings.autofocus { autofocus = value.rawValue }
        persisted = saved
    }

    public mutating func recordDigitalFOV(base: FieldOfView, zoomValue: UInt16,
                                          approximateDegrees: Double,
                                          on device: KiyoDeviceInfo, saved: Bool) {
        record(KiyoSettings(fieldOfView: base), on: device, saved: saved)
        zoomAbsolute = zoomValue
        approximateFieldOfView = approximateDegrees
    }
}

public enum KiyoStateStore {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("kiyoctl", isDirectory: true)
    }

    public static var url: URL { directory.appendingPathComponent("state.json") }

    public static func load() -> KiyoState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(KiyoState.self, from: data)
    }

    /// Best effort. A cache write failing is not a reason to report that a
    /// successful camera write failed, so this never throws.
    @discardableResult
    public static func save(_ state: KiyoState) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(state).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
