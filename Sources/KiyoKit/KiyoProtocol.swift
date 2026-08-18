import Foundation

/// Wire-level facts about the Razer Kiyo Pro's vendor-specific extension unit.
///
/// None of this is guessed. The payloads and the two-step field-of-view
/// sequence come from USB captures of Razer Synapse 3, by way of the
/// `cameractrls` / `kiyoproctrls` projects (MIT). See README.md.
public enum KiyoProtocol {
    public static let vendorID: UInt16 = 0x1532
    public static let productID: UInt16 = 0x0E05

    /// Canonical string form of the extension unit GUID. In the descriptor the
    /// first three fields are little-endian, so the bytes on the wire read
    /// `d0 9e e4 23 78 11 31 4f ae 52 d2 fb 8a 8d 3b 48`.
    public static let extensionUnitGUID = "23e49ed0-1178-4f31-ae52-d2fb8a8d3b48"

    /// UVC control selectors on the extension unit. There is deliberately no
    /// `bUnitID` here: it is discovered from the configuration descriptor at
    /// runtime, because firmware revisions renumber units.
    public enum Selector: UInt8, Sendable {
        /// Write an ISP command. Every setting this tool changes goes through here.
        case setISP = 0x01
        /// Read back an ISP result. Does not work on tested firmware — see `kiyoctl probe`.
        case getISPResult = 0x02

        public var name: String {
            switch self {
            case .setISP: return "SET_ISP"
            case .getISPResult: return "GET_ISP_RESULT"
            }
        }
    }

    /// Every payload on this unit is exactly 8 bytes.
    public static let payloadLength: UInt16 = 8

    /// Commit the live settings to the camera's non-volatile storage. Send it
    /// last, after the setting writes. Without it a setting applies to the
    /// current session and is lost on replug.
    public static let persist: [UInt8] = [0xc0, 0x03, 0xa8, 0x00, 0x00, 0x00, 0x00, 0x00]

    /// A constrained, persist-only plan for committing settings that were
    /// already applied to the live camera session. This intentionally exposes
    /// only the known persistence command, never arbitrary payloads.
    public static var persistPlan: [KiyoTransfer] {
        [KiyoTransfer(label: "persist to camera", payload: persist)]
    }

    /// Synapse sends this at startup. Its purpose is unknown and omitting it
    /// appears to be harmless. The CLI intentionally does not expose it.
    public static let unidentifiedInit: [UInt8] = [0xff, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
}

/// A single control transfer, with a label so `--verbose` and `--dry-run` can
/// explain what each one is for.
public struct KiyoTransfer: Sendable {
    public let label: String
    public let selector: KiyoProtocol.Selector
    public let payload: [UInt8]

    init(label: String, selector: KiyoProtocol.Selector = .setISP, payload: [UInt8]) {
        self.label = label
        self.selector = selector
        self.payload = payload
    }

    public var payloadHex: String {
        payload.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// One-line trace of the transfer, as `--verbose` and `--dry-run` print it.
    public func describe(wIndex: UInt16) -> String {
        let addressing = String(format: "sel=0x%02x wIndex=0x%04x", selector.rawValue, wIndex)
        return "  → SET_CUR \(addressing) len=\(payload.count)  \(payloadHex)  # \(label)"
    }
}

// MARK: - Settings

public enum FieldOfView: String, CaseIterable, Sendable {
    case wide, medium, narrow

    /// Approximate diagonal FOV. `wide` is the camera's factory default and the
    /// one with obvious barrel distortion at the frame edges.
    public var approximateDegrees: Int {
        switch self {
        case .wide: return 103
        case .medium: return 90
        case .narrow: return 80
        }
    }

    private var index: UInt8 {
        switch self {
        case .wide: return 0x00
        case .medium: return 0x01
        case .narrow: return 0x02
        }
    }

    public var transfers: [KiyoTransfer] {
        // Byte 2 distinguishes the "pre" write (0x00) from the real one (0x01);
        // byte 4 carries the FOV index. Medium and narrow need both writes.
        // Wide needs only the single write. The mechanism behind the pre-write
        // is not understood — Synapse sends it, so skipping it is not an option.
        let pre = KiyoTransfer(
            label: self == .wide ? "fov \(rawValue)" : "fov \(rawValue) — pre-write",
            payload: [0xff, 0x01, 0x00, 0x03, index, 0x00, 0x00, 0x00])

        guard self != .wide else { return [pre] }

        return [pre, KiyoTransfer(
            label: "fov \(rawValue)",
            payload: [0xff, 0x01, 0x01, 0x03, index, 0x00, 0x00, 0x00])]
    }
}

public enum HDR: String, CaseIterable, Sendable {
    case off, on

    public var transfers: [KiyoTransfer] {
        [KiyoTransfer(label: "hdr \(rawValue)",
                      payload: [0xff, 0x02, self == .on ? 0x01 : 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])]
    }
}

public enum HDRMode: String, CaseIterable, Sendable {
    case dark, bright

    public var transfers: [KiyoTransfer] {
        [KiyoTransfer(label: "hdr mode \(rawValue)",
                      payload: [0xff, 0x07, self == .bright ? 0x01 : 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])]
    }
}

public enum AutofocusMode: String, CaseIterable, Sendable {
    case responsive, passive

    public var transfers: [KiyoTransfer] {
        [KiyoTransfer(label: "af \(rawValue)",
                      payload: [0xff, 0x06, self == .passive ? 0x01 : 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])]
    }
}

/// A batch of settings to apply in one open/close cycle, with one persist at
/// the end. Any field left `nil` is not touched.
public struct KiyoSettings: Sendable {
    public var fieldOfView: FieldOfView?
    public var hdr: HDR?
    public var hdrMode: HDRMode?
    public var autofocus: AutofocusMode?

    public init(fieldOfView: FieldOfView? = nil,
                hdr: HDR? = nil,
                hdrMode: HDRMode? = nil,
                autofocus: AutofocusMode? = nil) {
        self.fieldOfView = fieldOfView
        self.hdr = hdr
        self.hdrMode = hdrMode
        self.autofocus = autofocus
    }

    public var isEmpty: Bool {
        fieldOfView == nil && hdr == nil && hdrMode == nil && autofocus == nil
    }

    /// The full ordered transfer list: settings first, then the persist command
    /// last. The unidentified Synapse startup command is deliberately excluded.
    public func plan(save: Bool) -> [KiyoTransfer] {
        var transfers: [KiyoTransfer] = []

        transfers += fieldOfView?.transfers ?? []
        transfers += hdr?.transfers ?? []
        transfers += hdrMode?.transfers ?? []
        transfers += autofocus?.transfers ?? []

        if save, !transfers.isEmpty {
            transfers += KiyoProtocol.persistPlan
        }

        return transfers
    }
}
