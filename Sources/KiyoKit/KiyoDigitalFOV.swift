import Foundation

/// Approximate conversion between the Kiyo Pro's percent-style digital zoom
/// and diagonal field of view. The camera reports Zoom Absolute as 100...400
/// but leaves the UVC focal-length descriptors at zero, so this cannot be a
/// calibrated optical measurement. Labels derived here must retain `~`.
public enum KiyoDigitalFOV {
    public static func approximateDegrees(baseDegrees: Double,
                                          zoomValue: UInt16,
                                          neutralZoomValue: UInt16) -> Double {
        guard baseDegrees > 0, baseDegrees < 180, neutralZoomValue > 0 else { return .nan }
        let magnification = Double(zoomValue) / Double(neutralZoomValue)
        guard magnification > 0 else { return .nan }

        let halfBase = baseDegrees * .pi / 360
        return 2 * atan(tan(halfBase) / magnification) * 180 / .pi
    }

    /// Returns the closest supported Zoom Absolute value for `targetDegrees`,
    /// or nil when that target is wider than the selected base or beyond the
    /// camera's reported digital-zoom range.
    public static func zoomValue(targetDegrees: Double,
                                 baseDegrees: Double,
                                 minimum: UInt16,
                                 maximum: UInt16,
                                 step: UInt16) -> UInt16? {
        guard targetDegrees > 0, targetDegrees <= baseDegrees,
              baseDegrees < 180, minimum > 0, maximum >= minimum, step > 0 else {
            return nil
        }

        let baseHalfAngle = baseDegrees * .pi / 360
        let targetHalfAngle = targetDegrees * .pi / 360
        let magnification = tan(baseHalfAngle) / tan(targetHalfAngle)
        let raw = Double(minimum) * magnification
        guard raw <= Double(maximum) + Double(step) / 2 else { return nil }

        let steps = ((raw - Double(minimum)) / Double(step)).rounded()
        let snapped = Double(minimum) + steps * Double(step)
        let bounded = min(Double(maximum), max(Double(minimum), snapped))
        return UInt16(bounded)
    }
}
