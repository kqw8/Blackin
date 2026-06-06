import Foundation

/// LaunchAgent install / load management.
///
/// Design keeps two concepts decoupled:
///   - **Background residency**: whether launchd has the agent loaded and running in the
///     current login session (bootstrap / bootout). `KeepAlive` makes it self-heal on
///     crash, the safety net against "stuck on a black screen".
///   - **Launch at login**: whether it auto-starts on next login (launchctl enable /
///     disable + whether the plist is present). Off by default; user turns it on via `login on`.
///
/// Physical fact: residency across reboot is essentially "launch at login"; the two can
/// only be distinguished within a single login session.
public enum LaunchAgent {
    public static let label = "com.kqw8.dusk"

    /// Standard location for the LaunchAgent plist; present here + not disabled = launches at login.
    public static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var domainTarget: String { "gui/\(getuid())" }
    private static var serviceTarget: String { "gui/\(getuid())/\(label)" }

    // MARK: - plist generation (pure functions, easy to unit test)

    /// Log file paths the tool writes to (used by uninstall cleanup so nothing is left behind).
    public static func logPaths() -> [String] {
        let dir = NSHomeDirectory() + "/Library/Logs"
        return ["\(dir)/dusk.out.log", "\(dir)/dusk.err.log"]
    }

    /// Generate plist contents. `executablePath` is the absolute path to the tool binary.
    public static func plistContents(executablePath: String) -> String {
        let logs = logPaths()
        let outLog = logs[0]
        let errLog = logs[1]
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executablePath)</string>
                <string>--daemon</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ProcessType</key>
            <string>Background</string>
            <key>StandardOutPath</key>
            <string>\(outLog)</string>
            <key>StandardErrorPath</key>
            <string>\(errLog)</string>
        </dict>
        </plist>
        """
    }

    // MARK: - plist file management

    @discardableResult
    public static func writePlist(executablePath: String) throws -> URL {
        let url = plistURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try plistContents(executablePath: executablePath).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    public static func removePlist() {
        try? FileManager.default.removeItem(at: plistURL)
    }

    public static func plistExists() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    // MARK: - launchctl operations

    /// Load the agent into the current session (background residency). Idempotent if already loaded.
    @discardableResult
    public static func bootstrap() -> Bool {
        _ = launchctl(["bootstrap", domainTarget, plistURL.path])
        return isBootstrapped()
    }

    /// Unload the agent from the current session (stop residency).
    public static func bootout() {
        _ = launchctl(["bootout", serviceTarget])
    }

    /// Start it once immediately (forces a run even when disabled; used for "resident but no auto-start").
    public static func kickstart() {
        _ = launchctl(["kickstart", "-k", serviceTarget])
    }

    /// Enable launch at login.
    public static func enableLogin() {
        _ = launchctl(["enable", serviceTarget])
    }

    /// Disable launch at login (does not affect current-session residency).
    public static func disableLogin() {
        _ = launchctl(["disable", serviceTarget])
    }

    // MARK: - status queries

    /// Whether it is currently loaded (resident in background).
    public static func isBootstrapped() -> Bool {
        launchctl(["print", serviceTarget]).status == 0
    }

    /// Whether it launches at login: plist present in LaunchAgents and not disabled.
    public static func isLoginEnabled() -> Bool {
        guard plistExists() else { return false }
        let output = launchctl(["print-disabled", domainTarget]).output
        for line in output.split(separator: "\n") where line.contains("\"\(label)\"") {
            // Looks like:  "com.kqw8.dusk" => true   (true == disabled)
            return !line.contains("true")
        }
        // Not in the disabled list -> launchd enables it by default.
        return true
    }

    // MARK: - helpers

    @discardableResult
    private static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "failed to run launchctl: \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
