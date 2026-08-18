import Foundation
import KiyoKit

enum KiyoCLI {
    static let version = "0.1.0"

    // MARK: - Entry point

    static func run(_ raw: [String]) -> Int32 {
        do {
            let arguments = try Arguments(raw)

            if arguments.has("--version") {
                print("kiyoctl \(version)")
                return 0
            }
            if arguments.has("--help", "-h") || arguments.positionals.isEmpty {
                print(helpText)
                return 0
            }

            switch arguments.positionals[0] {
            case "list":   try list(arguments)
            case "status": try status(arguments)
            case "fov":    try fov(arguments)
            case "hdr":    try hdr(arguments)
            case "af":     try autofocus(arguments)
            case "set":    try set(arguments)
            case "probe":  try probe(arguments)
            default:
                throw CLIFailure.usage("unknown command '\(arguments.positionals[0])'")
            }
            return 0
        } catch let failure as CLIFailure {
            complain("\(failure)")
            if case .usage = failure { complain("\nRun 'kiyoctl --help' for usage.") }
            return failure.exitCode
        } catch let failure as KiyoError {
            complain("\(failure)")
            return 1
        } catch {
            complain("\(error)")
            return 1
        }
    }

    // MARK: - list

    private struct DeviceJSON: Encodable {
        let product: String
        let serial: String?
        let locationID: String
        let firmware: String
        let extensionUnitFound: Bool
        let unitID: Int?
        let videoControlInterface: Int?
        let wIndex: String?
        let discoveredByFallbackScan: Bool
    }

    private static func list(_ arguments: Arguments) throws {
        let devices = try KiyoDevice.enumerate()

        if arguments.has("--json") {
            let payload = devices.map { device in
                DeviceJSON(
                    product: device.product,
                    serial: device.serial.isEmpty ? nil : device.serial,
                    locationID: device.locationHex,
                    firmware: device.firmwareVersion,
                    extensionUnitFound: device.extensionUnitFound,
                    unitID: device.extensionUnitFound ? Int(device.unitID) : nil,
                    videoControlInterface: device.extensionUnitFound ? Int(device.vcInterface) : nil,
                    wIndex: device.extensionUnitFound ? String(format: "0x%04x", device.wIndex) : nil,
                    discoveredByFallbackScan: device.foundViaFallbackScan)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(jsonText(try encoder.encode(payload)))
            return
        }

        guard !devices.isEmpty else { throw CLIFailure.noDevice }

        print("Razer Kiyo Pro — \(devices.count) device\(devices.count == 1 ? "" : "s") "
              + "(1532:0e05)\n")

        for device in devices {
            print("  \(device.product.isEmpty ? "Razer Kiyo Pro" : device.product)")
            field("location ID", device.locationHex)
            field("serial", device.serial.isEmpty ? "(not reported)" : device.serial)
            field("firmware", "\(device.firmwareVersion)  (bcdDevice "
                  + String(format: "0x%04x", device.firmwareBCD) + ")")

            if device.extensionUnitFound {
                field("extension unit", "bUnitID \(device.unitID) "
                      + String(format: "(0x%02x)", device.unitID)
                      + (device.foundViaFallbackScan ? "  [raw GUID scan]" : "  [descriptor walk]"))
                field("VideoControl", "bInterfaceNumber \(device.vcInterface)")
                field("wIndex", String(format: "0x%04x", device.wIndex))
                field("XU GUID", KiyoProtocol.extensionUnitGUID)
            } else {
                field("extension unit", "NOT FOUND")
                print("""

                      The Razer extension unit GUID is not in this device's descriptors, so
                      there is nothing to write to. Either the firmware predates it or this is
                      a different Kiyo model. Update the firmware from Windows and retry.
                      """)
            }
            print("")
        }
    }

    // MARK: - status

    private static func status(_ arguments: Arguments) throws {
        guard let state = KiyoStateStore.load() else {
            if arguments.has("--json") { print("{}") } else {
                print("No cached state yet — kiyoctl has not written to a camera on this Mac.")
            }
            return
        }

        if arguments.has("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(jsonText(try encoder.encode(state)))
            return
        }

        print("""
              Cached state — what kiyoctl last wrote, NOT read back from the camera.
              This firmware cannot report its current settings, and anything else (Synapse on
              another machine, another copy of this tool) may have changed them since.

              """)
        field("last written", state.updatedAt ?? "unknown")
        field("device", [state.locationID, state.serial, state.firmware.map { "firmware \($0)" }]
            .compactMap { $0 }.joined(separator: "  "))
        if let value = state.fieldOfView { field("fov", value) }
        if let value = state.hdr { field("hdr", value) }
        if let value = state.hdrMode { field("hdr mode", value) }
        if let value = state.autofocus { field("af", value) }
        field("persisted to camera", (state.persisted ?? false) ? "yes" : "no")
        field("cache file", KiyoStateStore.url.path)
    }

    // MARK: - Setting commands

    private static func fov(_ arguments: Arguments) throws {
        let value = try requireChoice(arguments, index: 1, of: FieldOfView.self, named: "field of view")
        try apply(KiyoSettings(fieldOfView: value), arguments)
    }

    private static func hdr(_ arguments: Arguments) throws {
        let value = try requireChoice(arguments, index: 1, of: HDR.self, named: "hdr")
        var settings = KiyoSettings(hdr: value)

        if let raw = arguments.value("--mode") {
            guard let mode = HDRMode(rawValue: raw.lowercased()) else {
                throw CLIFailure.usage("--mode expects "
                    + HDRMode.allCases.map(\.rawValue).joined(separator: " or ") + ", got '\(raw)'")
            }
            settings.hdrMode = mode
        }

        try apply(settings, arguments)
    }

    private static func autofocus(_ arguments: Arguments) throws {
        let value = try requireChoice(arguments, index: 1, of: AutofocusMode.self, named: "autofocus mode")
        try apply(KiyoSettings(autofocus: value), arguments)
    }

    private static func set(_ arguments: Arguments) throws {
        let pairs = arguments.positionals.dropFirst()
            .joined(separator: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !pairs.isEmpty else {
            throw CLIFailure.usage("set expects key=value pairs, e.g. 'kiyoctl set fov=narrow,hdr=off'")
        }

        var settings = KiyoSettings()
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                throw CLIFailure.usage("'\(pair)' is not a key=value pair")
            }
            let key = parts[0].lowercased()
            let value = parts[1].lowercased()

            switch key {
            case "fov":
                settings.fieldOfView = try choice(value, of: FieldOfView.self, named: "fov")
            case "hdr":
                settings.hdr = try choice(value, of: HDR.self, named: "hdr")
            case "hdrmode", "hdr-mode", "hdr_mode":
                settings.hdrMode = try choice(value, of: HDRMode.self, named: "hdrmode")
            case "af", "autofocus":
                settings.autofocus = try choice(value, of: AutofocusMode.self, named: "af")
            default:
                throw CLIFailure.usage("unknown setting '\(key)' — expected fov, hdr, hdrmode or af")
            }
        }

        try apply(settings, arguments)
    }

