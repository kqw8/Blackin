import Testing
import CoreGraphics
import Foundation
@testable import DuskKit

struct DisplayControllerTests {
    let internalID: CGDirectDisplayID = 1
    let externalID: CGDirectDisplayID = 2

    private func tempState() -> StateManager {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dusk-test-\(UUID().uuidString).json")
        return StateManager(url: url)
    }

    // External plugged in while in extended mode: mirror + disable auto-brightness + zero brightness (don't record a fixed brightness while auto-brightness is on).
    @Test func engageFromExtendedMode() {
        let backend = MockDisplayBackend(
            displays: [.builtin(internalID), .external(externalID)],
            brightness: [internalID: 0.8, externalID: 0.5],
            autoBrightness: [internalID: true],
            hasALC: [internalID: true])
        let state = tempState()
        DisplayController(backend: backend, state: state).evaluate()

        #expect(backend.mirrorMap[internalID] == externalID)
        #expect(backend.autoBrightnessMap[internalID] == false)
        #expect(backend.brightnessMap[internalID] == 0)
        #expect(backend.brightnessMap[externalID] == 0.5)
        #expect(state.state.engaged)
        #expect(state.state.weChangedMirror)
        #expect(state.state.priorAutoBrightness)            // recorded that it was on
        #expect(approx(state.state.priorBrightness, 0.8))   // recorded brightness before dimming
    }

    // Already mirrored (real-hardware case): don't touch the mirror arrangement.
    @Test func engageWhenAlreadyMirroredDoesNotTouchMirror() {
        let backend = MockDisplayBackend(
            displays: [.mirroredBuiltin(internalID), .external(externalID)],
            brightness: [internalID: 0.8, externalID: 0.5],
            autoBrightness: [internalID: true],
            hasALC: [internalID: true],
            mirror: [internalID: externalID])
        let state = tempState()
        DisplayController(backend: backend, state: state).evaluate()

        #expect(backend.mirrorSets.isEmpty)
        #expect(state.state.weChangedMirror == false)
        #expect(backend.autoBrightnessMap[internalID] == false)
        #expect(backend.brightnessMap[internalID] == 0)
        #expect(state.state.engaged)
    }

    // Disconnect: auto-brightness was on -> raise from black + re-enable auto-brightness + undo the mirror we added.
    @Test func disengageRestoresAutoBrightness() {
        let backend = MockDisplayBackend(
            displays: [.builtin(internalID)],
            brightness: [internalID: 0],
            autoBrightness: [internalID: false],
            hasALC: [internalID: true],
            mirror: [internalID: externalID])
        let state = tempState()
        state.update {
            $0.engaged = true; $0.priorAutoBrightness = true
            $0.priorBrightness = 0.7; $0.weChangedMirror = true
        }
        DisplayController(backend: backend, state: state).evaluate()

        #expect(approx(backend.brightnessMap[internalID], 0.7))   // restored to pre-dim brightness
        #expect(backend.autoBrightnessMap[internalID] == true)    // auto-brightness restored
        #expect(backend.mirrorMap[internalID] == nil)             // mirror removed
        #expect(state.state.engaged == false)
    }

    // Disconnect: auto-brightness was off (manual) -> restore the recorded manual brightness.
    @Test func disengageRestoresManualBrightness() {
        let backend = MockDisplayBackend(
            displays: [.builtin(internalID)],
            brightness: [internalID: 0],
            autoBrightness: [internalID: false],
            hasALC: [internalID: true])
        let state = tempState()
        state.update {
            $0.engaged = true; $0.priorAutoBrightness = false
            $0.priorBrightness = 0.8; $0.weChangedMirror = false
        }
        DisplayController(backend: backend, state: state).evaluate()

        #expect(approx(backend.brightnessMap[internalID], 0.8))
        #expect(backend.mirrorSets.isEmpty)
        #expect(state.state.engaged == false)
    }

    // bug-1 fix check: first restore gets knocked back to black by a display reconfig; within the recheck window we re-assert the restore.
    @Test func reAssertsRestoreWithinWindow() {
        let backend = MockDisplayBackend(
            displays: [.builtin(internalID)],
            brightness: [internalID: 0],
            autoBrightness: [internalID: false],
            hasALC: [internalID: true])
        let state = tempState()
        state.update { $0.engaged = true; $0.priorAutoBrightness = true; $0.priorBrightness = 0.5 }
        let c = DisplayController(backend: backend, state: state)

        c.evaluate()                                              // transition: restore to 0.5
        #expect(approx(backend.brightnessMap[internalID], 0.5))
        backend.brightnessMap[internalID] = 0                     // simulate being knocked back to black by a reconfig
        c.evaluate()                                              // within recheck window: re-assert
        #expect(approx(backend.brightnessMap[internalID], 0.5))   // self-healed
    }

