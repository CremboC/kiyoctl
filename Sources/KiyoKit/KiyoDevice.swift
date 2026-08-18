import CKiyoUSB
import Foundation

/// What discovery found out about one camera. `unitID` and `vcInterface` are
/// read from the configuration descriptor, never hardcoded.
public struct KiyoDeviceInfo: Sendable {
    public let locationID: UInt32
    public let product: String
    public let serial: String
    public let firmwareBCD: UInt16
    public let unitID: UInt8
    public let vcInterface: UInt8
    public let extensionUnitFound: Bool
    public let foundViaFallbackScan: Bool

    /// `bcdDevice` rendered the way Razer's firmware notes write it.
    public var firmwareVersion: String {
        String(format: "%x.%02x", firmwareBCD >> 8, firmwareBCD & 0xff)
    }

    public var locationHex: String { String(format: "0x%08x", locationID) }

    /// The `wIndex` every request to this unit carries.
    public var wIndex: UInt16 { UInt16(unitID) << 8 | UInt16(vcInterface) }
}

/// An open handle on the camera's default control pipe.
///
/// Deliberately narrow: open, send a short ordered list of transfers with a
/// mandatory delay between them, close. There is no polling, no reapply timer
/// and no way to hold this open across a UI interaction — the firmware does not
/// tolerate sustained control traffic.
public final class KiyoDevice {
    public struct Options: Sendable {
        /// Delay between consecutive control transfers, in milliseconds.
        ///
        /// Not a tuning knob. Roughly 25 rapid consecutive UVC SET_CUR
        /// operations can overwhelm this firmware and stall its endpoints, and
        /// on Linux that stall has been observed to cascade into a
        /// host-controller failure that takes the whole USB bus down. Current
        /// evidence supports a 100 ms minimum, which is also the default.
        public var delayMilliseconds: UInt32 = 100
        /// Hard ceiling on transfers per invocation. A full FOV change is 4.
        public var transferLimit: Int = 12
        /// Called with one line per transfer when verbose.
        public var log: (@Sendable (String) -> Void)?

        public init() {}

        func validate() throws {
            guard delayMilliseconds >= KiyoDevice.minimumDelayMilliseconds else {
                throw KiyoError.invalidArgument(
                    "inter-transfer delay must be at least \(KiyoDevice.minimumDelayMilliseconds) ms")
            }
            guard (1...KiyoDevice.maximumTransfersPerRun).contains(transferLimit) else {
                throw KiyoError.invalidArgument(
                    "transfer limit must be between 1 and \(KiyoDevice.maximumTransfersPerRun)")
            }
        }
    }

    public static let minimumDelayMilliseconds: UInt32 = 100
    public static let maximumTransfersPerRun = 12

    private let handle: OpaquePointer
    private let options: Options
    public let info: KiyoDeviceInfo
    // MARK: - Discovery

    /// Every 1532:0e05 on the bus, with its extension unit resolved. Does not
    /// open anything, so this is always safe to run against a live stream.
    public static func enumerate() throws -> [KiyoDeviceInfo] {
        let capacity = 8
        var raw = [kiyo_device_info](repeating: kiyo_device_info(), count: capacity)
        var count: Int32 = 0

        let status = raw.withUnsafeMutableBufferPointer { buffer in
            kiyo_enumerate(buffer.baseAddress, Int32(capacity), &count)
        }
        guard status == 0 else {
            throw KiyoError.usb(operation: "device enumeration", code: status)
        }

        return raw.prefix(Int(count)).map { entry in
            KiyoDeviceInfo(
                locationID: entry.location_id,
                product: Self.decodeCString(entry.product),
                serial: Self.decodeCString(entry.serial),
                firmwareBCD: entry.bcd_device,
                unitID: entry.unit_id,
                vcInterface: entry.vc_interface,
                extensionUnitFound: entry.xu_found,
                foundViaFallbackScan: entry.xu_via_fallback)
        }
    }

    // MARK: - Lifecycle

