import Foundation
import CoreGraphics

/// Core decision logic: an IDLE <-> ENGAGED state machine, but every `evaluate()`
/// **idempotently re-asserts** the desired state rather than acting only on a transition.
///
/// Why re-assert every time: on plug/unplug/wake macOS reconfigures displays, and our
/// brightness/mirror settings can get wiped by that reconfig. Combined with `DisplayMonitor`'s
/// "settle confirm" recheck, a wipe self-heals within 1-3 seconds. This is not a polling
/// watchdog -- in steady state there are no events, so we don't re-assert repeatedly (with
/// auto-brightness off, brightness 0 stays put). Mirroring is only changed when missing
/// (otherwise the screen flickers).
///
/// Respecting manual override: while engaged we only re-assert "off" as long as the built-in is
/// still mirrored *and* dark. The moment the user reclaims it -- switches it to extended, or raises
/// its brightness above ~0.15 (wake only nudges it to ~0.06) -- we hand it back and stay hands-off
/// until the external is disconnected and reconnected. So the tool never traps the user in a dark
/// built-in it won't release.
///
/// This layer never touches system singletons; all side effects go through the injected
/// backend / state, so it is unit-testable without real hardware.
public final class DisplayController {
    private let backend: DisplayBackend
    private let state: StateManager
    private let epsilon: Float = 0.01
    /// Above this, an engaged built-in is read as "the user brought it back" rather than our 0 (wake leaves it ~0.06).
    private let reclaimThreshold: Float = 0.15
    /// At/below this the built-in counts as "effectively dark" -- the cutoff the restore/self-heal guards use.
    private let darkThreshold: Float = 0.1
    /// While yielded to the user, dragging the built-in at/below this counts as an explicit "dim it again" -- re-engage
    /// without an unplug/replug. Kept well below `yieldVisibleFloor` so handing the built-in back never reads as this.
    private let reArmThreshold: Float = 0.05
    /// When yielding a dark built-in back to the user, raise it at least this high so it's actually usable *and*
    /// clearly above `reArmThreshold` (otherwise the very act of yielding would re-trigger the re-engage above).
    private let yieldVisibleFloor: Float = 0.3
    /// The external we last mirrored the built-in onto. Lets us tell "the mirror master got unplugged" (heal by
    /// re-mirroring to a remaining external) apart from "the user switched the built-in to extended" (yield).
    /// In-memory: after the first engage it's always set; an unknown (nil) un-mirror is treated as a user switch.
    private var lastMirrorTarget: CGDirectDisplayID?

    public var log: ((String) -> Void)?
    public var notifyFailure: ((String) -> Void)?
    private var lastNotifiedError: String?
    /// A short "recheck window" after restoring: re-assert the restore repeatedly to prevent the first restore from being wiped by a display reconfig.
    private var restoreDeadline: Date?

    public init(backend: DisplayBackend, state: StateManager) {
        self.backend = backend
        self.state = state
    }

    /// Re-assert the desired state based on the current display topology. Triggered by startup, topology change, wake, and settle confirm.
    public func evaluate() {
        let awake = backend.onlineDisplays().filter { !$0.isAsleep }
        guard let builtin = awake.first(where: { $0.isBuiltin }) else {
            // No awake built-in display (lid closed / sleep): do nothing, keep state.
            return
        }
        let externals = awake.filter { !$0.isBuiltin }.map { $0.id }
        if !externals.isEmpty {
            ensureDimmed(builtin.id, externals: externals)
        } else {
            ensureRestored(builtin.id)
        }
    }

    // MARK: - Ensure built-in is dimmed (idempotent assertion)

