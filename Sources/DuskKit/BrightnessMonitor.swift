import Foundation
import CoreGraphics

/// Watches the built-in display's **brightness** and debounces before calling back to re-evaluate.
///
/// Why this exists: a manual brightness change fires **no** display-reconfiguration callback, so
/// `DisplayMonitor` never sees it. That's the whole reason re-engaging used to require an unplug/replug.
/// This monitor is the missing event source -- it lets "drag the built-in to off" re-trigger dimming
/// immediately (the controller's re-arm path in `ensureDimmed` keys off the resulting `evaluate()`).
///
/// Brightness notifications come from the private DisplayServices framework, loaded via dlopen exactly like
/// `DisplayControl`'s brightness wrapper. If the symbols are gone it degrades to a no-op: we just lose the
/// immediacy and still re-engage on the next topology/wake event.
public final class BrightnessMonitor {
    /// Schedules `work` after `delay` seconds. Injectable so tests can drive the clock; defaults to the main queue.
    public typealias Scheduler = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void

    private let debounceInterval: TimeInterval
    private let scheduler: Scheduler
    /// Enumerates the currently-online built-in display ids. Injectable for tests; defaults to CoreGraphics.
    private let builtinDisplays: () -> [CGDirectDisplayID]

    /// Bumped on every event; a scheduled debounce fires only if it's still the latest -- that is the debounce.
    private var generation = 0
    private var started = false
    private var registered: Set<CGDirectDisplayID> = []

    private let registerFn: RegisterFn?
    private let unregisterFn: UnregisterFn?

    /// Fired after a debounced brightness change (main thread).
    public var onChange: (() -> Void)?

    /// - debounceInterval: default 0.3s. A slider drag emits a burst of callbacks; debounce collapses them into one.
    public init(debounceInterval: TimeInterval = 0.3,
                builtinDisplays: @escaping () -> [CGDirectDisplayID] = BrightnessMonitor.onlineBuiltins,
                scheduler: @escaping Scheduler = { delay, work in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                }) {
        self.debounceInterval = debounceInterval
        self.builtinDisplays = builtinDisplays
        self.scheduler = scheduler
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        self.registerFn = loadFunction(handle, "DisplayServicesRegisterForBrightnessChangeNotifications")
        self.unregisterFn = loadFunction(handle, "DisplayServicesUnregisterForBrightnessChangeNotifications")
    }

    public func start() {
        guard !started else { return }
        started = true
        refresh()
    }

    public func stop() {
        guard started else { return }
        started = false
        for id in registered { _ = unregisterFn?(id, contextBits) }
        registered.removeAll()
        generation += 1   // invalidate any pending debounce
    }

    /// Re-sync registrations to the current online built-in displays. Call after a topology change: the built-in's
    /// id is stable in practice, but this keeps us correct if it ever changes (and is a cheap no-op when it doesn't).
    /// A failed registration is NOT marked registered, so the next refresh retries it.
    public func refresh() {
        guard started, let registerFn else { return }
        let current = Set(builtinDisplays())
        for id in registered.subtracting(current) {
            _ = unregisterFn?(id, contextBits)
            registered.remove(id)
        }
        for id in current.subtracting(registered) where registerFn(id, contextBits, brightnessChangeCallback) == 0 {
            registered.insert(id)
        }
    }

    /// Debounce a brightness change into a single `onChange` (collapses a slider drag's burst of callbacks).
    func scheduleChange() {
        generation += 1
        let gen = generation
        scheduler(debounceInterval) { [weak self] in
            guard let self, self.generation == gen else { return }   // a newer event superseded this one
            self.onChange?()
        }
    }

    /// The monitor pointer, passed through DisplayServices as the notification `context` and recovered in the callback.
    private var contextBits: UInt64 { UInt64(UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())) }

    deinit { stop() }

    /// Online built-in display ids via the public CoreGraphics API (default source for `builtinDisplays`).
    public static func onlineBuiltins() -> [CGDirectDisplayID] {
        onlineDisplayIDs().filter { CGDisplayIsBuiltin($0) != 0 }
    }
}

// MARK: - Private DisplayServices brightness-notification symbols

/// Callback signature confirmed empirically on macOS 26: (display, context, name, info). The `display` arg comes
/// back as 0 and `name` is the CFString "DisplayServicesBrightness"; only `context` (our monitor pointer) is reliable.
private typealias BrightnessCallback =
    @convention(c) (CGDirectDisplayID, UInt64, UnsafeRawPointer?, UnsafeRawPointer?) -> Void
private typealias RegisterFn = @convention(c) (CGDirectDisplayID, UInt64, BrightnessCallback) -> Int32
private typealias UnregisterFn = @convention(c) (CGDirectDisplayID, UInt64) -> Int32

private func loadFunction<T>(_ handle: UnsafeMutableRawPointer?, _ name: String) -> T? {
    guard let handle, let sym = dlsym(handle, name) else { return nil }
    return unsafeBitCast(sym, to: T.self)
}

/// A C function pointer can't capture context, so the monitor is recovered from the round-tripped `context` bits.
/// Dispatched to main before touching the monitor's state, so the debounce counter is only ever mutated there.
private let brightnessChangeCallback: BrightnessCallback = { _, context, _, _ in
    guard let raw = UnsafeRawPointer(bitPattern: UInt(context)) else { return }
    let monitor = Unmanaged<BrightnessMonitor>.fromOpaque(raw).takeUnretainedValue()
    DispatchQueue.main.async { monitor.scheduleChange() }
}
