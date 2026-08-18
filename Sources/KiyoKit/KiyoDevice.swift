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
    public let cameraTerminalFound: Bool
    public let cameraTerminalID: UInt8
    public let zoomAbsoluteSupported: Bool
    public let objectiveFocalLengthMin: UInt16
    public let objectiveFocalLengthMax: UInt16
    public let ocularFocalLength: UInt16

    /// `bcdDevice` rendered the way Razer's firmware notes write it.
    public var firmwareVersion: String {
        String(format: "%x.%02x", firmwareBCD >> 8, firmwareBCD & 0xff)
    }

    public var locationHex: String { String(format: "0x%08x", locationID) }

    /// The `wIndex` every request to this unit carries.
    public var wIndex: UInt16 { UInt16(unitID) << 8 | UInt16(vcInterface) }

    /// Address used by standard UVC Camera Terminal controls such as Zoom Absolute.
    public var cameraTerminalWIndex: UInt16 {
        UInt16(cameraTerminalID) << 8 | UInt16(vcInterface)
    }
}

/// An open handle on the camera's default control pipe.
///
/// Deliberately narrow: open, send a short ordered list of transfers with a
/// mandatory delay between them, close. There is no polling, no reapply timer
/// and no way to hold this open across a UI interaction — the firmware does not
/// tolerate sustained control traffic.
public final class KiyoDevice {
    public struct ZoomCapabilities: Sendable {
        public let minimum: UInt16
        public let maximum: UInt16
        public let step: UInt16
        public let defaultValue: UInt16
        public let current: UInt16
        public let supportsGet: Bool
        public let supportsSet: Bool
    }

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
    private var lastTransferNanoseconds: UInt64?
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
                foundViaFallbackScan: entry.xu_via_fallback,
                cameraTerminalFound: entry.camera_terminal_found,
                cameraTerminalID: entry.camera_terminal_id,
                zoomAbsoluteSupported: entry.zoom_absolute_supported,
                objectiveFocalLengthMin: entry.objective_focal_length_min,
                objectiveFocalLengthMax: entry.objective_focal_length_max,
                ocularFocalLength: entry.ocular_focal_length)
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
            foundViaFallbackScan: discovered?.foundViaFallbackScan ?? false,
            cameraTerminalFound: discovered?.cameraTerminalFound ?? false,
            cameraTerminalID: discovered?.cameraTerminalID ?? 0,
            zoomAbsoluteSupported: discovered?.zoomAbsoluteSupported ?? false,
            objectiveFocalLengthMin: discovered?.objectiveFocalLengthMin ?? 0,
            objectiveFocalLengthMax: discovered?.objectiveFocalLengthMax ?? 0,
            ocularFocalLength: discovered?.ocularFocalLength ?? 0)
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
            try send(transfer)
            sent += 1
        }

        return sent
    }

    /// UVC GET_LEN. Cheap insurance against firmware drift.
    public func controlLength(for selector: KiyoProtocol.Selector) throws -> UInt16 {
        paceBeforeTransfer()
        defer { recordTransfer() }
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

    /// Reads the standard UVC Zoom Absolute capability and range. This sends
    /// only GET requests, paced exactly like writes; it never changes camera state.
    public func zoomCapabilities() throws -> ZoomCapabilities {
        guard info.cameraTerminalFound, info.zoomAbsoluteSupported else {
            throw KiyoError.invalidArgument("this camera does not advertise UVC Zoom Absolute")
        }

        let requests: [(name: String, code: UInt8)] = [
            ("GET_INFO", 0x86),
            ("GET_MIN", 0x82),
            ("GET_MAX", 0x83),
            ("GET_RES", 0x84),
            ("GET_DEF", 0x87),
            ("GET_CUR", 0x81),
        ]
        guard requests.count <= options.transferLimit else {
            throw KiyoError.transferLimitExceeded(planned: requests.count,
                                                  limit: options.transferLimit)
        }

        var values: [UInt16] = []
        for request in requests {
            paceBeforeTransfer()
            var value: UInt16 = 0
            let status = kiyo_zoom_get(handle, request.code, &value)
            recordTransfer()
            let addressing = String(format: "sel=0x0b wIndex=0x%04x",
                                    info.cameraTerminalWIndex)
            options.log?("  → \(request.name)  \(addressing) → "
                         + (status == 0 ? "\(value)" : "failed"))
            guard status == 0 else {
                throw KiyoError.usb(operation: "\(request.name) on Zoom Absolute", code: status)
            }
            values.append(value)
        }

        let infoBits = values[0]
        return ZoomCapabilities(
            minimum: values[1],
            maximum: values[2],
            step: values[3],
            defaultValue: values[4],
            current: values[5],
            supportsGet: infoBits & 0x01 != 0,
            supportsSet: infoBits & 0x02 != 0)
    }

    /// Applies one already-range-checked UVC Zoom Absolute value. Callers pass
    /// the capabilities they just discovered so arbitrary or stale values are
    /// rejected before a SET request can leave the process.
    @discardableResult
    public func setZoomAbsolute(_ value: UInt16,
                                capabilities: ZoomCapabilities) throws -> Int {
        guard capabilities.supportsSet else {
            throw KiyoError.invalidArgument("this camera reports Zoom Absolute as read-only")
        }
        guard value >= capabilities.minimum, value <= capabilities.maximum else {
            throw KiyoError.invalidArgument(
                "zoom value \(value) is outside \(capabilities.minimum)...\(capabilities.maximum)")
        }
        let step = capabilities.step
        guard step > 0, (value - capabilities.minimum) % step == 0 else {
            throw KiyoError.invalidArgument(
                "zoom value \(value) is not aligned to step \(step)")
        }

        paceBeforeTransfer()
        options.log?(String(format: "  → SET_CUR sel=0x0b wIndex=0x%04x len=2  %02x %02x"
                            + "  # digital zoom",
                            info.cameraTerminalWIndex,
                            value & 0xff, value >> 8))
        let status = kiyo_zoom_set(handle, value)
        recordTransfer()
        guard status == 0 else {
            throw KiyoError.usb(operation: "SET_CUR (Zoom Absolute)", code: status)
        }
        return 1
    }

    /// UVC GET_CUR on the read-back selector.
    ///
    /// Known not to work on the firmware `cameractrls` was tested against, which
    /// is why nothing in this tool depends on it. Exposed so the failure can be
    /// characterised on newer firmware; callers should treat an error as normal.
    public func readBack(selector: KiyoProtocol.Selector = .getISPResult,
                         length: UInt16 = KiyoProtocol.payloadLength) throws -> [UInt8] {
        paceBeforeTransfer()
        defer { recordTransfer() }
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
        paceBeforeTransfer()
        defer { recordTransfer() }
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

    private func paceBeforeTransfer() {
        guard let previous = lastTransferNanoseconds else { return }
        let required = UInt64(options.delayMilliseconds) * 1_000_000
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= previous ? now - previous : 0
        guard elapsed < required else { return }
        Thread.sleep(forTimeInterval: Double(required - elapsed) / 1_000_000_000)
    }

    private func recordTransfer() {
        lastTransferNanoseconds = DispatchTime.now().uptimeNanoseconds
    }

    private static func decodeCString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { raw in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
}
