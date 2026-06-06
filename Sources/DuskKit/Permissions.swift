import Foundation

/// Self-check / diagnostics for the tool's capabilities.
///
/// Internal-display brightness control goes through the private DisplayServices API,
/// which usually needs **no** special grants like Accessibility or Screen Recording;
/// it really "breaks" only when a macOS upgrade removes the private symbols.
/// So this mainly checks whether brightness control is available and gives a
/// human-readable diagnostic, so the `status` command can tell the user if it works.
public struct Diagnostics {
    public let brightnessControlAvailable: Bool

    public init(brightnessControlAvailable: Bool) {
        self.brightnessControlAvailable = brightnessControlAvailable
    }

    public init(backend: SystemDisplayBackend) {
        self.brightnessControlAvailable = backend.brightnessControlAvailable
    }

    /// One-line human-readable status.
    public var summary: String {
        brightnessControlAvailable
            ? "Brightness control API: available"
            : "Brightness control API: unavailable (private symbols missing; macOS may have changed)"
    }
}