    private func ensureDimmed(_ internalID: CGDirectDisplayID, externals: [CGDirectDisplayID]) {
        // Manual re-arm: while we've yielded the built-in to the user, them dragging its brightness back down to
        // ~off is an explicit "dim it again" -- re-engage in place (re-mirror + re-dim) without an unplug/replug.
        // `yieldToUser` guarantees a yielded built-in is left visibly lit (> reArmThreshold), so a brightness at/below
        // reArmThreshold here is necessarily the user's deliberate action, never our own restore. We keep engaged=true
        // and the session's recorded priorBrightness, so restore later still returns to the right value.
        if state.state.engaged, state.state.reclaimed,
           (backend.brightness(of: internalID) ?? 1) <= reArmThreshold {
            state.update { $0.reclaimed = false }
            guard ensureMirrored(internalID, externals: externals) else {
                fail("Failed to set mirroring; not applied")
                return
            }
            if assertDark(internalID) {
                log?("Built-in dragged to off while connected: re-dimming (no reconnect needed)")
            } else {
                fail("Could not disable the built-in's auto-brightness (private symbol may be gone); it may re-light")
            }
            return
        }

        // Already engaged this session: maintain, heal a topology change, or yield to a manual takeover.
        if state.state.engaged {
            // We've already handed control back to the user this session: stay out until they reconnect.
            if state.state.reclaimed { return }

            // The user raising the built-in's brightness well above our 0 is an unambiguous takeover (wake only
            // leaves it ~0.06), regardless of mirror state -- hand it back and stay out until reconnect.
            if (backend.brightness(of: internalID) ?? 0) >= reclaimThreshold {
                yieldToUser(internalID, switchedToExtended: false)
                return
            }

            let currentTarget = backend.mirrorTarget(of: internalID)
            let stillMirrored = currentTarget.map { externals.contains($0) } ?? false
            if stillMirrored {
                // Mirrored and dark -> re-assert "off" (heals e.g. wake nudging brightness back to ~0.06).
                lastMirrorTarget = currentTarget
                assertDark(internalID)
                return
            }

            // Not mirrored to any online external, but still dark. Two causes, told apart by whether the external
            // we were mirroring to is still attached:
            //   - it was unplugged while another external remains -> just re-mirror (heal), the user wants it off;
            //   - it's still attached, so the user un-mirrored it themselves -> they switched to extended -> yield.
            let mirrorTargetUnplugged = lastMirrorTarget.map { !externals.contains($0) } ?? false
            if mirrorTargetUnplugged {
                let newTarget = externals.min()!
                if backend.setMirror(of: internalID, to: newTarget) {
                    lastMirrorTarget = newTarget
                    state.update { $0.weChangedMirror = true }
                }
                assertDark(internalID)
                return
            }
            yieldToUser(internalID, switchedToExtended: true)
            return
        }

        // Fresh engage: capability check + record the original state needed for restore. engaged is set only
        // after everything succeeds, so a mirror failure won't leave a bogus "thinks it's dimmed" state.
        guard backend.canControlBrightness(of: internalID) else {
            fail("Cannot control built-in brightness (macOS may have changed); not applied")
            return
        }
        let autoOn = backend.autoBrightnessEnabled(of: internalID) ?? true
        state.update {
            $0.priorAutoBrightness = autoOn
            // Record pre-dim brightness for restore. Restore returns to this value, and the next dim reads
            // the same value, so it won't collapse over successive cycles (the root cause of the old 0.49 drift).
            if let b = backend.brightness(of: internalID), b > epsilon {
                $0.priorBrightness = b
            }
        }

        // Assert mirroring (see ensureMirrored); on failure don't fall back to extended+dim.
        guard ensureMirrored(internalID, externals: externals) else {
            fail("Failed to set mirroring; not applied")
            return
        }

        // Assert: turn off auto-brightness (the root cause) + zero brightness.
        let darkHeld = assertDark(internalID)

        state.update { $0.engaged = true; $0.reclaimed = false; $0.lastError = nil }
        lastNotifiedError = nil
        restoreDeadline = nil
        if darkHeld {
            log?("External connected: built-in mirrored and dimmed")
        } else {
            // Auto-brightness couldn't be disabled -> brightness 0 won't hold against ambient light. Surface it.
            fail("Could not disable the built-in's auto-brightness (private symbol may be gone); it may re-light")
        }
    }

    /// Mirror the built-in onto an online external. If it's already mirrored to *some* online external, leave it
    /// alone -- with multiple externals this avoids flipping the target back and forth (and flickering) due to the
    /// unstable ordering of CGGetOnlineDisplayList. Only when not mirrored, or the target is offline, do we mirror to
    /// a *deterministic* external (the lowest id). Returns false only when a needed mirror change failed.
    private func ensureMirrored(_ internalID: CGDirectDisplayID, externals: [CGDirectDisplayID]) -> Bool {
        let currentTarget = backend.mirrorTarget(of: internalID)
        let mirroredToOnlineExternal = currentTarget.map { externals.contains($0) } ?? false
        if !mirroredToOnlineExternal {
            let target = externals.min()!   // deterministic choice, doesn't drift across calls
            guard backend.setMirror(of: internalID, to: target) else { return false }
            state.update { $0.weChangedMirror = true }
        }
        lastMirrorTarget = backend.mirrorTarget(of: internalID)
        return true
    }

    /// Re-assert "off": disable auto-brightness (if the panel supports it) and set brightness to 0. Idempotent.
    /// Returns false if auto-brightness is supported but could NOT be disabled (so 0 won't hold against ambient light).
    @discardableResult
    private func assertDark(_ internalID: CGDirectDisplayID) -> Bool {
        var autoBrightnessHeld = true
        if backend.hasAutoBrightness(of: internalID) {
            autoBrightnessHeld = backend.setAutoBrightness(false, of: internalID)
        }
        // Only write when not already dark: a redundant setBrightness(0) re-fires the brightness-change
        // notification, bouncing us back through evaluate() in a tight loop (and flickering). Once at 0 it holds.
        if (backend.brightness(of: internalID) ?? 1) > epsilon {
            backend.setBrightness(0, of: internalID)
        }
        return autoBrightnessHeld
    }

