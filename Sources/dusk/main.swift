import Foundation
import Darwin
import AppKit
import DuskKit

/// Version baked into the binary. Bump this together with the release tag when cutting a release.
let duskVersion = "0.1.0"

// MARK: - General helpers

/// Real absolute path of the current executable, used to point the LaunchAgent at ourselves.
func currentExecutablePath() -> String {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size))
    if _NSGetExecutablePath(&buffer, &size) == 0 {
        let path = String(cString: buffer)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
    return CommandLine.arguments.first ?? "dusk"
}

func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Post a macOS notification (osascript works for a CLI; no app bundle needed). Used to fail loudly.
func postNotification(_ message: String) {
    let safe = message.replacingOccurrences(of: "\"", with: "'")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", "display notification \"\(safe)\" with title \"Dusk\""]
    try? process.run()
}

func makeController() -> DisplayController {
    let backend = SystemDisplayBackend()
    let state = StateManager()
    return DisplayController(backend: backend, state: state)
}

// MARK: - Background / foreground run

// Signal sources must be strongly retained, otherwise they're released immediately.
var signalSources: [DispatchSourceSignal] = []

func installSignalHandlers(_ handler: @escaping () -> Void) {
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
        signalSources.append(source)
    }
}

func runService(foreground: Bool) -> Never {
    // Must init the Cocoa app environment first, or we won't get external display-change
    // notifications (physical plug/unplug, lid close). A plain CLI + RunLoop.main.run() only
    // gets reconfigs this process triggers, not the async ones WindowServer pushes (confirmed
    // via cross-process testing). NSApplication only gets them after the connection is set up.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // background-style: no Dock icon, no focus stealing, no menu bar

    let backend = SystemDisplayBackend()
    let state = StateManager()
    let controller = DisplayController(backend: backend, state: state)
    controller.log = { message in
        // Stay silent as a daemon (no logs when healthy); only the foreground debug mode logs info.
        guard foreground else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        print("\(stamp) \(message)")
        fflush(stdout)
    }
    // Speak up only on failure: macOS notification + stderr (launchd captures stderr for debugging).
    controller.notifyFailure = { message in
        postNotification(message)
        printErr("dusk: \(message)")
    }

    if !backend.brightnessControlAvailable {
        printErr("Warning: brightness control API unavailable; cannot dim the built-in display (macOS may have changed).")
    }

    let monitor = DisplayMonitor()
    monitor.onChange = { controller.evaluate() }
    monitor.start()

    if foreground {
        print("dusk running in the foreground. Press Ctrl-C to quit.")
    }

    // Evaluate once at startup (covers "external already connected at launch" and "reconcile after crash").
    controller.evaluate()

    // Pure event-driven, no polling: with auto-brightness off, brightness 0 stays put, so no timer needed.

    // On quit/logout (launchd sends SIGTERM), unconditionally restore the built-in display (fail safe, rule 3).
    installSignalHandlers {
        controller.restoreUnconditionally()
        exit(0)
    }

    app.run()   // NSApplication event loop: delivers WindowServer external notifications + dispatch + signals
    // app.run() never returns.
    fatalError("event loop exited unexpectedly")
}

// MARK: - Subcommands

func cmdInstall() {
    let exe = currentExecutablePath()
    do {
        try LaunchAgent.writePlist(executablePath: exe)
    } catch {
        printErr("Failed to write LaunchAgent plist: \(error)")
        exit(1)
    }
    // Order matters: bootstrap (register the service) first, then disable / kickstart.
    // Bootstrapping while disabled makes launchctl fail (rc=5) and the daemon never starts.
    LaunchAgent.bootstrap()
    LaunchAgent.disableLogin()   // no autostart by default (still kickstarted for this session)
    LaunchAgent.kickstart()      // start now (kickstart -k force-runs a registered service even if disabled)
    guard LaunchAgent.isBootstrapped() else {
        printErr("❌ Install failed: the background service didn't load. Try `dusk start`, or check ~/Library/Logs.")
        exit(1)
    }
    print("✅ Installed and running in the background (start-at-login is off by default).")
    print("   • Start at login:  dusk login on")
    print("   • Check status:    dusk status")
    print("   • Uninstall:       dusk uninstall")
}