    // Re-triggered while already dimmed: don't re-apply the mirror (no flicker); brightness can be re-asserted idempotently.
    @Test func idempotentDoesNotReapplyMirror() {
        let backend = MockDisplayBackend(
            displays: [.mirroredBuiltin(internalID), .external(externalID)],
            brightness: [internalID: 0, externalID: 0.5],
            autoBrightness: [internalID: false],
            hasALC: [internalID: true],
            mirror: [internalID: externalID])
        let state = tempState()
        state.update { $0.engaged = true; $0.weChangedMirror = false }
        DisplayController(backend: backend, state: state).evaluate()

        #expect(backend.mirrorSets.isEmpty)                       // no mirror reconfig
        #expect(backend.brightnessMap[internalID] == 0)           // still 0
    }

    // Can't control brightness: fail loudly, never enter a half-baked state (no mirror, no dimming, don't set engaged).
    @Test func failsLoudlyWhenCannotControlBrightness() {
        let backend = MockDisplayBackend(
            displays: [.builtin(internalID), .external(externalID)],
            brightness: [internalID: 0.8],
            autoBrightness: [internalID: true],
            hasALC: [internalID: true])
        backend.canControl = false
        let state = tempState()
        var failures: [String] = []
        let c = DisplayController(backend: backend, state: state)
        c.notifyFailure = { failures.append($0) }
        c.evaluate()

        #expect(failures.isEmpty == false)
        #expect(state.state.lastError != nil)
        #expect(backend.mirrorSets.isEmpty)
        #expect(backend.brightnessSets.isEmpty)
        #expect(state.state.engaged == false)
    }

    // Mirror fails: fail loudly, don't dim, don't set engaged (no half-baked ghost screen).
    @Test func failsLoudlyWhenMirrorFails() {
        let backend = MockDisplayBackend(
            displays: [.builtin(internalID), .external(externalID)],
            brightness: [internalID: 0.8],
            autoBrightness: [internalID: true],
            hasALC: [internalID: true])
        backend.mirrorSucceeds = false
        let state = tempState()
        var failures: [String] = []
        let c = DisplayController(backend: backend, state: state)
        c.notifyFailure = { failures.append($0) }
        c.evaluate()

        #expect(failures.isEmpty == false)
        #expect(state.state.lastError != nil)
        #expect(backend.brightnessMap[internalID] == 0.8)   // not dimmed
        #expect(backend.autoBrightnessSets.isEmpty)         // never got to disabling auto-brightness
        #expect(state.state.engaged == false)
        #expect(state.state.weChangedMirror == false)
    }

    // Internal only, never dimmed: don't touch the displays.
    @Test func onlyInternalDoesNothing() {
        let backend = MockDisplayBackend(
            displays: [.builtin(internalID)],
            brightness: [internalID: 0.7])
        let state = tempState()
        DisplayController(backend: backend, state: state).evaluate()

        #expect(backend.brightnessSets.isEmpty)
        #expect(backend.mirrorSets.isEmpty)
    }

    // Internal asleep (lid closed): do nothing.
    @Test func asleepInternalIgnored() {
        let backend = MockDisplayBackend(
            displays: [.builtin(internalID, asleep: true), .external(externalID)],
            brightness: [internalID: 0.8])
        let state = tempState()
        DisplayController(backend: backend, state: state).evaluate()

        #expect(backend.brightnessSets.isEmpty)
        #expect(backend.mirrorSets.isEmpty)
    }

    // Missed the unplug event, only internal left and it's black: rescue it (manual-brightness path).
    @Test func staleEngagedRescuedWhenAlone() {
        let backend = MockDisplayBackend(
            displays: [.builtin(internalID)],
            brightness: [internalID: 0],
            autoBrightness: [internalID: false],
            hasALC: [internalID: true],
            mirror: [internalID: externalID])
        let state = tempState()
        state.update {
            $0.engaged = true; $0.priorAutoBrightness = false
            $0.priorBrightness = 0.6; $0.weChangedMirror = true
        }
        DisplayController(backend: backend, state: state).evaluate()

        #expect(approx(backend.brightnessMap[internalID], 0.6))
        #expect(backend.mirrorMap[internalID] == nil)
        #expect(state.state.engaged == false)
    }

