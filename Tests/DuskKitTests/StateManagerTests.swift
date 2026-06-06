import Testing
import Foundation
@testable import DuskKit

struct StateManagerTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dusk-state-\(UUID().uuidString).json")
    }

    @Test func defaultsWhenNoFile() {
        let state = StateManager(url: tempURL())
        #expect(state.state.engaged == false)
        #expect(state.state.priorBrightness == 1.0)
        #expect(state.state.priorAutoBrightness == true)
        #expect(state.state.weChangedMirror == false)
        #expect(state.state.reclaimed == false)
        #expect(state.state.lastError == nil)
    }

    @Test func persistAndReload() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = StateManager(url: url)
        first.update {
            $0.engaged = true
            $0.priorBrightness = 0.42
            $0.priorAutoBrightness = false
            $0.weChangedMirror = true
        }

        // New instance reads back from the same file, simulating crash reconciliation after a daemon restart.
        let reloaded = StateManager(url: url)
        #expect(reloaded.state.engaged)
        #expect(approx(reloaded.state.priorBrightness, 0.42))
        #expect(reloaded.state.priorAutoBrightness == false)
        #expect(reloaded.state.weChangedMirror)
    }

    @Test func corruptFileFallsBackToDefault() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try? Data("not valid json".utf8).write(to: url)

        let state = StateManager(url: url)
        #expect(state.state.engaged == false)              // corrupt file falls back to safe default
        #expect(state.state.priorBrightness == 1.0)
    }

    // A state file written by an older build (no `reclaimed` / `lastError` keys) must still load -- and SAFELY --
    // rather than throwing and discarding restore data on upgrade.
    @Test func decodesLegacyStateWithoutReclaimedKey() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let legacy = #"{"engaged":true,"priorBrightness":0.5,"priorAutoBrightness":false,"weChangedMirror":true}"#
        try? Data(legacy.utf8).write(to: url)

        let state = StateManager(url: url)
        #expect(state.state.engaged)
        #expect(approx(state.state.priorBrightness, 0.5))
        #expect(state.state.priorAutoBrightness == false)
        #expect(state.state.weChangedMirror)
        #expect(state.state.reclaimed == false)            // defaulted, not a decode failure
        #expect(state.state.lastError == nil)
    }
}