func cmdUninstall() {
    // Restore the built-in display, then stop the service, then delete every file we created (zero residue).
    makeController().restoreUnconditionally()
    LaunchAgent.bootout()
    LaunchAgent.enableLogin()    // clear the launchctl disable override that install wrote
    LaunchAgent.removePlist()
    let fm = FileManager.default
    // Delete all runtime data: the state directory (incl. state.json) + log files.
    try? fm.removeItem(at: StateManager.defaultURL().deletingLastPathComponent())
    for path in LaunchAgent.logPaths() { try? fm.removeItem(atPath: path) }

    print("✅ Stopped, restored the built-in display, and removed everything it created")
    print("   (LaunchAgent plist, launchd registration, state file, and logs).")
    print("   The binary itself is still at:")
    print("     \(currentExecutablePath())")
    print("   Delete that file to remove it completely.")
}

func cmdStart() {
    LaunchAgent.bootstrap()
    LaunchAgent.kickstart()
    print("✅ Background service started.")
}

func cmdStop() {
    // Restore the built-in before stopping, so it's not left dark with no one managing it (rule 3).
    makeController().restoreUnconditionally()
    LaunchAgent.bootout()
    print("✅ Background service stopped; built-in display restored.")
}

func cmdLogin(_ arg: String?) {
    switch arg {
    case "on":
        if !LaunchAgent.plistExists() {
            _ = try? LaunchAgent.writePlist(executablePath: currentExecutablePath())
        }
        LaunchAgent.enableLogin()
        LaunchAgent.bootstrap()
        print("✅ Start-at-login enabled.")
    case "off":
        LaunchAgent.disableLogin()
        print("✅ Start-at-login disabled (background residency unaffected).")
    default:
        printErr("Usage: dusk login on|off")
        exit(2)
    }
}

func cmdStatus() {
    let backend = SystemDisplayBackend()
    let state = StateManager()
    let diag = Diagnostics(backend: backend)

    print("dusk \(duskVersion) — status")
    print("")
    print("Capability:")
    print("  • \(diag.summary)")
    print("")
    print("Residency / autostart:")
    print("  • Background service: \(LaunchAgent.isBootstrapped() ? "running" : "not running")")
    print("  • Start at login:     \(LaunchAgent.isLoginEnabled() ? "on" : "off")")
    print("")
    print("State (\(StateManager.defaultURL().path)):")
    print("  • Built-in dimmed:        \(state.state.engaged && !state.state.reclaimed ? "yes" : "no")")
    if state.state.reclaimed {
        print("  • Yielded to manual override: yes (resumes when you reconnect the external)")
    }
    print("  • Brightness before dim:  \(String(format: "%.2f", state.state.priorBrightness))")
    print("  • Auto-brightness before: \(state.state.priorAutoBrightness ? "on" : "off")")
    if let err = state.state.lastError {
        print("  • ⚠️ Last error: \(err)")
    }
    print("")
    print("Displays:")
    let displays = backend.onlineDisplays()
    if displays.isEmpty {
        print("  (none detected)")
    }
    for d in displays {
        let kind = d.isBuiltin ? "built-in" : "external"
        let displayState: String
        if d.isAsleep { displayState = "asleep" }
        else if d.isActive { displayState = "active" }
        else { displayState = "mirror/standby" }   // awake but isActive=false, usually a mirror slave
        let brightness = backend.brightness(of: d.id).map { String(format: "%.2f", $0) } ?? "—"
        let mirror = backend.mirrorTarget(of: d.id).map { " mirror→\($0)" } ?? ""
        print("  • [\(kind) · \(displayState)] id=\(d.id)  brightness=\(brightness)\(mirror)")
    }
}

func printUsage() {
    print("""
    dusk — turn off the built-in display when an external is connected

    Usage:
      dusk            Run in the foreground (debug; Ctrl-C to quit)
      dusk --daemon   Background mode (used by launchd)
      dusk install    Install and start the background service (no autostart)
      dusk uninstall  Stop, restore the built-in display, and clean up
      dusk start      Start the background service
      dusk stop       Stop the background service and restore the built-in
      dusk login on   Enable start-at-login
      dusk login off  Disable start-at-login (default)
      dusk status     Show displays and tool state
      dusk --version  Print the version
      dusk --help     Show this help
    """)
}

// MARK: - Entry point

// Line-buffer stdout so each log line shows up immediately even through a pipe/redirect (tee, log file),
// instead of being swallowed by the default block buffering and dumped all at once on exit.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case nil:
    runService(foreground: true)
case "--daemon":
    runService(foreground: false)
case "install":
    cmdInstall()
case "uninstall":
    cmdUninstall()
case "start":
    cmdStart()
case "stop":
    cmdStop()
case "login":
    cmdLogin(arguments.dropFirst().first)
case "status":
    cmdStatus()
case "--version", "-v", "version":
    print("dusk \(duskVersion)")
case "--help", "-h", "help":
    printUsage()
case let other?:
    printErr("Unknown command: \(other)\n")
    printUsage()
    exit(2)
}
