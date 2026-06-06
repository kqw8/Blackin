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
}