    // Unconditional forced restore (uninstall / exit fallback).
    @Test func restoreUnconditionallyForces() {
        let backend = MockDisplayBackend(
            displays: [.builtin(internalID), .external(externalID)],
            brightness: [internalID: 0, externalID: 0.5],
            autoBrightness: [internalID: false],
            hasALC: [internalID: true],
            mirror: [internalID: externalID])
        let state = tempState()
        state.update {
            $0.engaged = true; $0.priorAutoBrightness = true
            $0.priorBrightness = 0.5; $0.weChangedMirror = true
        }
        DisplayController(backend: backend, state: state).restoreUnconditionally()

        #expect(approx(backend.brightnessMap[internalID], 0.5))   // forced restore
        #expect(backend.autoBrightnessMap[internalID] == true)
        #expect(backend.mirrorMap[internalID] == nil)
        #expect(state.state.engaged == false)
    }

    // Multiple externals: already mirrored to one online external -> don't keep switching between them (no thrash, no flicker).
    @Test func multipleExternalsDoesNotChurnMirror() {
        let ext2: CGDirectDisplayID = 3
        let backend = MockDisplayBackend(
            displays: [.mirroredBuiltin(internalID), .external(externalID), .external(ext2)],
            brightness: [internalID: 0, externalID: 0.5, ext2: 0.5],
            autoBrightness: [internalID: false],
            hasALC: [internalID: true],
            mirror: [internalID: ext2])
        let state = tempState()
        state.update { $0.engaged = true }
        DisplayController(backend: backend, state: state).evaluate()

        #expect(backend.mirrorSets.isEmpty)              // didn't switch mirror target
        #expect(backend.mirrorMap[internalID] == ext2)   // kept as-is
    }

    // Multiple externals, not yet mirrored: deterministically mirror to the lowest id (no drift across calls).
    @Test func multipleExternalsMirrorsToLowestId() {
        let ext2: CGDirectDisplayID = 3
        let backend = MockDisplayBackend(
            displays: [.builtin(internalID), .external(externalID), .external(ext2)],
            brightness: [internalID: 0.8, externalID: 0.5, ext2: 0.5],
            autoBrightness: [internalID: true],
            hasALC: [internalID: true])
        let state = tempState()
        DisplayController(backend: backend, state: state).evaluate()

        #expect(backend.mirrorMap[internalID] == externalID)   // 2 < 3, pick externalID
    }

    // Self-heal fallback: only internal left but black, and state is default/lost (engaged=false) -> still force it bright (red line 3).
    @Test func selfHealsDarkSoleScreenEvenWhenStateSaysIdle() {
        let backend = MockDisplayBackend(
            displays: [.builtin(internalID)],
            brightness: [internalID: 0],
            autoBrightness: [internalID: false],
            hasALC: [internalID: true])
        let state = tempState()   // defaults: engaged=false, priorBrightness=1.0
        DisplayController(backend: backend, state: state).evaluate()

        #expect((backend.brightnessMap[internalID] ?? 0) > 0.1)   // rescued to bright, never left black
    }

    // priorBrightness corrupted to 0 (damaged/tampered): restore falls back to full brightness, never "restores" to a black value like 0.01.
    @Test func restoreFloorAvoidsBlackOnCorruptPriorBrightness() {
        let backend = MockDisplayBackend(
            displays: [.builtin(internalID)],
            brightness: [internalID: 0],
            autoBrightness: [internalID: false],
            hasALC: [internalID: true])
        let state = tempState()
        state.update { $0.engaged = true; $0.priorBrightness = 0; $0.priorAutoBrightness = false }
        DisplayController(backend: backend, state: state).evaluate()

        #expect(approx(backend.brightnessMap[internalID], 1.0))
    }

    // User switches the built-in to extended while engaged: hand it back (restore brightness + auto-brightness),
    // do NOT force the mirror back, and mark it reclaimed so we stay out.
    @Test func yieldsWhenUserSwitchesToExtended() {
        let backend = MockDisplayBackend(
            displays: [.builtin(internalID), .external(externalID)],   // built-in is a normal display again
            brightness: [internalID: 0, externalID: 0.5],
            autoBrightness: [internalID: false],
            hasALC: [internalID: true],
            mirror: [:])                                               // not mirrored -> the user extended it
        let state = tempState()
        state.update {
            $0.engaged = true; $0.weChangedMirror = true
            $0.priorAutoBrightness = true; $0.priorBrightness = 0.7
        }
        DisplayController(backend: backend, state: state).evaluate()

        #expect(approx(backend.brightnessMap[internalID], 0.7))   // raised so the extended screen is usable
        #expect(backend.autoBrightnessMap[internalID] == true)    // auto-brightness handed back
        #expect(backend.mirrorSets.isEmpty)                       // did NOT force the mirror back on
        #expect(state.state.reclaimed)
    }

