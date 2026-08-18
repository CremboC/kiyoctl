import Foundation
import KiyoKit

/// Reasons to stop before touching the camera.
enum CLIFailure: Error, CustomStringConvertible {
    case usage(String)
    case noDevice
    case runtime(String)

    var description: String {
        switch self {
        case let .usage(message): return message
        case .noDevice: return "no Razer Kiyo Pro (1532:0e05) found on the USB bus"
        case let .runtime(message): return message
        }
    }

    var exitCode: Int32 {
        switch self {
        case .usage: return 2
        case .noDevice: return 3
        case .runtime: return 1
        }
    }
}

/// A deliberately small hand-rolled parser. Adding swift-argument-parser would
/// mean a fetched dependency in something that is meant to stay a single signed
/// binary with no dylibs.
struct Arguments {
    private(set) var positionals: [String] = []
    private var flags: Set<String> = []
    private var values: [String: String] = [:]

    private static let valued: Set<String> = [
        "--device", "--delay", "--mode",
    ]
    private static let boolean: Set<String> = [
        "--dry-run", "--verbose", "-v", "--no-save", "--json",
        "--help", "-h", "--version",
    ]

    init(_ raw: [String]) throws {
        var iterator = raw.makeIterator()

        while let token = iterator.next() {
            guard token.hasPrefix("-"), token != "-" else {
                positionals.append(token)
                continue
            }

            // --key=value
            if let separator = token.firstIndex(of: "="), token.hasPrefix("--") {
                let key = String(token[token.startIndex..<separator])
                let value = String(token[token.index(after: separator)...])
                guard Self.valued.contains(key) else {
                    throw CLIFailure.usage("'\(key)' does not take a value")
                }
                values[key] = value
                continue
            }

            if Self.boolean.contains(token) {
                flags.insert(token)
                continue
            }

            if Self.valued.contains(token) {
                guard let value = iterator.next() else {
                    throw CLIFailure.usage("'\(token)' needs a value")
                }
                values[token] = value
                continue
            }

            throw CLIFailure.usage("unknown option '\(token)'")
        }
    }

    func has(_ flag: String...) -> Bool { flag.contains { flags.contains($0) } }

    func value(_ key: String) -> String? { values[key] }

    /// Bounded on purpose: these values end up as `UInt32` delays and as loop
    /// counts, so an absurd argument should be a usage error rather than a trap
    /// or a runaway allocation.
    func integer(_ key: String, max ceiling: Int = 60_000) throws -> Int? {
        guard let raw = values[key] else { return nil }
        guard let parsed = Int(raw), parsed >= 0 else {
            throw CLIFailure.usage("'\(key)' expects a non-negative integer, got '\(raw)'")
        }
        guard parsed <= ceiling else {
            throw CLIFailure.usage("'\(key)' must be at most \(ceiling), got \(parsed)")
        }
        return parsed
    }

    /// Location IDs are hex when prefixed `0x` and decimal otherwise.
    ///
    /// Deliberately not clever about a bare `14400000`: read as hex that is a
    /// different device than read as decimal, and silently picking one would
    /// mean writing to the wrong camera. `kiyoctl list` prints the `0x` form.
    func locationID() throws -> UInt32? {
        guard let raw = values["--device"] else { return nil }
        let normalised = raw.lowercased()

        if normalised.hasPrefix("0x") {
            guard let parsed = UInt32(normalised.dropFirst(2), radix: 16) else {
                throw CLIFailure.usage("could not parse --device '\(raw)' as hex")
            }
            return parsed
        }
        guard let parsed = UInt32(normalised) else {
            throw CLIFailure.usage("could not parse --device '\(raw)' — use the 0x-prefixed "
                + "location ID from 'kiyoctl list', or a plain decimal value")
        }
        return parsed
    }

    /// Shared transport options. `--delay` is clamped rather than trusted: the
    /// point of the delay is to protect firmware that is known to wedge, so a
    /// caller asking for less than the safe floor is asking for trouble.
    func deviceOptions(verboseLogging: Bool) throws -> KiyoDevice.Options {
        var options = KiyoDevice.Options()

        if let requested = try integer("--delay") {
            options.delayMilliseconds = UInt32(max(Int(KiyoDevice.minimumDelayMilliseconds), requested))
        }

        if verboseLogging {
            options.log = { message in print(message) }
        }

        return options
    }
}
