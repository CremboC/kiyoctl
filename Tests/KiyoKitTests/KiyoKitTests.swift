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
        foundViaFallbackScan: false)
}