    /// The user manually took the built-in back (extended it, or raised its brightness). Hand it over:
    /// re-enable auto-brightness, make sure it's actually visible, and stay hands-off until reconnect.
    private func yieldToUser(_ internalID: CGDirectDisplayID, switchedToExtended: Bool) {
        if state.state.priorAutoBrightness, backend.hasAutoBrightness(of: internalID) {
            backend.setAutoBrightness(true, of: internalID)
        }
        // If it's still dark (e.g. switched to extended, leaving it a black second screen), raise it so it's
        // usable. If the user reclaimed by raising the brightness themselves, leave their value untouched.
        // Floor the restore at yieldVisibleFloor: it must be both genuinely usable and clearly above reArmThreshold,
        // so handing the built-in back never itself trips the "dragged to off" re-engage on the next evaluate.
        if (backend.brightness(of: internalID) ?? 0) < reclaimThreshold {
            let restoreTo = max(state.state.priorBrightness, yieldVisibleFloor)
            backend.setBrightness(restoreTo, of: internalID)
        }
        state.update { $0.reclaimed = true }
        log?(switchedToExtended
             ? "Built-in switched to extended; handing it back, staying out until reconnect"
             : "Built-in brightness raised manually; handing it back, staying out until reconnect")
    }

    // MARK: - Ensure built-in is restored (idempotent assertion + recheck window)

    private func ensureRestored(_ internalID: CGDirectDisplayID) {
        if state.state.engaged {
            // dimmed/yielded -> restored transition: open a recheck window and re-assert the restore (guards the first restore against being wiped by reconfig).
            state.update { $0.engaged = false; $0.reclaimed = false; $0.lastError = nil }
            lastNotifiedError = nil
            restoreDeadline = Date().addingTimeInterval(5)
            log?("External disconnected: restoring built-in")
            performRestore(internalID, force: false)
        } else if let deadline = restoreDeadline, Date() < deadline {
            performRestore(internalID, force: false)
        } else if let b = backend.brightness(of: internalID), b < darkThreshold {
            // Self-heal fallback: only the built-in remains but it's dark (crash leftover / state file lost or corrupt / missed event),
            // force it bright unconditionally. This is the last line of defense for rule 3 -- the only screen must never stay dark, regardless of the engaged flag.
            performRestore(internalID, force: true)
            log?("Built-in was the only screen and dark; forced restore")
        }
        // Otherwise: never dimmed / window passed and built-in is fine -- don't touch the user's displays.
    }

    /// Restore brightness / auto-brightness / mirroring. Idempotent: only raise brightness when "still dark", to avoid fighting the user's manual brightness changes.
    private func performRestore(_ internalID: CGDirectDisplayID, force: Bool) {
        // Restore to pre-dim brightness (only set when still dark or forced, to avoid fighting the user's manual brightness changes).
        let current = backend.brightness(of: internalID) ?? 0
        if force || current < darkThreshold {
            // Normally priorBrightness is always > epsilon; if it got polluted to ~0 (state corrupt/tampered),
            // fall back to full brightness -- never "restore" to a value like 0.01 that is actually still dark.
            let target = state.state.priorBrightness > epsilon ? state.state.priorBrightness : 1.0
            backend.setBrightness(target, of: internalID)
        }
        // Auto-brightness was originally on -> turn it back on and let it take over subsequent tweaks.
        if state.state.priorAutoBrightness, backend.hasAutoBrightness(of: internalID) {
            backend.setAutoBrightness(true, of: internalID)
        }
        // Undo the mirror we added; clear the flag only once we *confirm it's actually undone*.
        // If undo fails (setMirror returns false or the target is still there), keep weChangedMirror=true and retry next time / next launch.
        if state.state.weChangedMirror {
            if backend.mirrorTarget(of: internalID) == nil {
                state.update { $0.weChangedMirror = false }
            } else if backend.setMirror(of: internalID, to: nil),
                      backend.mirrorTarget(of: internalID) == nil {
                state.update { $0.weChangedMirror = false }
            }
        }
    }

    /// Called on quit / uninstall / SIGTERM: unconditionally and forcibly fully restore the built-in (fail safe).
    public func restoreUnconditionally() {
        guard let builtin = backend.onlineDisplays().first(where: { $0.isBuiltin }) else { return }
        // Even if the persisted flag says "never touched", force it bright whenever the built-in is actually dark (state may be corrupt/stale).
        let builtinDark = (backend.brightness(of: builtin.id) ?? 1) < darkThreshold
        guard state.state.engaged || state.state.weChangedMirror || builtinDark else { return }
        if state.state.engaged { state.update { $0.engaged = false; $0.reclaimed = false } }
        // Clearing weChangedMirror is left to performRestore (only after confirming the mirror is undone); don't clear it unconditionally here,
        // otherwise an undo failure would lose the "should restore mirror" state.
        performRestore(builtin.id, force: true)
        restoreDeadline = nil
    }

    // MARK: - Fail loudly (same error notified only once)

    private func fail(_ message: String) {
        state.update { $0.lastError = message }
        log?("⚠️ " + message)
        if message != lastNotifiedError {
            lastNotifiedError = message
            notifyFailure?(message)
        }
    }
}