    /// Opens the device at `locationID`, or the first match when it is nil.
    public init(locationID: UInt32? = nil, options: Options = Options()) throws {
        try options.validate()

        var opened: OpaquePointer?
        let status = kiyo_open(locationID ?? 0, &opened)
        guard status == 0, let opened else {
            throw KiyoError.usb(operation: "opening the camera", code: status)
        }

        self.handle = opened
        self.options = options
        // The open path only carries the addressing it needs; the cosmetic
        // fields come from a second (non-opening) discovery pass so that `list`
        // and the apply output describe the camera identically.
        let resolved = kiyo_location_id(opened)
        let discovered = (try? Self.enumerate())?.first { $0.locationID == resolved }
        self.info = KiyoDeviceInfo(
            locationID: resolved,
            product: discovered?.product ?? "Razer Kiyo Pro",
            serial: discovered?.serial ?? "",
            firmwareBCD: kiyo_bcd_device(opened),
            unitID: kiyo_unit_id(opened),
            vcInterface: kiyo_vc_interface(opened),
            extensionUnitFound: true,
            foundViaFallbackScan: discovered?.foundViaFallbackScan ?? false)
    }

    deinit { kiyo_close(handle) }

    // MARK: - Applying settings

    /// Sends `transfers` in order, sleeping between each one, and returns the
    /// total number of control transfers that went out — including the GET_LEN
    /// probe, since that is one more thing the firmware had to answer.
    @discardableResult
    public func run(_ transfers: [KiyoTransfer]) throws -> Int {
        guard !transfers.isEmpty else { return 0 }
        try Self.validate(transfers)

        let planned = transfers.count + 1 // mandatory GET_LEN
        guard planned <= options.transferLimit else {
            throw KiyoError.transferLimitExceeded(planned: planned, limit: options.transferLimit)
        }

        let length = try controlLength(for: .setISP)
        var sent = 1
        guard length == KiyoProtocol.payloadLength else {
            throw KiyoError.unexpectedControlLength(length)
        }

        for transfer in transfers {
            if sent > 0 { pause(milliseconds: options.delayMilliseconds) }
            try send(transfer)
            sent += 1
        }

        return sent
    }

    /// UVC GET_LEN. Cheap insurance against firmware drift.
    public func controlLength(for selector: KiyoProtocol.Selector) throws -> UInt16 {
        var length: UInt16 = 0
        let status = kiyo_get_len(handle, selector.rawValue, &length)

        let outcome = status == 0 ? "\(length)" : "failed"
        let addressing = String(format: "sel=0x%02x wIndex=0x%04x", selector.rawValue, info.wIndex)
        options.log?("  → GET_LEN  \(addressing) → \(outcome)")

        guard status == 0 else {
            throw KiyoError.usb(operation: "GET_LEN on \(selector.name)", code: status)
        }
        return length
    }

    /// UVC GET_CUR on the read-back selector.
    ///
    /// Known not to work on the firmware `cameractrls` was tested against, which
    /// is why nothing in this tool depends on it. Exposed so the failure can be
    /// characterised on newer firmware; callers should treat an error as normal.
    public func readBack(selector: KiyoProtocol.Selector = .getISPResult,
                         length: UInt16 = KiyoProtocol.payloadLength) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: Int(length))
        var done: UInt16 = 0

        let status = buffer.withUnsafeMutableBufferPointer { pointer in
            kiyo_get_cur(handle, selector.rawValue, pointer.baseAddress, length, &done)
        }
        guard status == 0 else {
            throw KiyoError.usb(operation: "GET_CUR on \(selector.name)", code: status)
        }
        return Array(buffer.prefix(Int(done)))
    }

    // MARK: - Internals

    static func validate(_ transfers: [KiyoTransfer]) throws {
        guard transfers.allSatisfy({
            $0.selector == .setISP && $0.payload.count == Int(KiyoProtocol.payloadLength)
        }) else {
            throw KiyoError.invalidArgument(
                "every write must use SET_ISP with an 8-byte payload")
        }
    }

    private func send(_ transfer: KiyoTransfer) throws {
        options.log?(describe(transfer))

        let status = transfer.payload.withUnsafeBufferPointer { buffer in
            kiyo_set_cur(handle, transfer.selector.rawValue,
                         buffer.baseAddress, UInt16(buffer.count))
        }
        guard status == 0 else {
            // A failed request can mean the camera firmware is already wedged.
            // Stop immediately rather than adding more control traffic.
            throw KiyoError.usb(operation: "SET_CUR (\(transfer.label))", code: status)
        }
    }

    public func describe(_ transfer: KiyoTransfer) -> String {
        transfer.describe(wIndex: info.wIndex)
    }

    /// Named to avoid shadowing Darwin's `sleep`, which takes seconds.
    private func pause(milliseconds: UInt32) {
        guard milliseconds > 0 else { return }
        Thread.sleep(forTimeInterval: Double(milliseconds) / 1000)
    }

    private static func decodeCString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { raw in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
}