    // MARK: - The one code path that writes

    private static func apply(_ settings: KiyoSettings, _ arguments: Arguments) throws {
        let save = !arguments.has("--no-save")
        let verbose = arguments.has("--verbose", "-v")
        let plan = settings.plan(save: save)

        guard !plan.isEmpty else { throw CLIFailure.usage("nothing to apply") }

        let options = try arguments.deviceOptions(verboseLogging: verbose)

        if arguments.has("--dry-run") {
            // Deliberately does not open the device — a dry run should be
            // inert even if the camera is mid-call. It still enumerates so the
            // printed wIndex is the real discovered one where possible.
            let target = try dryRunTarget(arguments)
            printPlan(plan, target: target, options: options)
            return
        }

        let device = try KiyoDevice(locationID: try arguments.locationID(), options: options)
        if verbose { print(summaryHeader(for: device.info)) }

        let sent = try device.run(plan)

        print("Applied to \(device.info.product) at \(device.info.locationHex):")
        report(settings)
        field("saved to camera", save ? "yes" : "no — session only, lost on replug")
        print("\n\(sent) control transfer\(sent == 1 ? "" : "s"), "
              + "\(options.delayMilliseconds) ms apart.")

        var state: KiyoState
        if let cached = KiyoStateStore.load(), cached.belongs(to: device.info) {
            state = cached
        } else {
            state = KiyoState()
        }
        state.record(settings, on: device.info, saved: save)
        if !KiyoStateStore.save(state) {
            complain("note: the camera was updated, but the display cache at "
                     + "\(KiyoStateStore.url.path) could not be written.")
        }

    }

    // MARK: - probe

    private static func probe(_ arguments: Arguments) throws {
        let options = try arguments.deviceOptions(verboseLogging: false)
        let device = try KiyoDevice(locationID: try arguments.locationID(), options: options)

        print(summaryHeader(for: device.info))
        print("""

              Read-back experiment. Upstream reports that GET_CUR on the read-back selector
              does not work on this firmware, so failures below are expected, not errors.
              Nothing here writes to the camera.

              """)

        for selector in [KiyoProtocol.Selector.setISP, .getISPResult] {
            do {
                let length = try device.controlLength(for: selector)
                field("GET_LEN \(selector.name)", "\(length)"
                      + (length == KiyoProtocol.payloadLength ? "  (as expected)" : "  (UNEXPECTED)"))
            } catch {
                field("GET_LEN \(selector.name)", "failed — \(error)")
            }
            Thread.sleep(forTimeInterval: Double(options.delayMilliseconds) / 1000)
        }

        do {
            let bytes = try device.readBack()
            let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            field("GET_CUR GET_ISP_RESULT", bytes.isEmpty ? "returned 0 bytes" : hex)
            print("\nThis firmware answered the read-back. That is more than upstream saw — "
                  + "worth reporting to the cameractrls project.")
        } catch {
            field("GET_CUR GET_ISP_RESULT", "failed — \(error)")
            print("\nMatches upstream: read-back is unavailable. 'kiyoctl status' shows the "
                  + "write cache instead.")
        }
    }

    // MARK: - Output helpers

