import Foundation

/// State that must survive process restarts.
///
/// Before going dark, record everything needed to restore (prior brightness,
/// prior auto-brightness, whether we changed the mirror) so a crash/restart can
/// fully recover the internal display (rule 3).
public struct PersistentState: Codable, Equatable {
    /// Whether the internal display is currently mirrored and dark.
    public var engaged: Bool
    /// Internal display's normal brightness before going dark, for restore; range [0,1].
    public var priorBrightness: Float
    /// Internal display's auto-brightness (ambient light) setting before going dark, for restore.
    public var priorAutoBrightness: Bool
    /// Whether we set the mirror: only when true should disconnect/exit restore the display to extended.
    public var weChangedMirror: Bool
    /// During an external-connected session, whether the user manually took the built-in back (switched it to
    /// extended, or raised its brightness). While true we stay hands-off until the external is reconnected.
    public var reclaimed: Bool
    /// Description of the last failure; non-nil means "not working", shown by status (fail loudly).
    public var lastError: String?

    public init(engaged: Bool,
                priorBrightness: Float,
                priorAutoBrightness: Bool,
                weChangedMirror: Bool,
                reclaimed: Bool = false,
                lastError: String? = nil) {
        self.engaged = engaged
        self.priorBrightness = priorBrightness
        self.priorAutoBrightness = priorAutoBrightness
        self.weChangedMirror = weChangedMirror
        self.reclaimed = reclaimed
        self.lastError = lastError
    }

    /// Decode tolerantly: a state file written by an older build (no `reclaimed`) loads with it defaulted to false.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engaged = try c.decode(Bool.self, forKey: .engaged)
        priorBrightness = try c.decode(Float.self, forKey: .priorBrightness)
        priorAutoBrightness = try c.decode(Bool.self, forKey: .priorAutoBrightness)
        weChangedMirror = try c.decode(Bool.self, forKey: .weChangedMirror)
        reclaimed = try c.decodeIfPresent(Bool.self, forKey: .reclaimed) ?? false
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }

    /// Safe defaults: not dark, full brightness, auto-brightness on, mirror untouched.
    public static let defaultState = PersistentState(
        engaged: false,
        priorBrightness: 1.0,
        priorAutoBrightness: true,
        weChangedMirror: false,
        reclaimed: false,
        lastError: nil)
}

/// Handles persisting and loading `PersistentState` to/from disk.
public final class StateManager {
    private let url: URL
    public private(set) var state: PersistentState

    public init(url: URL? = nil) {
        self.url = url ?? StateManager.defaultURL()
        self.state = StateManager.read(from: self.url) ?? .defaultState
    }

    /// Mutate the state and persist immediately.
    public func update(_ mutate: (inout PersistentState) -> Void) {
        mutate(&state)
        persist()
    }

    public func persist() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("dusk: failed to write state file: \(error)\n".utf8))
        }
    }

    private static func read(from url: URL) -> PersistentState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PersistentState.self, from: data)
    }

    /// Default state file location: ~/Library/Application Support/dusk/state.json
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("dusk/state.json")
    }
}
