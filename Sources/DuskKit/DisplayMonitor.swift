import Foundation
import CoreGraphics
import AppKit

/// Watches display topology changes and system wake, then debounces before calling back to re-evaluate.
///
/// A single physical plug/unplug makes `CGDisplayRegisterReconfigurationCallback` fire several times,
/// so we must debounce before acting (rule 4). After sleep/wake the system relights the internal
/// display, so we re-evaluate then too (rule 5).
public final class DisplayMonitor {
    /// Schedules `work` to run after `delay` seconds. Injectable so tests can drive the clock deterministically;
    /// defaults to the real main-queue timer.
    public typealias Scheduler = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void

    private let debounceInterval: TimeInterval
    private let settleConfirmDelays: [TimeInterval]
    private let scheduler: Scheduler
    /// Bumped on every event; a scheduled debounce fires only if it's still the latest -- that is the debounce.
    private var generation = 0
    private var started = false

    /// Fired after a debounced topology or power-state change (main thread).
    public var onChange: (() -> Void)?

    /// - debounceInterval: default 0.3s. A plug/unplug emits a burst of events; debounce collapses
    ///   them into one action and also lets the display config settle (otherwise mirror/dim can fail).
    /// - settleConfirmDelays: extra "settle confirm" times (seconds) after the event. Covers transient
    ///   states like **lid open** where the internal display wakes late and isn't up yet at callback
    ///   time: confirms a few times then stops, not continuous polling.
    public init(debounceInterval: TimeInterval = 0.3,
                settleConfirmDelays: [TimeInterval] = [1.0, 3.0],
                scheduler: @escaping Scheduler = { delay, work in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                }) {
        self.debounceInterval = debounceInterval
        self.settleConfirmDelays = settleConfirmDelays
        self.scheduler = scheduler
    }

    public func start() {
        guard !started else { return }
        started = true

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, ctx)

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(handleWake),
                       name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleWake),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    public func stop() {
        guard started else { return }
        started = false
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(displayReconfigCallback, ctx)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        generation += 1   // invalidate any pending debounce
    }

    @objc private func handleWake() { scheduleChange() }

    /// Called from the C callback or wake notification; debounces, fires `onChange`, then schedules a few "settle confirm" passes.
    func scheduleChange() {
        generation += 1
        let gen = generation
        scheduler(debounceInterval) { [weak self] in
            guard let self, self.generation == gen else { return }   // a newer event superseded this one
            self.onChange?()
            // A bounded number of rechecks after the event, covering late internal-display wake (e.g. lid open); onChange is idempotent and stops once confirmed.
            for delay in self.settleConfirmDelays {
                self.scheduler(delay) { [weak self] in self?.onChange?() }
            }
        }
    }

    deinit { stop() }
}

/// `CGDisplayReconfigurationCallBack` is a C function pointer and can't capture context,
/// so self is passed in via userInfo.
private func displayReconfigCallback(_ display: CGDirectDisplayID,
                                     _ flags: CGDisplayChangeSummaryFlags,
                                     _ userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo else { return }
    // One plug/unplug emits many flags (begin / add-remove / mirror / desktop shape change...); we
    // don't filter finely, just scheduleChange every time and let debounce merge/dedupe. Missing an
    // event is far more dangerous than over-triggering.
    let monitor = Unmanaged<DisplayMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async { monitor.scheduleChange() }
}