    // User raises the built-in brightness while engaged (still mirrored): respect it, re-enable auto-brightness,
    // don't zero it back, mark reclaimed.
    @Test func yieldsWhenUserRaisesBrightness() {
        let backend = MockDisplayBackend(
            displays: [.mirroredBuiltin(internalID), .external(externalID)],
            brightness: [internalID: 0.8, externalID: 0.5],          // user pushed it up
            autoBrightness: [internalID: false],
            hasALC: [internalID: true],
            mirror: [internalID: externalID])
        let state = tempState()
        state.update {
            $0.engaged = true; $0.weChangedMirror = false
            $0.priorAutoBrightness = true; $0.priorBrightness = 0.6
        }
        DisplayController(backend: backend, state: state).evaluate()

        #expect(approx(backend.brightnessMap[internalID], 0.8))   // left at the user's value, not zeroed
        #expect(backend.autoBrightnessMap[internalID] == true)    // auto-brightness handed back
        #expect(state.state.reclaimed)
    }

    // Wake nudges the built-in to ~0.06 (still dark, still mirrored): NOT a manual takeover -- re-assert 0.
    @Test func wakeDriftIsNotReclaim() {
        let backend = MockDisplayBackend(
            displays: [.mirroredBuiltin(internalID), .external(externalID)],
            brightness: [internalID: 0.06, externalID: 0.5],
            autoBrightness: [internalID: false],
            hasALC: [internalID: true],
            mirror: [internalID: externalID])
        let state = tempState()
        state.update { $0.engaged = true }
        DisplayController(backend: backend, state: state).evaluate()

        #expect(backend.brightnessMap[internalID] == 0)    // re-zeroed
        #expect(state.state.reclaimed == false)            // not treated as the user
    }

    // After yielding, stay completely hands-off while the external is still connected.
    @Test func staysHandsOffAfterReclaim() {
        let backend = MockDisplayBackend(
            displays: [.mirroredBuiltin(internalID), .external(externalID)],
            brightness: [internalID: 0.8, externalID: 0.5],
            autoBrightness: [internalID: true],
            hasALC: [internalID: true],
            mirror: [internalID: externalID])
        let state = tempState()
        state.update { $0.engaged = true; $0.reclaimed = true }
        DisplayController(backend: backend, state: state).evaluate()

        #expect(backend.brightnessSets.isEmpty)
        #expect(backend.mirrorSets.isEmpty)
        #expect(backend.autoBrightnessSets.isEmpty)
    }

    // Reclaim is per-connection: after unplugging and connecting a fresh external, engage again.
    @Test func reEngagesOnReconnectAfterReclaim() {
        let state = tempState()
        state.update {
            $0.engaged = true; $0.reclaimed = true
            $0.weChangedMirror = true; $0.priorBrightness = 0.7
        }

        // Unplug: only the built-in remains -> the session resets (engaged + reclaimed cleared).
        let afterUnplug = MockDisplayBackend(
            displays: [.builtin(internalID)],
            brightness: [internalID: 0.7],
            autoBrightness: [internalID: true],
            hasALC: [internalID: true])
        DisplayController(backend: afterUnplug, state: state).evaluate()
        #expect(state.state.engaged == false)
        #expect(state.state.reclaimed == false)

        // Replug an external: engage again (mirror + dim).
        let afterReplug = MockDisplayBackend(
            displays: [.builtin(internalID), .external(externalID)],
            brightness: [internalID: 0.7, externalID: 0.5],
            autoBrightness: [internalID: true],
            hasALC: [internalID: true])
        DisplayController(backend: afterReplug, state: state).evaluate()
        #expect(afterReplug.mirrorMap[internalID] == externalID)
        #expect(afterReplug.brightnessMap[internalID] == 0)
        #expect(state.state.engaged)
        #expect(state.state.reclaimed == false)
    }

