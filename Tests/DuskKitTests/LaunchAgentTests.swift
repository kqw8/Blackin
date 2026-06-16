import Testing
@testable import DuskKit

struct LaunchAgentTests {
    // plist generation is a pure function; assert key fields are present so we don't produce an agent that won't run.
    @Test func plistContainsEssentials() {
        let exe = "/usr/local/bin/dusk"
        let plist = LaunchAgent.plistContents(executablePath: exe)

        #expect(plist.contains("<string>\(exe)</string>"))   // binary path
        #expect(plist.contains("--daemon"))                  // launched with --daemon
        #expect(plist.contains(LaunchAgent.label))           // Label
        #expect(plist.contains("<key>KeepAlive</key>"))      // restart on crash
        #expect(plist.contains("<key>RunAtLoad</key>"))
        #expect(plist.hasPrefix("<?xml"))                    // valid plist header
    }

    @Test func plistContainsCustomPath() {
        let plist = LaunchAgent.plistContents(executablePath: "/opt/local/bin/dusk")
        #expect(plist.contains("/opt/local/bin/dusk"))
    }

    @Test func parsesBooleanDisabledState() {
        let output = #"""
        disabled services = {
            "com.kqw8.dusk" => true
            "com.example.other" => false
        }
        """#

        #expect(LaunchAgent.disabledState(for: LaunchAgent.label, in: output) == true)
        #expect(LaunchAgent.disabledState(for: "com.example.other", in: output) == false)
    }

    @Test func parsesWordDisabledState() {
        let output = #"""
        disabled services = {
            "com.kqw8.dusk" => disabled
            "com.example.other" => enabled
        }
        """#

        #expect(LaunchAgent.disabledState(for: LaunchAgent.label, in: output) == true)
        #expect(LaunchAgent.disabledState(for: "com.example.other", in: output) == false)
        #expect(LaunchAgent.disabledState(for: "com.example.missing", in: output) == nil)
    }
}