    private static func dryRunTarget(_ arguments: Arguments) throws -> KiyoDeviceInfo? {
        let requestedLocation = try arguments.locationID()
        let devices = try KiyoDevice.enumerate()

        if let requestedLocation {
            guard let device = devices.first(where: { $0.locationID == requestedLocation }) else {
                throw CLIFailure.noDevice
            }
            guard device.extensionUnitFound else {
                throw CLIFailure.runtime(
                    "camera at \(device.locationHex) does not expose the Razer extension unit")
            }
            return device
        }

        guard let device = devices.first else { return nil }
        guard device.extensionUnitFound else {
            throw CLIFailure.runtime("the first matched camera does not expose the Razer extension unit")
        }
        return device
    }

    private static func printPlan(_ plan: [KiyoTransfer],
                                  target: KiyoDeviceInfo?,
                                  options: KiyoDevice.Options) {
        print("Dry run — nothing was sent.\n")

        if let target {
            print("Target: \(target.product) at \(target.locationHex)")
            field("addressing", "bUnitID \(target.unitID), VideoControl interface "
                  + "\(target.vcInterface), wIndex "
                  + String(format: "0x%04x", target.wIndex))
        } else {
            print("No Kiyo Pro attached, so bUnitID could not be discovered.")
            field("addressing", "wIndex shown as 0x0000 — placeholder, not the real value")
        }

        let wIndex = target?.wIndex ?? 0
        let total = plan.count + 1
        print("\nPlanned transfers (\(total), \(options.delayMilliseconds) ms apart):")
        let addressing = String(format: "sel=0x01 wIndex=0x%04x", wIndex)
        print("  → GET_LEN  \(addressing)            # expect \(KiyoProtocol.payloadLength)")
        for transfer in plan { print(transfer.describe(wIndex: wIndex)) }
    }

    private static func summaryHeader(for info: KiyoDeviceInfo) -> String {
        "\(info.product) at \(info.locationHex) — firmware \(info.firmwareVersion), "
            + "bUnitID \(info.unitID), wIndex " + String(format: "0x%04x", info.wIndex)
    }

    private static func report(_ settings: KiyoSettings) {
        if let value = settings.fieldOfView {
            field("fov", "\(value.rawValue)  (~\(value.approximateDegrees)°)")
        }
        if let value = settings.hdr { field("hdr", value.rawValue) }
        if let value = settings.hdrMode { field("hdr mode", value.rawValue) }
        if let value = settings.autofocus { field("af", value.rawValue) }
    }

    private static func field(_ name: String, _ value: String) {
        print("    " + name.padding(toLength: max(20, name.count + 1), withPad: " ", startingAt: 0)
              + value)
    }

    private static func complain(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    // MARK: - Choice parsing

    private static func requireChoice<T: RawRepresentable & CaseIterable>(
        _ arguments: Arguments, index: Int, of type: T.Type, named name: String
    ) throws -> T where T.RawValue == String {
        guard arguments.positionals.count > index else {
            throw CLIFailure.usage("\(name) expects one of "
                + T.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return try choice(arguments.positionals[index].lowercased(), of: type, named: name)
    }

    private static func choice<T: RawRepresentable & CaseIterable>(
        _ raw: String, of type: T.Type, named name: String
    ) throws -> T where T.RawValue == String {
        guard let value = T(rawValue: raw) else {
            throw CLIFailure.usage("'\(raw)' is not a valid \(name) — expected "
                + T.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return value
    }

    // MARK: - Help

    static let helpText = """
        kiyoctl \(version) — field of view, HDR and autofocus for the Razer Kiyo Pro on macOS.

        These settings live behind a Razer vendor extension unit that the macOS UVC driver
        does not expose, which is why no other Mac app can reach them.

        USAGE
          kiyoctl list                          matched cameras, discovered bUnitID, wIndex
          kiyoctl fov wide|medium|narrow        ~103° / ~90° / ~80°
          kiyoctl hdr on|off [--mode dark|bright]
          kiyoctl af responsive|passive
          kiyoctl set fov=narrow,hdr=off        batch, with a single persist at the end
          kiyoctl status                        the write cache (see the caveat it prints)
          kiyoctl probe                         read-back experiment; writes nothing

        OPTIONS
          --device <id>        target one camera by location ID (hex or decimal)
          --no-save            skip the persist command — applies now, lost on replug
          --dry-run            print the transfers and exit without opening the device
          --verbose, -v        log every transfer as hex
          --delay <ms>         inter-transfer delay, floor and default 100
          --json               machine-readable output for list and status
          --version, --help

        NOTES
          Settings persist in the camera unless --no-save is passed, so this is a one-shot
          tool, not a daemon. Transfers are deliberately slow: this firmware stalls when
          driven hard, and the stall has been known to take a whole USB bus with it.

          Close Zoom, OBS, Photo Booth and other camera clients before applying settings.
          If the device is already in use, kiyoctl refuses to seize it.

        EXIT CODES
          0 success   1 runtime error   2 usage error   3 no camera found
        """
}

private func jsonText(_ data: Data) -> String {
    String(data: data, encoding: .utf8) ?? ""
}