    // Multi-monitor: unplugging the mirror MASTER (one of several externals) must heal by re-mirroring to a
    // remaining external, NOT be mistaken for the user switching to extended (which would yield + light the laptop).
    @Test func unpluggingMirrorMasterHealsInsteadOfYielding() {
        let ext1: CGDirectDisplayID = 2
        let ext2: CGDirectDisplayID = 3
        let backend = MockDisplayBackend(
            displays: [.builtin(internalID), .external(ext1), .external(ext2)],
            brightness: [internalID: 0.8, ext1: 0.5, ext2: 0.5],
            autoBrightness: [internalID: true],
            hasALC: [internalID: true])
        let state = tempState()
        let c = DisplayController(backend: backend, state: state)
        c.evaluate()                                       // engage: mirror built-in -> ext1 (lowest id)
        #expect(backend.mirrorMap[internalID] == ext1)
        #expect(state.state.engaged)

        // Unplug ext1 (the master); ext2 stays. Unplugging drops the mirror.
        backend.displays = [.builtin(internalID), .external(ext2)]
        backend.mirrorMap[internalID] = nil
        c.evaluate()

        #expect(backend.mirrorMap[internalID] == ext2)    // healed onto the remaining external
        #expect(state.state.reclaimed == false)           // not mistaken for a manual takeover
        #expect(backend.brightnessMap[internalID] == 0)   // still dark
    }

    // Mirror-undo fail-safe: if un-mirroring fails on disconnect, weChangedMirror stays set and retries next time.
    @Test func mirrorUndoRetriesUntilConfirmed() {
        let backend = MockDisplayBackend(
            displays: [.builtin(internalID)],
            brightness: [internalID: 0],
            autoBrightness: [internalID: false],
            hasALC: [internalID: true],
            mirror: [internalID: externalID])
        let state = tempState()
        state.update {
            $0.engaged = true; $0.priorAutoBrightness = true
            $0.priorBrightness = 0.6; $0.weChangedMirror = true
        }
        backend.mirrorSucceeds = false                     // un-mirror attempts fail
        let c = DisplayController(backend: backend, state: state)
        c.evaluate()                                       // disconnect: restore, but mirror undo fails
        #expect(state.state.weChangedMirror)               // kept set for a retry
        #expect(backend.mirrorMap[internalID] == externalID)

        backend.mirrorSucceeds = true                      // undo can now succeed
        c.evaluate()
        #expect(backend.mirrorMap[internalID] == nil)      // mirror finally removed
        #expect(state.state.weChangedMirror == false)      // cleared only after confirmed
    }

    // Quit/uninstall must NOT fight the user's displays when the tool never engaged and the built-in is fine.
    @Test func restoreUnconditionallyNoOpsWhenNothingToRestore() {
        let backend = MockDisplayBackend(
            displays: [.builtin(internalID), .external(externalID)],
            brightness: [internalID: 0.7, externalID: 0.5])
        let state = tempState()   // defaults: engaged=false, weChangedMirror=false
        DisplayController(backend: backend, state: state).restoreUnconditionally()

        #expect(backend.brightnessSets.isEmpty)
        #expect(backend.mirrorSets.isEmpty)
    }

    // ...but a dark built-in is force-rescued even with default state (corrupt/lost-state safety, rule 3).
    @Test func restoreUnconditionallyForcesDarkBuiltinEvenWhenStateSaysIdle() {
        let backend = MockDisplayBackend(
            displays: [.builtin(internalID)],
            brightness: [internalID: 0],
            autoBrightness: [internalID: false],
            hasALC: [internalID: true])
        let state = tempState()   // engaged=false
        DisplayController(backend: backend, state: state).restoreUnconditionally()

        #expect((backend.brightnessMap[internalID] ?? 0) > 0.1)
    }

    // A persistent failure notifies once (not on every event); a later success clears lastError.
    @Test func sameFailureNotifiesOnceAndClearsOnSuccess() {
        let backend = MockDisplayBackend(
            displays: [.builtin(internalID), .external(externalID)],
            brightness: [internalID: 0.8],
            autoBrightness: [internalID: true],
            hasALC: [internalID: true])
        backend.canControl = false
        let state = tempState()
        var notifications = 0
        let c = DisplayController(backend: backend, state: state)
        c.notifyFailure = { _ in notifications += 1 }

        c.evaluate(); c.evaluate()                  // same failure twice
        #expect(notifications == 1)                 // notified only once
        #expect(state.state.lastError != nil)

        backend.canControl = true                   // failure resolved
        c.evaluate()                                // engages successfully
        #expect(state.state.lastError == nil)       // error cleared on success
        #expect(state.state.engaged)
    }
}
