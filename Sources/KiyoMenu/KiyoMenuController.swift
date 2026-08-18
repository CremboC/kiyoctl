import AppKit
import KiyoKit

final class KiyoMenuController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum ItemTag: Int {
        case fovWide = 100
        case fovMedium
        case fovNarrow
        case fov70 = 140
        case fov60
        case fov50
        case fov40
        case fov30
        case fov24
        case hdrOff = 110
        case hdrOn
        case hdrModeDark = 120
        case hdrModeBright
        case afResponsive = 130
        case afPassive
    }

    private enum SettingGroup {
        case fov, hdr, hdrMode, autofocus
    }

    private struct SettingOperation {
        let settings: KiyoSettings
        let group: SettingGroup
        let summary: String
        let baseFOV: FieldOfView?

        init(settings: KiyoSettings, group: SettingGroup, summary: String,
             baseFOV: FieldOfView? = nil) {
            self.settings = settings
            self.group = group
            self.summary = summary
            self.baseFOV = baseFOV
        }
    }

    private enum MenuFailure: LocalizedError {
        case noDevice

        var errorDescription: String? {
            switch self {
            case .noDevice: return "No Razer Kiyo Pro (1532:0e05) was found"
            }
        }
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let workQueue = DispatchQueue(label: "com.kiyoctl.menu.usb", qos: .userInitiated)
    private let connectedIcon = KiyoMenuIcon.apertureTemplate()

    private let deviceItem = NSMenuItem(title: "Looking for Razer Kiyo Pro…", action: nil, keyEquivalent: "")
    private let resultItem = NSMenuItem(title: "Last applied: unknown (write-only camera)", action: nil,
                                        keyEquivalent: "")
    private let saveChangesItem = NSMenuItem(title: "Save changes to camera", action: nil,
                                             keyEquivalent: "")
    private let refreshItem = NSMenuItem(title: "Refresh Camera", action: nil, keyEquivalent: "r")
    private let quitItem = NSMenuItem(title: "Quit KiyoMenu", action: nil, keyEquivalent: "q")
    private let digitalFOVHeader = NSMenuItem(title: "Approximate FOV — select a base above",
                                               action: nil, keyEquivalent: "")

    private var settingItems: [NSMenuItem] = []
    private var fovItems: [NSMenuItem] = []
    private var digitalFOVItems: [NSMenuItem] = []
    private var hdrItems: [NSMenuItem] = []
    private var hdrModeItems: [NSMenuItem] = []
    private var autofocusItems: [NSMenuItem] = []
    private var device: KiyoDeviceInfo?
    private var isBusy = false
    private var hasUnsavedChanges = false
    private var zoomCapabilities: KiyoDevice.ZoomCapabilities?
    private var selectedBaseFOV: FieldOfView?
    private var rememberedState: KiyoState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        configureMenu()
        refreshCamera()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if device == nil, !isBusy { refreshCamera() }
    }

    // MARK: - Menu construction

    private func configureStatusItem() {
        statusItem.button?.image = symbol("video.slash", description: "Kiyo controls")
        statusItem.button?.toolTip = "KiyoMenu — camera not found"
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.autoenablesItems = false
        menu.delegate = self

        deviceItem.isEnabled = false
        menu.addItem(deviceItem)
        menu.addItem(.separator())

        fovItems = addFOVSubmenu()

        hdrItems = addSubmenu(
            title: "HDR",
            entries: [
                ("Off", ItemTag.hdrOff),
                ("On", ItemTag.hdrOn),
            ])

        hdrModeItems = addSubmenu(
            title: "HDR Mode",
            entries: [
                ("Dark", ItemTag.hdrModeDark),
                ("Bright", ItemTag.hdrModeBright),
            ])

        autofocusItems = addSubmenu(
            title: "Autofocus",
            entries: [
                ("Responsive", ItemTag.afResponsive),
                ("Passive", ItemTag.afPassive),
            ])

        settingItems = fovItems + hdrItems + hdrModeItems + autofocusItems

        menu.addItem(.separator())
        saveChangesItem.target = self
        saveChangesItem.action = #selector(toggleSaveChanges(_:))
        saveChangesItem.toolTip = "Checked: persist every change. Check after session-only edits to save them together."
        menu.addItem(saveChangesItem)

        let statusSubmenu = NSMenu(title: "Status")
        statusSubmenu.autoenablesItems = false
        resultItem.isEnabled = false
        statusSubmenu.addItem(resultItem)
        let statusParent = NSMenuItem(title: "Status", action: nil, keyEquivalent: "")
        statusParent.submenu = statusSubmenu
        menu.addItem(statusParent)
        menu.addItem(.separator())

        refreshItem.target = self
        refreshItem.action = #selector(refreshCameraAction(_:))
        menu.addItem(refreshItem)

        quitItem.target = self
        quitItem.action = #selector(quit(_:))
        menu.addItem(quitItem)

        updateAvailability()
    }

    private func addSubmenu(title: String, entries: [(String, ItemTag)]) -> [NSMenuItem] {
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false

        let items = entries.map { entry -> NSMenuItem in
            let item = NSMenuItem(title: entry.0, action: #selector(applySetting(_:)), keyEquivalent: "")
            item.target = self
            item.tag = entry.1.rawValue
            item.isEnabled = false
            submenu.addItem(item)
            return item
        }

        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        menu.addItem(parent)
        return items
    }

    private func addFOVSubmenu() -> [NSMenuItem] {
        let submenu = NSMenu(title: "Field of View")
        submenu.autoenablesItems = false

        let baseEntries: [(String, ItemTag)] = [
            ("Wide (~103°)", .fovWide),
            ("Medium (~90°)", .fovMedium),
            ("Narrow (~80°)", .fovNarrow),
        ]
        let baseItems = baseEntries.map { title, tag -> NSMenuItem in
            let item = NSMenuItem(title: title, action: #selector(applySetting(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag.rawValue
            submenu.addItem(item)
            return item
        }

        submenu.addItem(.separator())
        digitalFOVHeader.isEnabled = false
        submenu.addItem(digitalFOVHeader)

        let digitalEntries: [(Double, ItemTag)] = [
            (70, .fov70), (60, .fov60), (50, .fov50),
            (40, .fov40), (30, .fov30), (24, .fov24),
        ]
        digitalFOVItems = digitalEntries.map { degrees, tag -> NSMenuItem in
            let item = NSMenuItem(title: "~\(Int(degrees))°", action: #selector(applyDigitalFOV(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = tag.rawValue
            item.toolTip = "Approximate diagonal FOV using standard UVC digital zoom."
            submenu.addItem(item)
            return item
        }

        let parent = NSMenuItem(title: "Field of View", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        menu.addItem(parent)
        return baseItems + digitalFOVItems
    }

    // MARK: - Discovery

    @objc private func refreshCameraAction(_ sender: NSMenuItem) {
        refreshCamera()
    }

    private func refreshCamera() {
        guard !isBusy else { return }
        setBusy(true, message: "Discovering camera…")

        workQueue.async { [weak self] in
            let result: Result<(KiyoDeviceInfo, KiyoDevice.ZoomCapabilities?), Error>
            do {
                guard let found = try KiyoDevice.enumerate().first(where: { $0.extensionUnitFound }) else {
                    throw MenuFailure.noDevice
                }
                let zoom: KiyoDevice.ZoomCapabilities?
                if found.zoomAbsoluteSupported {
                    zoom = try? KiyoDevice(locationID: found.locationID).zoomCapabilities()
                } else {
                    zoom = nil
                }
                result = .success((found, zoom))
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                self?.finishDiscovery(result)
            }
        }
    }

    private func finishDiscovery(
        _ result: Result<(KiyoDeviceInfo, KiyoDevice.ZoomCapabilities?), Error>
    ) {
        switch result {
        case let .success((info, zoom)):
            device = info
            zoomCapabilities = zoom
            restoreRememberedState(for: info, zoom: zoom)
            deviceItem.title = "\(info.product) • \(info.locationHex)"
            setConnectedIcon(toolTip: "KiyoMenu — \(info.product) connected")
        case let .failure(error):
            device = nil
            zoomCapabilities = nil
            selectedBaseFOV = nil
            rememberedState = nil
            hasUnsavedChanges = false
            clearSelections()
            deviceItem.title = "Camera unavailable"
            resultItem.title = "Error: \(render(error))"
            setIcon("exclamationmark.triangle", toolTip: "KiyoMenu — \(render(error))")
        }
        setBusy(false)
    }

    // MARK: - Applying settings

    @objc private func applySetting(_ sender: NSMenuItem) {
        guard !isBusy, let device, let operation = operation(for: sender.tag) else { return }

        let shouldSave = saveChangesItem.state == .on
        let zoom = operation.baseFOV == nil ? nil : zoomCapabilities
        setBusy(true, message: "Applying \(operation.summary)…")

        workQueue.async { [weak self] in
            let result: Result<(KiyoDeviceInfo, Int), Error>
            do {
                let handle = try KiyoDevice(locationID: device.locationID)
                var sent = try handle.run(operation.settings.plan(save: shouldSave))
                if let zoom {
                    sent += try handle.setZoomAbsolute(zoom.minimum, capabilities: zoom)
                }

                result = .success((handle.info, sent))
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                self?.finishApply(result, operation: operation, selectedItem: sender, saved: shouldSave)
            }
        }
    }

    private func finishApply(_ result: Result<(KiyoDeviceInfo, Int), Error>,
                             operation: SettingOperation,
                             selectedItem: NSMenuItem,
                             saved: Bool) {
        switch result {
        case let .success((info, transferCount)):
            device = info
            hasUnsavedChanges = !saved
            if let baseFOV = operation.baseFOV { selectedBaseFOV = baseFOV }
            select(selectedItem, in: operation.group)
            var state = rememberedState ?? KiyoState()
            state.record(operation.settings, on: info, saved: saved)
            if let base = operation.baseFOV, let zoom = zoomCapabilities {
                state.zoomAbsolute = zoom.minimum
                state.approximateFieldOfView = Double(base.approximateDegrees)
            }
            rememberedState = state
            _ = KiyoStateStore.save(state)
            let storage = saved ? "saved to camera" : "session only"
            resultItem.title = "✓ \(operation.summary) • \(storage) • \(transferCount) transfers"
            setConnectedIcon(toolTip: "KiyoMenu — \(operation.summary), \(storage)")
        case let .failure(error):
            resultItem.title = "Error: \(render(error))"
            setIcon("exclamationmark.triangle", toolTip: "KiyoMenu — \(render(error))")
        }
        setBusy(false)
    }

    private func operation(for tag: Int) -> SettingOperation? {
        guard let tag = ItemTag(rawValue: tag) else { return nil }
        switch tag {
        case .fovWide:
            return SettingOperation(settings: KiyoSettings(fieldOfView: .wide),
                                    group: .fov, summary: "FOV Wide", baseFOV: .wide)
        case .fovMedium:
            return SettingOperation(settings: KiyoSettings(fieldOfView: .medium),
                                    group: .fov, summary: "FOV Medium", baseFOV: .medium)
        case .fovNarrow:
            return SettingOperation(settings: KiyoSettings(fieldOfView: .narrow),
                                    group: .fov, summary: "FOV Narrow", baseFOV: .narrow)
        case .fov70, .fov60, .fov50, .fov40, .fov30, .fov24:
            return nil
        case .hdrOff:
            return SettingOperation(settings: KiyoSettings(hdr: .off),
                                    group: .hdr, summary: "HDR Off")
        case .hdrOn:
            return SettingOperation(settings: KiyoSettings(hdr: .on),
                                    group: .hdr, summary: "HDR On")
        case .hdrModeDark:
            return SettingOperation(settings: KiyoSettings(hdrMode: .dark),
                                    group: .hdrMode, summary: "HDR Mode Dark")
        case .hdrModeBright:
            return SettingOperation(settings: KiyoSettings(hdrMode: .bright),
                                    group: .hdrMode, summary: "HDR Mode Bright")
        case .afResponsive:
            return SettingOperation(settings: KiyoSettings(autofocus: .responsive),
                                    group: .autofocus, summary: "AF Responsive")
        case .afPassive:
            return SettingOperation(settings: KiyoSettings(autofocus: .passive),
                                    group: .autofocus, summary: "AF Passive")
        }
    }

    @objc private func applyDigitalFOV(_ sender: NSMenuItem) {
        guard !isBusy, let device, let base = selectedBaseFOV,
              let zoom = zoomCapabilities, zoom.supportsSet,
              let target = digitalFOVTarget(for: sender.tag),
              let value = KiyoDigitalFOV.zoomValue(
                targetDegrees: target,
                baseDegrees: Double(base.approximateDegrees),
                minimum: zoom.minimum, maximum: zoom.maximum, step: zoom.step) else { return }

        let shouldSave = saveChangesItem.state == .on
        setBusy(true, message: "Applying FOV ~\(Int(target))°…")

        workQueue.async { [weak self] in
            let result: Result<(KiyoDeviceInfo, Int), Error>
            do {
                let handle = try KiyoDevice(locationID: device.locationID)
                var sent = try handle.setZoomAbsolute(value, capabilities: zoom)
                if shouldSave { sent += try handle.run(KiyoProtocol.persistPlan) }

                result = .success((handle.info, sent))
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                self?.finishDigitalFOV(result, selectedItem: sender, base: base,
                                       target: target, zoomValue: value, saved: shouldSave)
            }
        }
    }

    private func finishDigitalFOV(_ result: Result<(KiyoDeviceInfo, Int), Error>,
                                  selectedItem: NSMenuItem,
                                  base: FieldOfView,
                                  target: Double,
                                  zoomValue: UInt16,
                                  saved: Bool) {
        switch result {
        case let .success((info, transferCount)):
            device = info
            hasUnsavedChanges = !saved
            select(selectedItem, in: .fov)
            let actual = KiyoDigitalFOV.approximateDegrees(
                baseDegrees: Double(base.approximateDegrees),
                zoomValue: zoomValue,
                neutralZoomValue: zoomCapabilities?.minimum ?? 100)
            var state = rememberedState ?? KiyoState()
            state.recordDigitalFOV(base: base, zoomValue: zoomValue,
                                   approximateDegrees: actual,
                                   on: info, saved: saved)
            rememberedState = state
            _ = KiyoStateStore.save(state)
            let storage = saved ? "save requested" : "session only"
            resultItem.title = "✓ FOV ~\(Int(target))° • \(zoomValue)% from "
                + "\(base.rawValue) • \(storage) • \(transferCount) transfers"
            setConnectedIcon(toolTip: "KiyoMenu — FOV ~\(Int(target))°, \(storage)")
        case let .failure(error):
            resultItem.title = "Error: \(render(error))"
            setIcon("exclamationmark.triangle", toolTip: "KiyoMenu — \(render(error))")
        }
        setBusy(false)
    }

    private func digitalFOVTarget(for tag: Int) -> Double? {
        guard let tag = ItemTag(rawValue: tag) else { return nil }
        switch tag {
        case .fov70: return 70
        case .fov60: return 60
        case .fov50: return 50
        case .fov40: return 40
        case .fov30: return 30
        case .fov24: return 24
        default: return nil
        }
    }

    // MARK: - UI state

    @objc private func toggleSaveChanges(_ sender: NSMenuItem) {
        guard !isBusy else { return }

        if sender.state == .on {
            sender.state = .off
            resultItem.title = hasUnsavedChanges
                ? "Unsaved session changes pending"
                : "Future changes will be session only"
            return
        }

        sender.state = .on
        guard hasUnsavedChanges, let device else {
            resultItem.title = "✓ Future changes will be saved to camera"
            return
        }

        setBusy(true, message: "Saving accumulated changes to camera…")
        workQueue.async { [weak self] in
            let result: Result<(KiyoDeviceInfo, Int), Error>
            do {
                let handle = try KiyoDevice(locationID: device.locationID)
                let sent = try handle.run(KiyoProtocol.persistPlan)

                result = .success((handle.info, sent))
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                self?.finishSave(result)
            }
        }
    }

    private func finishSave(_ result: Result<(KiyoDeviceInfo, Int), Error>) {
        switch result {
        case let .success((info, transferCount)):
            device = info
            hasUnsavedChanges = false
            var state = rememberedState ?? KiyoState()
            state.record(KiyoSettings(), on: info, saved: true)
            rememberedState = state
            _ = KiyoStateStore.save(state)
            resultItem.title = "✓ Accumulated changes saved • \(transferCount) transfers"
            setConnectedIcon(toolTip: "KiyoMenu — changes saved to camera")
        case let .failure(error):
            resultItem.title = "Error saving changes: \(render(error))"
            setIcon("exclamationmark.triangle", toolTip: "KiyoMenu — \(render(error))")
        }
        setBusy(false)
    }

    private func select(_ item: NSMenuItem, in group: SettingGroup) {
        let items: [NSMenuItem]
        switch group {
        case .fov: items = fovItems
        case .hdr: items = hdrItems
        case .hdrMode: items = hdrModeItems
        case .autofocus: items = autofocusItems
        }
        for candidate in items { candidate.state = candidate === item ? .on : .off }
    }

    private func restoreRememberedState(for info: KiyoDeviceInfo,
                                        zoom: KiyoDevice.ZoomCapabilities?) {
        clearSelections()
        selectedBaseFOV = nil
        rememberedState = nil
        hasUnsavedChanges = false

        guard let cached = KiyoStateStore.load(), cached.canRestoreDisplay(for: info) else {
            if let zoom {
                resultItem.title = "Connected • camera zoom \(zoom.current)% • base FOV unknown"
            } else {
                resultItem.title = "Connected • no remembered settings"
            }
            return
        }

        rememberedState = cached
        if let raw = cached.fieldOfView, let base = FieldOfView(rawValue: raw) {
            selectedBaseFOV = base
            restoreFOVSelection(base: base, zoom: zoom, cached: cached)
        }
        if let raw = cached.hdr, let value = HDR(rawValue: raw) {
            selectRemembered(tag: value == .on ? .hdrOn : .hdrOff, in: .hdr)
        }
        if let raw = cached.hdrMode, let value = HDRMode(rawValue: raw) {
            selectRemembered(tag: value == .bright ? .hdrModeBright : .hdrModeDark,
                             in: .hdrMode)
        }
        if let raw = cached.autofocus, let value = AutofocusMode(rawValue: raw) {
            selectRemembered(tag: value == .passive ? .afPassive : .afResponsive,
                             in: .autofocus)
        }

        if let base = selectedBaseFOV, let zoom {
            let degrees = KiyoDigitalFOV.approximateDegrees(
                baseDegrees: Double(base.approximateDegrees),
                zoomValue: zoom.current, neutralZoomValue: zoom.minimum)
            resultItem.title = String(format:
                "Remembered base %@ • camera zoom %d%% • effective ~%.1f°",
                base.rawValue, Int(zoom.current), degrees)
        } else {
            resultItem.title = "Remembered settings restored • current base FOV unknown"
        }
    }

    private func restoreFOVSelection(base: FieldOfView,
                                     zoom: KiyoDevice.ZoomCapabilities?,
                                     cached: KiyoState) {
        let zoomValue = zoom?.current ?? cached.zoomAbsolute
        let neutral = zoom?.minimum ?? 100
        guard let zoomValue, zoomValue != neutral else {
            selectRemembered(tag: itemTag(for: base), in: .fov)
            return
        }

        let degrees = KiyoDigitalFOV.approximateDegrees(
            baseDegrees: Double(base.approximateDegrees),
            zoomValue: zoomValue, neutralZoomValue: neutral)
        let closest = digitalFOVItems.compactMap { item -> (NSMenuItem, Double)? in
            guard let target = digitalFOVTarget(for: item.tag) else { return nil }
            return (item, abs(target - degrees))
        }.min { $0.1 < $1.1 }

        if let closest, closest.1 < 1.0 { select(closest.0, in: .fov) }
    }

    private func itemTag(for value: FieldOfView) -> ItemTag {
        switch value {
        case .wide: return .fovWide
        case .medium: return .fovMedium
        case .narrow: return .fovNarrow
        }
    }

    private func selectRemembered(tag: ItemTag, in group: SettingGroup) {
        let items: [NSMenuItem]
        switch group {
        case .fov: items = fovItems
        case .hdr: items = hdrItems
        case .hdrMode: items = hdrModeItems
        case .autofocus: items = autofocusItems
        }
        guard let item = items.first(where: { $0.tag == tag.rawValue }) else { return }
        select(item, in: group)
    }

    private func clearSelections() {
        for item in settingItems { item.state = .off }
    }

    private func setBusy(_ busy: Bool, message: String? = nil) {
        isBusy = busy
        if let message { resultItem.title = message }
        if busy { setIcon("hourglass", toolTip: "KiyoMenu — working") }
        updateAvailability()
    }

    private func updateAvailability() {
        let canApply = device != nil && !isBusy
        for item in settingItems { item.isEnabled = canApply }
        let canApplyDigital = canApply && selectedBaseFOV != nil
            && zoomCapabilities?.supportsSet == true
        for item in digitalFOVItems {
            guard canApplyDigital, let base = selectedBaseFOV, let zoom = zoomCapabilities,
                  let target = digitalFOVTarget(for: item.tag) else {
                item.isEnabled = false
                continue
            }
            item.isEnabled = KiyoDigitalFOV.zoomValue(
                targetDegrees: target,
                baseDegrees: Double(base.approximateDegrees),
                minimum: zoom.minimum, maximum: zoom.maximum, step: zoom.step) != nil
        }
        if zoomCapabilities == nil {
            digitalFOVHeader.title = "Approximate FOV — zoom unavailable"
        } else if let base = selectedBaseFOV {
            digitalFOVHeader.title = "Digital crop from \(base.rawValue) (~\(base.approximateDegrees)°)"
        } else {
            digitalFOVHeader.title = "Approximate FOV — select a base above"
        }
        saveChangesItem.isEnabled = canApply
        refreshItem.isEnabled = !isBusy
        quitItem.isEnabled = !isBusy
    }

    private func setIcon(_ name: String, toolTip: String) {
        statusItem.button?.image = symbol(name, description: "Kiyo controls")
        statusItem.button?.toolTip = toolTip
    }

    private func setConnectedIcon(toolTip: String) {
        statusItem.button?.image = connectedIcon
        statusItem.button?.toolTip = toolTip
    }

    private func symbol(_ name: String, description: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        image?.isTemplate = true
        return image
    }

    private func render(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
