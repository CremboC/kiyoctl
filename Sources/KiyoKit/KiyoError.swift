import CKiyoUSB
import Foundation

public enum KiyoError: Error, CustomStringConvertible {
    /// A failure from the IOKit transport. `code` is either a small `kiyo_status`
    /// or a raw `IOReturn`, so it is always worth printing verbatim.
    case usb(operation: String, code: Int32)
    /// The firmware reported a control length other than 8 for SET_ISP.
    case unexpectedControlLength(UInt16)
    /// The plan exceeded the transfer ceiling. This firmware stalls under load;
    /// a legitimate operation is only a handful of transfers.
    case transferLimitExceeded(planned: Int, limit: Int)
    case invalidArgument(String)

    public var description: String {
        switch self {
        case let .usb(operation, code):
            var rendered = "unrecognised status"
            if let text = kiyo_status_string(code) { rendered = String(cString: text) }
            // Small codes are ours; anything else is an IOReturn, which is only
            // ever recognisable in hex.
            let codeText = (code > 0 && code < 100)
                ? "kiyo_status \(code)"
                : String(format: "IOReturn 0x%08x", UInt32(bitPattern: code))
            return "\(operation) failed: \(rendered) (\(codeText))"
        case let .unexpectedControlLength(length):
            return """
                extension unit reported a control length of \(length), expected 8 — \
                refusing to write.
                """
        case let .transferLimitExceeded(planned, limit):
            return """
                plan needs \(planned) control transfers but the limit is \(limit). \
                This firmware is known to stall under control-transfer load; split the request.
                """
        case let .invalidArgument(message):
            return message
        }
    }
}
