@testable import KiyoKit
import Testing

@Test func narrowPlanUsesPreWriteThenWriteThenPersist() {
    let plan = KiyoSettings(fieldOfView: .narrow).plan(save: true)

    #expect(plan.map(\.payload) == [
        [0xff, 0x01, 0x00, 0x03, 0x02, 0x00, 0x00, 0x00],
        [0xff, 0x01, 0x01, 0x03, 0x02, 0x00, 0x00, 0x00],
        KiyoProtocol.persist,
    ])
}

@Test func fullBatchStaysWithinSafetyCeiling() throws {
    let settings = KiyoSettings(
        fieldOfView: .medium, hdr: .on, hdrMode: .dark, autofocus: .responsive)
    let plan = settings.plan(save: true)

    #expect(plan.count + 1 == 7) // includes GET_LEN
    #expect(plan.count + 1 <= KiyoDevice.maximumTransfersPerRun)
    try KiyoDevice.validate(plan)
}

@Test func accumulatedSettingsCanBePersistedOnce() throws {
    let plan = KiyoProtocol.persistPlan

    #expect(plan.count == 1)
    #expect(plan.first?.payload == KiyoProtocol.persist)
    try KiyoDevice.validate(plan)
}

@Test func digitalFOVMappingUsesRectilinearCropGeometry() throws {
    let degrees = KiyoDigitalFOV.approximateDegrees(
        baseDegrees: 80, zoomValue: 200, neutralZoomValue: 100)
    #expect(abs(degrees - 45.52) < 0.02)

    let value = try #require(KiyoDigitalFOV.zoomValue(
        targetDegrees: 60, baseDegrees: 80,
        minimum: 100, maximum: 400, step: 1))
    #expect(value == 145)

    let roundTrip = KiyoDigitalFOV.approximateDegrees(
        baseDegrees: 80, zoomValue: value, neutralZoomValue: 100)
    #expect(abs(roundTrip - 60) < 0.2)
}

@Test func digitalFOVMappingRejectsUnsupportedAngles() {
    #expect(KiyoDigitalFOV.zoomValue(
        targetDegrees: 90, baseDegrees: 80,
        minimum: 100, maximum: 400, step: 1) == nil)
    #expect(KiyoDigitalFOV.zoomValue(
        targetDegrees: 20, baseDegrees: 80,
        minimum: 100, maximum: 400, step: 1) == nil)
}

@Test func unsafeOptionsAreRejectedBeforeOpeningUSBDevice() {
    var options = KiyoDevice.Options()
    options.delayMilliseconds = KiyoDevice.minimumDelayMilliseconds - 1
    expectError { try options.validate() }

    options = KiyoDevice.Options()
    options.transferLimit = KiyoDevice.maximumTransfersPerRun + 1
    expectError { try options.validate() }
}

@Test func unsafeWriteShapesAreRejected() {
    expectError {
        try KiyoDevice.validate([KiyoTransfer(label: "short", payload: [0xff])])
    }
    expectError {
        try KiyoDevice.validate([
            KiyoTransfer(label: "wrong selector", selector: .getISPResult,
                         payload: Array(repeating: 0, count: 8)),
        ])
    }
}

@Test func cachedStateDoesNotBelongToAnotherCamera() {
    let first = device(location: 0x1000, serial: "A")
    let second = device(location: 0x2000, serial: "B")
    var state = KiyoState()
    state.record(KiyoSettings(fieldOfView: .narrow), on: first, saved: true)

    #expect(state.belongs(to: first))
    #expect(!state.belongs(to: second))
}

@Test func cacheWithoutSerialIsNeverMerged() {
    let first = device(location: 0x1000, serial: "")
    var state = KiyoState()
    state.record(KiyoSettings(fieldOfView: .wide), on: first, saved: true)

    #expect(!state.belongs(to: first))
    #expect(state.canRestoreDisplay(for: first))
    #expect(!state.canRestoreDisplay(for: device(location: 0x2000, serial: "")))
}

private func expectError(_ body: () throws -> Void) {
    do {
        try body()
        Issue.record("expected operation to throw")
    } catch {
        // Expected.
    }
}

private func device(location: UInt32, serial: String) -> KiyoDeviceInfo {
    KiyoDeviceInfo(
        locationID: location,
        product: "Razer Kiyo Pro",
        serial: serial,
        firmwareBCD: 0x0821,
        unitID: 12,
        vcInterface: 0,
        extensionUnitFound: true,
        foundViaFallbackScan: false,
        cameraTerminalFound: true,
        cameraTerminalID: 1,
        zoomAbsoluteSupported: true,
        objectiveFocalLengthMin: 100,
        objectiveFocalLengthMax: 400,
        ocularFocalLength: 100)
}
