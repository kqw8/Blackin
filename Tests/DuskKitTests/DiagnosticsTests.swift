import Testing
@testable import DuskKit

struct DiagnosticsTests {
    // The `status` "Capability" line is the one signal that surfaces a private-API break after a macOS
    // upgrade, so pin both branches (guards against an inverted ternary that would falsely report "available").
    @Test func summaryReflectsAvailability() {
        #expect(Diagnostics(brightnessControlAvailable: true).summary == "Brightness control API: available")
        #expect(Diagnostics(brightnessControlAvailable: false).summary.contains("unavailable"))
    }
}
