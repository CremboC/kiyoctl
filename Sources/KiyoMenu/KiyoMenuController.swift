import AppKit
import KiyoKit

final class KiyoMenuController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum ItemTag: Int {
        case fovWide = 100
        case fovMedium
        case fovNarrow
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

    private var settingItems: [NSMenuItem] = []
    private var fovItems: [NSMenuItem] = []
    private var hdrItems: [NSMenuItem] = []
    private var hdrModeItems: [NSMenuItem] = []
    private var autofocusItems: [NSMenuItem] = []
    private var device: KiyoDeviceInfo?
    private var isBusy = false
    private var hasUnsavedChanges = false

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

        fovItems = addSubmenu(
            title: "Field of View",
            entries: [
                ("Wide (~103°)", ItemTag.fovWide),
                ("Medium (~90°)", ItemTag.fovMedium),
                ("Narrow (~80°)", ItemTag.fovNarrow),
            ])

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

        resultItem.isEnabled = false
        menu.addItem(resultItem)
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

    // MARK: - Discovery

    @objc private func refreshCameraAction(_ sender: NSMenuItem) {
        refreshCamera()
    }

    private func refreshCamera() {
        guard !isBusy else { return }
        setBusy(true, message: "Discovering camera…")

        workQueue.async { [weak self] in
            let result: Result<KiyoDeviceInfo, Error>
            do {
                guard let found = try KiyoDevice.enumerate().first(where: { $0.extensionUnitFound }) else {
                    throw MenuFailure.noDevice
                }
                result = .success(found)
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                self?.finishDiscovery(result)
            }
        }
    }

    private func finishDiscovery(_ result: Result<KiyoDeviceInfo, Error>) {
        switch result {
        case let .success(info):
            device = info
            deviceItem.title = "\(info.product) • \(info.locationHex)"
            setConnectedIcon(toolTip: "KiyoMenu — \(info.product) connected")
        case let .failure(error):
            device = nil
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
        setBusy(true, message: "Applying \(operation.summary)…")

        workQueue.async { [weak self] in
            let result: Result<(KiyoDeviceInfo, Int), Error>
            do {
                let handle = try KiyoDevice(locationID: device.locationID)
                let sent = try handle.run(operation.settings.plan(save: shouldSave))

                var state: KiyoState
                if let cached = KiyoStateStore.load(), cached.belongs(to: handle.info) {
                    state = cached
                } else {
                    state = KiyoState()
                }
                state.record(operation.settings, on: handle.info, saved: shouldSave)
                _ = KiyoStateStore.save(state)
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
            select(selectedItem, in: operation.group)
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
                                    group: .fov, summary: "FOV Wide")
        case .fovMedium:
            return SettingOperation(settings: KiyoSettings(fieldOfView: .medium),
                                    group: .fov, summary: "FOV Medium")
        case .fovNarrow:
            return SettingOperation(settings: KiyoSettings(fieldOfView: .narrow),
                                    group: .fov, summary: "FOV Narrow")
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

                var state: KiyoState
                if let cached = KiyoStateStore.load(), cached.belongs(to: handle.info) {
                    state = cached
                } else {
                    state = KiyoState()
                }
                state.record(KiyoSettings(), on: handle.info, saved: true)
                _ = KiyoStateStore.save(state)
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

    private func setBusy(_ busy: Bool, message: String? = nil) {
        isBusy = busy
        if let message { resultItem.title = message }
        if busy { setIcon("hourglass", toolTip: "KiyoMenu — working") }
        updateAvailability()
    }

    private func updateAvailability() {
        let canApply = device != nil && !isBusy
        for item in settingItems { item.isEnabled = canApply }
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
