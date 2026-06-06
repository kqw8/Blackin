import Foundation
import CoreGraphics

/// Minimal info about a single display.
public struct DisplayInfo: Equatable {
    public let id: CGDirectDisplayID
    public let isBuiltin: Bool
    /// CoreGraphics active flag. In mirror mode the "slave" display is lit but isActive is still false,
    /// so don't decide on this alone; combine with isAsleep.
    public let isActive: Bool
    /// Whether asleep/off (built-in is usually asleep when lid is closed). Use !isAsleep to tell if it's lit.
    public let isAsleep: Bool

    public init(id: CGDirectDisplayID, isBuiltin: Bool, isActive: Bool, isAsleep: Bool = false) {
        self.id = id
        self.isBuiltin = isBuiltin
        self.isActive = isActive
        self.isAsleep = isAsleep
    }
}

/// Display-layer abstraction: list displays, control brightness, auto-brightness, and mirroring.
///
/// Real impl: enumeration/mirroring use the **public** CoreGraphics API; brightness/auto-brightness use the
/// **private** DisplayServices (dlopen, degrade gracefully if missing). Unit tests use a mock, no real hardware.
public protocol DisplayBackend: AnyObject {
    func onlineDisplays() -> [DisplayInfo]

    // Brightness (private DisplayServices)
    func canControlBrightness(of id: CGDirectDisplayID) -> Bool
    func brightness(of id: CGDirectDisplayID) -> Float?
    @discardableResult
    func setBrightness(_ value: Float, of id: CGDirectDisplayID) -> Bool

    // Auto-brightness / ambient light compensation (private DisplayServices). Disable it so brightness 0 holds.
    func hasAutoBrightness(of id: CGDirectDisplayID) -> Bool
    func autoBrightnessEnabled(of id: CGDirectDisplayID) -> Bool?
    @discardableResult
    func setAutoBrightness(_ enabled: Bool, of id: CGDirectDisplayID) -> Bool

    // Mirroring (public CoreGraphics)
    func mirrorTarget(of id: CGDirectDisplayID) -> CGDirectDisplayID?
    /// Mirror id onto target; target == nil means disable mirroring.
    @discardableResult
    func setMirror(of id: CGDirectDisplayID, to target: CGDirectDisplayID?) -> Bool
}

// MARK: - Private DisplayServices wrapper

private func loadSymbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
    guard let handle, let sym = dlsym(handle, name) else { return nil }
    return unsafeBitCast(sym, to: type)
}

/// Wrapper around private DisplayServices symbols. All loaded dynamically via dlopen/dlsym, degrade if missing,
/// never crash the tool when a private symbol changes (signatures verified on macOS 26).
final class DisplayServicesAPI {
    typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias CanChangeFn     = @convention(c) (CGDirectDisplayID) -> Bool
    typealias HasALCFn        = @convention(c) (CGDirectDisplayID) -> Bool
    typealias ALCEnabledFn    = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Bool>) -> Int32
    typealias EnableALCFn     = @convention(c) (CGDirectDisplayID, Bool) -> Int32

    private let getBrightnessF: GetBrightnessFn?
    private let setBrightnessF: SetBrightnessFn?
    private let canChangeF: CanChangeFn?
    private let hasALCF: HasALCFn?
    private let alcEnabledF: ALCEnabledFn?
    private let enableALCF: EnableALCFn?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        getBrightnessF = loadSymbol(handle, "DisplayServicesGetBrightness", as: GetBrightnessFn.self)
        setBrightnessF = loadSymbol(handle, "DisplayServicesSetBrightness", as: SetBrightnessFn.self)
        canChangeF     = loadSymbol(handle, "DisplayServicesCanChangeBrightness", as: CanChangeFn.self)
        hasALCF        = loadSymbol(handle, "DisplayServicesHasAmbientLightCompensation", as: HasALCFn.self)
        alcEnabledF    = loadSymbol(handle, "DisplayServicesAmbientLightCompensationEnabled", as: ALCEnabledFn.self)
        enableALCF     = loadSymbol(handle, "DisplayServicesEnableAmbientLightCompensation", as: EnableALCFn.self)
    }

    var brightnessAvailable: Bool { getBrightnessF != nil && setBrightnessF != nil }

    func getBrightness(_ id: CGDirectDisplayID) -> Float? {
        guard let getBrightnessF else { return nil }
        var value: Float = 0
        return getBrightnessF(id, &value) == 0 ? value : nil
    }
    func setBrightness(_ value: Float, _ id: CGDirectDisplayID) -> Bool {
        guard let setBrightnessF else { return false }
        return setBrightnessF(id, value) == 0
    }
    func canChangeBrightness(_ id: CGDirectDisplayID) -> Bool { canChangeF?(id) ?? false }
    func hasAmbient(_ id: CGDirectDisplayID) -> Bool { hasALCF?(id) ?? false }
    func ambientEnabled(_ id: CGDirectDisplayID) -> Bool? {
        guard let alcEnabledF else { return nil }
        var on = false
        return alcEnabledF(id, &on) == 0 ? on : nil
    }
    func setAmbient(_ enabled: Bool, _ id: CGDirectDisplayID) -> Bool {
        guard let enableALCF else { return false }
        return enableALCF(id, enabled) == 0
    }
}

// MARK: - Real backend

public final class SystemDisplayBackend: DisplayBackend {
    private let ds = DisplayServicesAPI()

    public init() {}

    /// Whether brightness control is available (private symbols loaded successfully).
    public var brightnessControlAvailable: Bool { ds.brightnessAvailable }

    public func onlineDisplays() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            DisplayInfo(id: id,
                        isBuiltin: CGDisplayIsBuiltin(id) != 0,
                        isActive: CGDisplayIsActive(id) != 0,
                        isAsleep: CGDisplayIsAsleep(id) != 0)
        }
    }

    // Brightness
    public func canControlBrightness(of id: CGDirectDisplayID) -> Bool { ds.canChangeBrightness(id) }
    public func brightness(of id: CGDirectDisplayID) -> Float? { ds.getBrightness(id) }
    @discardableResult
    public func setBrightness(_ value: Float, of id: CGDirectDisplayID) -> Bool {
        ds.setBrightness(max(0, min(1, value)), id)
    }

    // Auto-brightness
    public func hasAutoBrightness(of id: CGDirectDisplayID) -> Bool { ds.hasAmbient(id) }
    public func autoBrightnessEnabled(of id: CGDirectDisplayID) -> Bool? { ds.ambientEnabled(id) }
    @discardableResult
    public func setAutoBrightness(_ enabled: Bool, of id: CGDirectDisplayID) -> Bool {
        ds.setAmbient(enabled, id)
    }

    // Mirroring (public API)
    public func mirrorTarget(of id: CGDirectDisplayID) -> CGDirectDisplayID? {
        let target = CGDisplayMirrorsDisplay(id)
        return target == 0 ? nil : target
    }
    @discardableResult
    public func setMirror(of id: CGDirectDisplayID, to target: CGDirectDisplayID?) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        // target == nil -> pass 0 (kCGNullDirectDisplay) to disable mirroring.
        let master = target ?? CGDirectDisplayID(0)
        guard CGConfigureDisplayMirrorOfDisplay(config, id, master) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        // forSession: applies only to this login session; a hard crash/logout auto-reverts, reducing the risk of getting stuck mirrored.
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }
}
