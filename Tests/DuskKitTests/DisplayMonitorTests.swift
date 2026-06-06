import Testing
@testable import DuskKit

struct DisplayMonitorTests {
    // Rule 4: a burst of reconfiguration events debounces into exactly ONE onChange.
    @Test func debounceCollapsesBurstIntoOneOnChange() {
        var scheduled: [() -> Void] = []
        let monitor = DisplayMonitor(debounceInterval: 0.3, settleConfirmDelays: [],
                                     scheduler: { _, work in scheduled.append(work) })
        var fires = 0
        monitor.onChange = { fires += 1 }

        monitor.scheduleChange()
        monitor.scheduleChange()
        monitor.scheduleChange()
        // Three debounce works were queued; firing them all, only the latest is still current.
        for work in scheduled { work() }

        #expect(fires == 1)
    }

    // Rule 5: after the debounced fire, onChange runs once more per settle-confirm delay (late lid-open wake).
    @Test func settleConfirmFiresOncePerDelay() {
        var scheduled: [() -> Void] = []
        let monitor = DisplayMonitor(debounceInterval: 0.3, settleConfirmDelays: [1.0, 3.0],
                                     scheduler: { _, work in scheduled.append(work) })
        var fires = 0
        monitor.onChange = { fires += 1 }

        monitor.scheduleChange()
        // Drain the queue, including works appended while draining (the settle passes).
        var i = 0
        while i < scheduled.count { scheduled[i](); i += 1 }

        #expect(fires == 3)   // 1 debounce + 2 settle confirms
    }
}
