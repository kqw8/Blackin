import CoreGraphics
@testable import DuskKit

/// Fake display backend for tests; never touches real hardware.
/// Records every write so we can assert what was / wasn't done.
final class MockDisplayBackend: DisplayBackend {
    var displays: [DisplayInfo]
    var brightnessMap: [CGDirectDisplayID: Float]
    var autoBrightnessMap: [CGDirectDisplayID: Bool]
    var hasALCMap: [CGDirectDisplayID: Bool]
    var mirrorMap: [CGDirectDisplayID: CGDirectDisplayID]   // display -> target

    var canControl = true            // CanChangeBrightness return value
    var brightnessSucceeds = true    // whether setBrightness succeeds (for testing failures)
    var mirrorSucceeds = true        // whether setMirror succeeds (for testing failures)

    // call log
    private(set) var brightnessSets: [(id: CGDirectDisplayID, value: Float)] = []
    private(set) var autoBrightnessSets: [(id: CGDirectDisplayID, enabled: Bool)] = []
    private(set) var mirrorSets: [(id: CGDirectDisplayID, target: CGDirectDisplayID?)] = []

    init(displays: [DisplayInfo],
         brightness: [CGDirectDisplayID: Float] = [:],
         autoBrightness: [CGDirectDisplayID: Bool] = [:],
         hasALC: [CGDirectDisplayID: Bool] = [:],
         mirror: [CGDirectDisplayID: CGDirectDisplayID] = [:]) {
        self.displays = displays
        self.brightnessMap = brightness
        self.autoBrightnessMap = autoBrightness
        self.hasALCMap = hasALC
        self.mirrorMap = mirror
    }

    func onlineDisplays() -> [DisplayInfo] { displays }

    func canControlBrightness(of id: CGDirectDisplayID) -> Bool { canControl }
    func brightness(of id: CGDirectDisplayID) -> Float? { brightnessMap[id] }
    @discardableResult
    func setBrightness(_ value: Float, of id: CGDirectDisplayID) -> Bool {
        guard brightnessSucceeds else { return false }
        brightnessMap[id] = value
        brightnessSets.append((id, value))
        return true
    }

    func hasAutoBrightness(of id: CGDirectDisplayID) -> Bool { hasALCMap[id] ?? false }
    func autoBrightnessEnabled(of id: CGDirectDisplayID) -> Bool? { autoBrightnessMap[id] }
    @discardableResult
    func setAutoBrightness(_ enabled: Bool, of id: CGDirectDisplayID) -> Bool {
        autoBrightnessMap[id] = enabled
        autoBrightnessSets.append((id, enabled))
        return true
    }

    func mirrorTarget(of id: CGDirectDisplayID) -> CGDirectDisplayID? { mirrorMap[id] }
    @discardableResult
    func setMirror(of id: CGDirectDisplayID, to target: CGDirectDisplayID?) -> Bool {
        guard mirrorSucceeds else { return false }
        mirrorSets.append((id, target))
        mirrorMap[id] = target
        return true
    }
}

/// Approximate float comparison (swift-testing's #expect has no built-in accuracy).
func approx(_ a: Float?, _ b: Float, _ eps: Float = 0.001) -> Bool {
    guard let a else { return false }
    return abs(a - b) < eps
}

// convenience constructors
extension DisplayInfo {
    static func builtin(_ id: CGDirectDisplayID, active: Bool = true, asleep: Bool = false) -> DisplayInfo {
        DisplayInfo(id: id, isBuiltin: true, isActive: active, isAsleep: asleep)
    }
    static func external(_ id: CGDirectDisplayID, active: Bool = true, asleep: Bool = false) -> DisplayInfo {
        DisplayInfo(id: id, isBuiltin: false, isActive: active, isAsleep: asleep)
    }
    /// The "secondary" builtin display in mirror mode: on (asleep=false) but isActive=false.
    static func mirroredBuiltin(_ id: CGDirectDisplayID) -> DisplayInfo {
        DisplayInfo(id: id, isBuiltin: true, isActive: false, isAsleep: false)
    }
}
